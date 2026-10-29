//! Why murrtty can't draw (roadmap 6.3). When the renderer can't have an
//! OpenGL 4.3 context, the dialog says what is missing and what to do,
//! from what Windows says of the session (Remote Desktop), the display
//! adapter (its driver, or Windows' basic one) and the OpenGL it offers a
//! legacy context (Windows' own fallback is "GDI Generic" OpenGL 1.1).
const std = @import("std");
const wgl = @import("opengl").wgl;

const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.gl_diagnosis);

pub const Kind = enum { library, remote, basic_adapter, no_driver, old_driver, unknown };

/// Whether `err` is one a renderer's OpenGL setup gives.
pub fn isGlError(err: anyerror) bool {
    return switch (err) {
        error.LibraryMissing,
        error.WindowCreateFailed,
        error.ExtensionMissing,
        error.PixelFormatFailed,
        error.ContextCreateFailed,
        error.MakeCurrentFailed,
        error.WglGetDCFailed,
        error.WglMakeCurrentFailed,
        error.OpenGLOutdated,
        => true,
        else => false,
    };
}

/// What Windows says, for the dialog.
const Facts = struct {
    remote: bool,
    adapter: []const u8,
    gl: ?wgl.Info,
    /// MURRTTY_OPENGL, when set.
    library: ?[]const u8,
};

const SM_REMOTESESSION = 0x1000;

const DISPLAY_DEVICEW = extern struct {
    cb: u32 = @sizeOf(DISPLAY_DEVICEW),
    DeviceName: [32]u16 = undefined,
    DeviceString: [128]u16 = undefined,
    StateFlags: u32 = 0,
    DeviceID: [128]u16 = undefined,
    DeviceKey: [128]u16 = undefined,
};
const DISPLAY_DEVICE_PRIMARY_DEVICE = 0x4;
extern "user32" fn EnumDisplayDevicesW(device: ?[*:0]const u16, index: u32, dd: *DISPLAY_DEVICEW, flags: u32) callconv(.winapi) c.BOOL;

/// The display adapter showing the primary desktop, into `buf`.
fn primaryAdapter(buf: []u8) []const u8 {
    var i: u32 = 0;
    while (true) : (i += 1) {
        var dd: DISPLAY_DEVICEW = .{};
        if (EnumDisplayDevicesW(null, i, &dd, 0) == 0) return "unknown";
        if (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE == 0) continue;
        const name = std.mem.sliceTo(&dd.DeviceString, 0);
        // Ample: an adapter's name is ASCII, at most 128 units.
        const n = std.unicode.utf16LeToUtf8(buf, name) catch return "unknown";
        return buf[0..n];
    }
}

fn gather(err: anyerror, adapter_buf: []u8, gl_buf: *[512]u8, library_buf: []u8) Facts {
    var facts: Facts = .{
        .remote = c.GetSystemMetrics(SM_REMOTESESSION) != 0,
        .adapter = primaryAdapter(adapter_buf),
        .gl = if (err == error.LibraryMissing) null else wgl.info(gl_buf),
        .library = null,
    };
    if (wgl.libraryOverridden()) {
        var w: [1024]u16 = undefined;
        const n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(wgl.library_variable), &w, w.len);
        if (n > 0 and n < w.len) {
            const len = std.unicode.utf16LeToUtf8(library_buf, w[0..@min(n, library_buf.len / 3)]) catch 0;
            facts.library = library_buf[0..len];
        }
    }
    // The GUI tests' stand-ins for machines they don't run on
    // (GHOSTTY_WIN32_TEST_GL_DIAG): "remote", "basic", "generic", "old".
    // Each stands for the whole machine: a local one but for "remote", so
    // a run over Remote Desktop still diagnoses the others as asked.
    if (test_hooks.active()) {
        var w: [16]u16 = undefined;
        const n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_WIN32_TEST_GL_DIAG"), &w, w.len);
        const generic: wgl.Info = .{ .vendor = "Microsoft Corporation", .renderer = "GDI Generic", .version = "1.1.0" };
        if (n > 0 and n < w.len) {
            const is = struct {
                fn is(have: []const u16, comptime want: []const u8) bool {
                    return std.mem.eql(u16, have, std.unicode.utf8ToUtf16LeStringLiteral(want));
                }
            }.is;
            const which = w[0..n];
            if (is(which, "remote")) {
                facts.remote = true;
                facts.adapter = "Microsoft Remote Display Adapter";
                facts.gl = generic;
            } else if (is(which, "basic")) {
                facts.remote = false;
                facts.adapter = "Microsoft Basic Display Adapter";
                facts.gl = generic;
            } else if (is(which, "generic")) {
                facts.remote = false;
                facts.gl = generic;
            } else if (is(which, "old")) {
                facts.remote = false;
                facts.gl = .{ .vendor = "Example", .renderer = "Example GPU", .version = "3.3.0 Example 1.0" };
            }
        }
    }
    return facts;
}

/// Whether an OpenGL version string ("4.6.0 NVIDIA 560.94") is 4.3 or
/// later.
fn atLeast43(version: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, version, ". ");
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    return major > 4 or (major == 4 and minor >= 3);
}

fn kindOf(err: anyerror, facts: Facts) Kind {
    if (err == error.LibraryMissing) return .library;
    const gl = facts.gl orelse return if (facts.remote) .remote else .unknown;
    const generic = std.ascii.findIgnoreCase(gl.renderer, "GDI Generic") != null;
    const enough = atLeast43(gl.version);
    if (facts.remote and (generic or !enough)) return .remote;
    if (std.ascii.findIgnoreCase(facts.adapter, "Basic Display") != null or
        std.ascii.findIgnoreCase(facts.adapter, "Basic Render") != null) return .basic_adapter;
    if (generic) return .no_driver;
    if (!enough) return .old_driver;
    return .unknown;
}

pub const heading = "murrtty can't draw: it needs OpenGL 4.3";

/// The dialog's body for `kind`, into `buf`.
fn body(buf: []u8, kind: Kind, err: anyerror, facts: Facts) []const u8 {
    const gl = facts.gl orelse wgl.Info{ .vendor = "", .renderer = "unknown", .version = "" };
    return switch (kind) {
        .library => if (facts.library) |path| std.fmt.bufPrint(buf,
            \\The OpenGL that MURRTTY_OPENGL names couldn't be loaded: {s}
            \\
            \\It must be the full path of an opengl32.dll. Remove the variable to use Windows' own.
        , .{path}) else std.fmt.bufPrint(buf, "Windows' OpenGL (opengl32.dll, in the System32 folder) couldn't be loaded.", .{}),
        .remote => std.fmt.bufPrint(buf,
            \\This Remote Desktop session's display offers no OpenGL 4.3 ({s} {s}).
            \\
            \\Start murrtty at the computer itself, or let Remote Desktop use the computer's graphics card: turn on the policy "Use hardware graphics adapters for all Remote Desktop Services sessions" (Computer Configuration > Administrative Templates > Windows Components > Remote Desktop Services > Remote Desktop Session Host > Remote Session Environment).
        , .{ gl.renderer, gl.version }),
        .basic_adapter => std.fmt.bufPrint(buf,
            \\Windows is using its Microsoft Basic Display Adapter: the graphics card's own driver isn't installed.
            \\
            \\Install it from the card's maker (NVIDIA, AMD or Intel) or the computer's, then start murrtty again.
        , .{}),
        .no_driver => std.fmt.bufPrint(buf,
            \\The graphics driver offers no OpenGL; only Windows' fallback ({s} {s}) is there.
            \\
            \\In a virtual machine, turn on its 3D acceleration. Otherwise install the graphics card's driver from its maker.
        , .{ gl.renderer, gl.version }),
        .old_driver => std.fmt.bufPrint(buf,
            \\The graphics driver offers OpenGL {s} ({s}), and murrtty needs 4.3.
            \\
            \\Update the driver from the graphics card's maker.
        , .{ gl.version, gl.renderer }),
        .unknown => std.fmt.bufPrint(buf, "murrtty couldn't set up OpenGL ({t}). Updating the graphics driver may help.", .{err}),
    } catch buf[0..0];
}

/// Tell the user why murrtty can't draw, in a task dialog (a message box
/// if that can't show). Runs a modal loop; for murrtty's start, before
/// any window.
pub fn show(app: *App, err: anyerror) void {
    var adapter_buf: [384]u8 = undefined;
    var gl_buf: [512]u8 = undefined;
    var library_buf: [3072]u8 = undefined;
    const facts = gather(err, &adapter_buf, &gl_buf, &library_buf);
    const kind = kindOf(err, facts);
    log.err("OpenGL 4.3 is not available ({t}): {t}, adapter {s}, remote {}", .{ kind, err, facts.adapter, facts.remote });

    var body_buf: [4096]u8 = undefined;
    const text = body(&body_buf, kind, err, facts);
    const gl = facts.gl orelse wgl.Info{ .vendor = "", .renderer = "", .version = "" };
    var details_buf: [2048]u8 = undefined;
    const details = std.fmt.bufPrint(&details_buf,
        \\Display adapter: {s}
        \\OpenGL: {s}, {s}, {s}
        \\Remote Desktop session: {s}
        \\Error: {t}
        \\
        \\To see murrtty's log, start it from a shell with: murrtty.exe 2> murrtty.log
    , .{
        facts.adapter,
        if (gl.vendor.len > 0) gl.vendor else "unknown",
        gl.renderer,
        gl.version,
        if (facts.remote) "yes" else "no",
        err,
    }) catch "";

    if (app.taskDialog(.{
        .owner = null,
        .title = "murrtty",
        .instruction = heading,
        .content = text,
        .expanded = details,
        .icon = .@"error",
        .common_buttons = c.TDCBF_CLOSE_BUTTON,
    }) == null) {
        var msg_buf: [6200]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s}\n\n{s}\n\n{s}", .{ heading, text, details }) catch text;
        _ = Surface.messageBox(app.core_app.alloc, null, msg, "murrtty", c.MB_OK | c.MB_ICONERROR);
    }
}

test "atLeast43" {
    const testing = std.testing;
    try testing.expect(atLeast43("4.6.0 NVIDIA 560.94"));
    try testing.expect(atLeast43("4.3.0 - Build 31.0.101"));
    try testing.expect(!atLeast43("4.2.0"));
    try testing.expect(!atLeast43("3.3.0 Mesa"));
    try testing.expect(!atLeast43("1.1.0"));
    try testing.expect(!atLeast43(""));
}

test "kindOf" {
    const testing = std.testing;
    const generic: wgl.Info = .{ .vendor = "Microsoft Corporation", .renderer = "GDI Generic", .version = "1.1.0" };
    const nvidia: wgl.Info = .{ .vendor = "NVIDIA Corporation", .renderer = "NVIDIA GeForce RTX 2070/PCIe/SSE2", .version = "4.6.0 NVIDIA 560.94" };
    const old: wgl.Info = .{ .vendor = "Intel", .renderer = "Intel HD Graphics", .version = "3.1.0 - Build 9.17" };
    const base: Facts = .{ .remote = false, .adapter = "NVIDIA GeForce RTX 2070", .gl = nvidia, .library = null };
    try testing.expectEqual(Kind.library, kindOf(error.LibraryMissing, base));
    try testing.expectEqual(Kind.unknown, kindOf(error.ContextCreateFailed, base));

    var f = base;
    f.remote = true;
    f.gl = generic;
    try testing.expectEqual(Kind.remote, kindOf(error.ExtensionMissing, f));
    // A Remote Desktop session with the GPU's OpenGL is no diagnosis.
    f.gl = nvidia;
    try testing.expectEqual(Kind.unknown, kindOf(error.ContextCreateFailed, f));

    f = base;
    f.adapter = "Microsoft Basic Display Adapter";
    f.gl = generic;
    try testing.expectEqual(Kind.basic_adapter, kindOf(error.ExtensionMissing, f));
    f.adapter = "VMware SVGA 3D";
    try testing.expectEqual(Kind.no_driver, kindOf(error.ExtensionMissing, f));
    f.gl = old;
    try testing.expectEqual(Kind.old_driver, kindOf(error.ContextCreateFailed, f));
}
