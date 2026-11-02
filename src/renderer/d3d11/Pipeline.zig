//! A render pipeline: its shaders, the input layout of its per-instance
//! data and its blending (opengl/Pipeline.zig's counterpart).
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;
const dxgi = d3d11.dxgi;

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    /// DXBC of the vertex and pixel shaders.
    vertex: []const u8,
    pixel: []const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to blend (premultiplied: ONE, ONE_MINUS_SRC_ALPHA).
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

vs: *d3d.VertexShader,
ps: *d3d.PixelShader,
/// Null without vertex data (the full screen triangle).
layout: ?*d3d.InputLayout,
/// Bytes per instance (or vertex).
stride: u32,
/// Null: blending off.
blend: ?*d3d.BlendState,

pub fn init(gpu: *d3d.Device, comptime VertexAttributes: ?type, opts: Options) !Self {
    var vs: ?*d3d.VertexShader = null;
    if (!com.succeeded(gpu.createVertexShader(opts.vertex, &vs))) return error.D3D11Failed;
    errdefer com.release(vs.?);
    var ps: ?*d3d.PixelShader = null;
    if (!com.succeeded(gpu.createPixelShader(opts.pixel, &ps))) return error.D3D11Failed;
    errdefer com.release(ps.?);

    var layout: ?*d3d.InputLayout = null;
    if (VertexAttributes) |VA| {
        const elements = inputElements(VA, opts.step_fn);
        const hr = gpu.createInputLayout(&elements, opts.vertex, &layout);
        if (!com.succeeded(hr)) {
            log.err("input layout for {s} failed hr=0x{x:0>8}", .{ @typeName(VA), @as(u32, @bitCast(hr)) });
            return error.D3D11Failed;
        }
    }
    errdefer if (layout) |l| com.release(l);

    var blend: ?*d3d.BlendState = null;
    if (opts.blending_enabled) {
        var desc: d3d.BlendDesc = .{};
        desc.RenderTarget[0] = .{
            .BlendEnable = com.TRUE,
            .SrcBlend = .one,
            .DestBlend = .inv_src_alpha,
            .SrcBlendAlpha = .one,
            .DestBlendAlpha = .inv_src_alpha,
        };
        if (!com.succeeded(gpu.createBlendState(&desc, &blend))) return error.D3D11Failed;
    }

    return .{
        .vs = vs.?,
        .ps = ps.?,
        .layout = layout,
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .blend = blend,
    };
}

pub fn deinit(self: *const Self) void {
    if (self.blend) |b| com.release(b);
    if (self.layout) |l| com.release(l);
    com.release(self.ps);
    com.release(self.vs);
}

/// The input layout of `T`'s fields, in order, as semantic ATTR<n> (the
/// HLSL's VsIn), as opengl/Pipeline.zig's autoAttribute lays them out.
fn inputElements(comptime T: type, step_fn: Options.StepFunction) [@typeInfo(T).@"struct".field_names.len]d3d.InputElementDesc {
    var out = comptime fieldElements(T);
    for (&out) |*e| {
        e.InputSlotClass = if (step_fn == .per_instance) .per_instance else .per_vertex;
        e.InstanceDataStepRate = if (step_fn == .per_instance) 1 else 0;
    }
    return out;
}

/// Each field's format and offset.
fn fieldElements(comptime T: type) [@typeInfo(T).@"struct".field_names.len]d3d.InputElementDesc {
    const info = @typeInfo(T).@"struct";
    var out: [info.field_names.len]d3d.InputElementDesc = undefined;
    for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        const FT = switch (@typeInfo(field_type)) {
            .@"struct" => |s| s.backing_integer.?,
            .@"enum" => |e| e.tag_type,
            else => field_type,
        };
        const size, const IT = switch (@typeInfo(FT)) {
            .array => |a| .{ a.len, a.child },
            else => .{ 1, FT },
        };
        out[i] = .{
            .SemanticName = "ATTR",
            .SemanticIndex = i,
            .Format = formatOf(IT, size),
            .InputSlot = 0,
            .AlignedByteOffset = @offsetOf(T, field_name),
        };
    }
    return out;
}

fn formatOf(comptime IT: type, comptime n: usize) dxgi.Format {
    return switch (IT) {
        u8 => switch (n) {
            1 => .r8_uint,
            4 => .r8g8b8a8_uint,
            else => @compileError("no u8 vertex format of this size"),
        },
        u16 => switch (n) {
            2 => .r16g16_uint,
            else => @compileError("no u16 vertex format of this size"),
        },
        i16 => switch (n) {
            2 => .r16g16_sint,
            else => @compileError("no i16 vertex format of this size"),
        },
        u32 => switch (n) {
            1 => .r32_uint,
            2 => .r32g32_uint,
            else => @compileError("no u32 vertex format of this size"),
        },
        f32 => switch (n) {
            1 => .r32_float,
            2 => .r32g32_float,
            4 => .r32g32b32a32_float,
            else => @compileError("no f32 vertex format of this size"),
        },
        else => @compileError("no vertex format for " ++ @typeName(IT)),
    };
}

test "input layouts" {
    const shaders = @import("shaders.zig");
    const text = inputElements(shaders.CellText, .per_instance);
    try std.testing.expectEqual(7, text.len);
    try std.testing.expectEqual(dxgi.Format.r32g32_uint, text[0].Format);
    try std.testing.expectEqual(dxgi.Format.r16g16_sint, text[2].Format);
    try std.testing.expectEqual(dxgi.Format.r16g16_uint, text[3].Format);
    try std.testing.expectEqual(@as(u32, 20), text[3].AlignedByteOffset);
    try std.testing.expectEqual(dxgi.Format.r8g8b8a8_uint, text[4].Format);
    try std.testing.expectEqual(dxgi.Format.r8_uint, text[5].Format);
    try std.testing.expectEqual(@as(u32, 29), text[6].AlignedByteOffset);
    const bg = inputElements(shaders.BgImage, .per_instance);
    try std.testing.expectEqual(dxgi.Format.r32_float, bg[0].Format);
    try std.testing.expectEqual(dxgi.Format.r8_uint, bg[1].Format);
    try std.testing.expectEqual(@as(u32, 4), bg[1].AlignedByteOffset);
}
