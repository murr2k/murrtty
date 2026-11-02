//! What every pane's Direct3D 11 renderer shares (murrtty's roadmap 7.8).
//!
//! Each pane has its own ID3D11Device, whose immediate context only its
//! render thread uses (as each had its own OpenGL context): no locks
//! between the panes' render threads, and a lost device is one pane's to
//! rebuild. This holds whether panes draw on the GPU or with WARP, decided
//! by the first pane and kept, and the shaders, compiled once per process
//! (DXBC doesn't depend on the device).
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;
const dxgi = d3d11.dxgi;
const compiler = d3d11.compiler;
const global = @import("../../global.zig");

const log = std.log.scoped(.d3d11);

/// The win32 runtime asks for none.
pub const Options = struct {};

alloc: Allocator,

/// Panes draw with WARP: no hardware adapter gave feature level 11_0, or
/// MURRTTY_D3D=warp asked for it (`warp_asked`).
warp: std.atomic.Value(bool),
warp_asked: bool,

/// The GUI tests' stand-in for a machine whose GPU, or GPU and WARP both,
/// give no device (GHOSTTY_WIN32_TEST_D3D=hardware or all), or for custom
/// shaders the compiler refuses (post). Debug only.
test_fail: enum { none, hardware, all, post } = .none,

/// Each program's bytecode, compiled the first time a pane asks.
shader_mutex: std.Io.Mutex = .init,
compiled: std.EnumArray(Program, ?Bytecode) = .initFill(null),

pub const Program = enum {
    bg_color,
    cell_bg,
    cell_text,
    image,
    bg_image,
    present,
    shapes,
    /// The vertex shader of custom shaders' passes (full_screen_vs).
    post,
};

pub const Bytecode = struct {
    vs: []const u8,
    ps: []const u8,
};

pub fn init(alloc: Allocator, options: Options) !*Device {
    _ = options;
    const self = try alloc.create(Device);
    const asked = envIs("MURRTTY_D3D", "warp");
    self.* = .{
        .alloc = alloc,
        .warp = .init(asked),
        .warp_asked = asked,
    };
    if (comptime builtin.mode == .debug) {
        if (envIs("GHOSTTY_WIN32_TEST_D3D", "hardware")) self.test_fail = .hardware;
        if (envIs("GHOSTTY_WIN32_TEST_D3D", "all")) self.test_fail = .all;
        if (envIs("GHOSTTY_WIN32_TEST_D3D", "post")) self.test_fail = .post;
    }
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    for (std.enums.values(Program)) |p| if (self.compiled.get(p)) |b| {
        self.alloc.free(b.vs);
        self.alloc.free(b.ps);
    };
    alloc.destroy(self);
}

/// Whether environment variable `name` is `value` (ignoring case).
/// MURRTTY_D3D=warp draws with WARP even where a GPU could (tests,
/// diagnosis): an environment variable, as the config file stays Ghostty's.
fn envIs(comptime name: []const u8, comptime value: []const u8) bool {
    var buf: [value.len + 1]u16 = undefined;
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len);
    // `value` is ASCII: compared unit by unit, nothing converted.
    if (n != value.len) return false;
    for (buf[0..n], value) |unit, ch| {
        if (unit > 0x7f or std.ascii.toLower(@intCast(unit)) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

/// A pane's device and immediate context.
pub const Made = struct {
    gpu: *d3d.Device,
    ctx: *d3d.DeviceContext,
    /// WARP, or the GPU's driver is Microsoft's Basic Render Driver: the
    /// frames are drawn on the CPU.
    software: bool,
};

pub const Purpose = struct {
    /// Replacing a lost device: the GPU may be resetting and back a moment
    /// later, so a failure there never moves every pane to WARP.
    recovering: bool = false,
    /// The GPU's device or none (recovery's first tries).
    gpu_only: bool = false,
};

/// A new device for a pane: on the GPU, unless panes draw with WARP (once
/// the GPU fails a new pane, every pane after draws with WARP).
pub fn createDevice(self: *Device, purpose: Purpose) !Made {
    if (!self.warp.load(.acquire)) {
        const made = if (self.test_fail == .hardware or self.test_fail == .all) error.DeviceFailed else create(.hardware);
        if (made) |m| return m else |err| {
            if (purpose.gpu_only) return err;
            if (purpose.recovering) {
                log.warn("no Direct3D 11 device on the GPU after the loss err={}; this pane draws with WARP", .{err});
            } else {
                log.warn("no Direct3D 11 device on the GPU err={}; drawing with WARP", .{err});
                self.warp.store(true, .release);
            }
        }
    }
    if (self.test_fail == .all) return error.DeviceFailed;
    return create(.warp);
}

fn create(driver: d3d.DriverType) !Made {
    var gpu: ?*d3d.Device = null;
    var ctx: ?*d3d.DeviceContext = null;
    var level: d3d.FeatureLevel = undefined;
    // 11_0 at least: structured buffers in the vertex shader.
    const levels = [_]d3d.FeatureLevel{.@"11_0"};
    const hr = d3d.D3D11CreateDevice(null, driver, null, d3d.CREATE_DEVICE_BGRA_SUPPORT, &levels, levels.len, d3d.SDK_VERSION, &gpu, &level, &ctx);
    if (!com.succeeded(hr)) {
        log.info("D3D11CreateDevice({t}) failed hr=0x{x:0>8}", .{ driver, @as(u32, @bitCast(hr)) });
        return error.DeviceFailed;
    }
    const made: Made = .{ .gpu = gpu.?, .ctx = ctx.?, .software = driver == .warp or isSoftware(gpu.?) };
    return made;
}

/// Whether the device's adapter draws on the CPU: WARP, or Microsoft's
/// Basic Render Driver, which a machine without a GPU driver (a virtual
/// machine, GitHub's runners) gets as its "hardware" adapter and which
/// doesn't set DXGI's software flag. Both are Microsoft's 0x1414:0x8C.
fn isSoftware(gpu: *d3d.Device) bool {
    const dxgi_device = com.query(gpu, dxgi.Device) orelse return false;
    defer com.release(dxgi_device);
    const adapter = dxgi_device.getAdapter() orelse return false;
    defer com.release(adapter);
    var desc: dxgi.AdapterDesc1 = undefined;
    if (!com.succeeded(adapter.getDesc1(&desc))) return false;
    return desc.Flags & dxgi.ADAPTER_FLAG_SOFTWARE != 0 or
        (desc.VendorId == 0x1414 and desc.DeviceId == 0x8C);
}

/// The adapter's name, for the log and the tests' dump.
pub fn adapterName(gpu: *d3d.Device, buf: []u8) []const u8 {
    const dxgi_device = com.query(gpu, dxgi.Device) orelse return "";
    defer com.release(dxgi_device);
    const adapter = dxgi_device.getAdapter() orelse return "";
    defer com.release(adapter);
    var desc: dxgi.AdapterDesc1 = undefined;
    if (!com.succeeded(adapter.getDesc1(&desc))) return "";
    // Whole characters while they fit: a non-ASCII name can take three
    // bytes a unit, more than `buf` holds.
    var n: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(std.mem.sliceTo(&desc.Description, 0));
    while (it.nextCodepoint() catch null) |cp| {
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (n + len > buf.len) break;
        _ = std.unicode.utf8Encode(cp, buf[n..][0..len]) catch break;
        n += len;
    }
    return buf[0..n];
}

/// The bytecode the build compiled (src/build/DxbcStep.zig), or a stub
/// without any where the build machine isn't Windows.
const dxbc = @import("murrtty_dxbc");

/// A program's bytecode: the build's, or compiled the first time it is
/// asked for.
pub fn bytecode(self: *Device, program: Program) !Bytecode {
    switch (program) {
        inline else => |p| if (comptime @hasDecl(dxbc, @tagName(p))) {
            const code = @field(dxbc, @tagName(p));
            return .{ .vs = code[0], .ps = code[1] };
        },
    }
    self.shader_mutex.lockUncancelable(global.io());
    defer self.shader_mutex.unlock(global.io());
    if (self.compiled.get(program)) |b| return b;
    const b = try self.compile(program);
    self.compiled.set(program, b);
    return b;
}

const sources = @import("shaders.zig").sources;

fn compile(self: *Device, program: Program) !Bytecode {
    const src = sources.get(program);
    const vs = try compileStage(self.alloc, src.text, @tagName(program), src.vs, "vs_5_0");
    errdefer self.alloc.free(vs);
    // `post` is a vertex stage alone: each custom shader is its pixel stage.
    const ps = if (src.ps.len == 0) &.{} else try compileStage(self.alloc, src.text, @tagName(program), src.ps, "ps_5_0");
    return .{ .vs = vs, .ps = ps };
}

/// One entry point of `text` to DXBC (System32's d3dcompiler_47), copied
/// into `alloc`'s memory.
pub fn compileStage(alloc: Allocator, text: []const u8, name: [:0]const u8, entry: [:0]const u8, target: [:0]const u8) ![]u8 {
    var messages: std.ArrayList(u8) = .empty;
    defer messages.deinit(alloc);
    const code = compiler.compile(text, name, entry, target, compiler.OPTIMIZATION_LEVEL3, &messages, alloc) catch |err| {
        log.err("compiling {s} {s} failed err={} {s}", .{ name, entry, err, messages.items });
        return err;
    };
    defer code.deinit();
    return try alloc.dupe(u8, code.bytes());
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
