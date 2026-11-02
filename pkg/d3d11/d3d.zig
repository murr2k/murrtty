//! Direct3D 11 (d3d11.h): the device, its immediate context, resources,
//! views, states and shaders, as murrtty's renderer uses them. Slot
//! indices from mingw-w64's `ID3D11DeviceVtbl` and
//! `ID3D11DeviceContextVtbl`.
const std = @import("std");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const GUID = com.GUID;
const method = com.method;

pub const SDK_VERSION: u32 = 7;

pub const DriverType = enum(u32) { unknown = 0, hardware = 1, reference = 2, null = 3, software = 4, warp = 5 };
pub const FeatureLevel = enum(u32) {
    @"10_0" = 0xa000,
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    _,
};

pub const CREATE_DEVICE_SINGLETHREADED: u32 = 0x1;
pub const CREATE_DEVICE_DEBUG: u32 = 0x2;
pub const CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const Usage = enum(u32) { default = 0, immutable = 1, dynamic = 2, staging = 3 };

pub const BIND_VERTEX_BUFFER: u32 = 0x1;
pub const BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const BIND_SHADER_RESOURCE: u32 = 0x8;
pub const BIND_RENDER_TARGET: u32 = 0x20;

pub const CPU_ACCESS_WRITE: u32 = 0x10000;
pub const CPU_ACCESS_READ: u32 = 0x20000;

pub const RESOURCE_MISC_BUFFER_STRUCTURED: u32 = 0x40;

pub const Map = enum(u32) { read = 1, write = 2, read_write = 3, write_discard = 4, write_no_overwrite = 5 };

pub const Topology = enum(u32) { triangle_list = 4, triangle_strip = 5 };

pub const InputClass = enum(u32) { per_vertex = 0, per_instance = 1 };
pub const APPEND_ALIGNED_ELEMENT: u32 = 0xffffffff;

pub const Blend = enum(u32) {
    zero = 1,
    one = 2,
    src_color = 3,
    inv_src_color = 4,
    src_alpha = 5,
    inv_src_alpha = 6,
    dest_alpha = 7,
    inv_dest_alpha = 8,
    dest_color = 9,
    inv_dest_color = 10,
};
pub const BlendOp = enum(u32) { add = 1, subtract = 2, rev_subtract = 3, min = 4, max = 5 };
pub const COLOR_WRITE_ENABLE_ALL: u8 = 0xf;

pub const FillMode = enum(u32) { wireframe = 2, solid = 3 };
pub const CullMode = enum(u32) { none = 1, front = 2, back = 3 };

pub const Filter = enum(u32) { min_mag_mip_point = 0, min_mag_mip_linear = 0x15 };
pub const AddressMode = enum(u32) { wrap = 1, mirror = 2, clamp = 3, border = 4 };
pub const ComparisonFunc = enum(u32) { never = 1, always = 8 };

pub const SrvDimension = enum(u32) { buffer = 1, texture2d = 4 };
pub const RtvDimension = enum(u32) { buffer = 1, texture2d = 4 };

pub const BufferDesc = extern struct {
    ByteWidth: u32,
    Usage: Usage = .default,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: dxgi.Format,
    SampleDesc: dxgi.SampleDesc = .{},
    Usage: Usage = .default,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const SubresourceData = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32 = 0,
    SysMemSlicePitch: u32 = 0,
};

pub const MappedSubresource = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: u32 = 0,
    DepthPitch: u32 = 0,
};

pub const ShaderResourceViewDesc = extern struct {
    Format: dxgi.Format,
    ViewDimension: SrvDimension,
    u: extern union {
        Buffer: extern struct { FirstElement: u32, NumElements: u32 },
        Texture2D: extern struct { MostDetailedMip: u32, MipLevels: u32 },
        _size: [4]u32,
    },
};

pub const RenderTargetViewDesc = extern struct {
    Format: dxgi.Format,
    ViewDimension: RtvDimension,
    u: extern union {
        Texture2D: extern struct { MipSlice: u32 },
        _size: [3]u32,
    },
};

pub const InputElementDesc = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32 = 0,
    Format: dxgi.Format,
    InputSlot: u32 = 0,
    AlignedByteOffset: u32 = APPEND_ALIGNED_ELEMENT,
    InputSlotClass: InputClass = .per_vertex,
    InstanceDataStepRate: u32 = 0,
};

pub const RenderTargetBlendDesc = extern struct {
    BlendEnable: BOOL = com.FALSE,
    SrcBlend: Blend = .one,
    DestBlend: Blend = .zero,
    BlendOp: BlendOp = .add,
    SrcBlendAlpha: Blend = .one,
    DestBlendAlpha: Blend = .zero,
    BlendOpAlpha: BlendOp = .add,
    RenderTargetWriteMask: u8 = COLOR_WRITE_ENABLE_ALL,
};

pub const BlendDesc = extern struct {
    AlphaToCoverageEnable: BOOL = com.FALSE,
    IndependentBlendEnable: BOOL = com.FALSE,
    RenderTarget: [8]RenderTargetBlendDesc = @splat(.{}),
};

pub const RasterizerDesc = extern struct {
    FillMode: FillMode = .solid,
    CullMode: CullMode = .none,
    FrontCounterClockwise: BOOL = com.FALSE,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = com.TRUE,
    ScissorEnable: BOOL = com.FALSE,
    MultisampleEnable: BOOL = com.FALSE,
    AntialiasedLineEnable: BOOL = com.FALSE,
};

pub const SamplerDesc = extern struct {
    Filter: Filter,
    AddressU: AddressMode = .clamp,
    AddressV: AddressMode = .clamp,
    AddressW: AddressMode = .clamp,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 1,
    ComparisonFunc: ComparisonFunc = .never,
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = std.math.floatMax(f32),
};

pub const Viewport = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

pub const Box = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*dxgi.Adapter1,
    driver_type: DriverType,
    software: ?*anyopaque,
    flags: u32,
    levels: ?[*]const FeatureLevel,
    level_count: u32,
    sdk_version: u32,
    device: ?*?*Device,
    level: ?*FeatureLevel,
    context: ?*?*DeviceContext,
) callconv(.winapi) HRESULT;

/// ID3D11Resource: any resource, for the calls that take one.
pub const Resource = opaque {
    pub const iid = GUID.parse("dc8e63f3-d12b-4952-b47b-5e45026a862d");
};

pub const Buffer = opaque {
    pub const iid = GUID.parse("48570b85-d1ee-4fcd-a250-eb350722b037");

    pub fn resource(self: *Buffer) *Resource {
        return @ptrCast(self);
    }
};

pub const Texture2D = opaque {
    pub const iid = GUID.parse("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    pub fn resource(self: *Texture2D) *Resource {
        return @ptrCast(self);
    }

    pub fn getDesc(self: *Texture2D, desc: *Texture2DDesc) void {
        method(self, 10, fn (*Texture2D, *Texture2DDesc) callconv(.winapi) void)(self, desc);
    }
};

pub const ShaderResourceView = opaque {};
pub const RenderTargetView = opaque {};
pub const InputLayout = opaque {};
pub const VertexShader = opaque {};
pub const PixelShader = opaque {};
pub const BlendState = opaque {};
pub const RasterizerState = opaque {};
pub const SamplerState = opaque {};

/// ID3D11Device.
pub const Device = opaque {
    pub const iid = GUID.parse("db6f6ddb-ac77-4e88-8253-819df9bbf140");

    pub fn createBuffer(self: *Device, desc: *const BufferDesc, initial: ?*const SubresourceData, out: *?*Buffer) HRESULT {
        return method(self, 3, fn (*Device, *const BufferDesc, ?*const SubresourceData, *?*Buffer) callconv(.winapi) HRESULT)(self, desc, initial, out);
    }

    pub fn createTexture2D(self: *Device, desc: *const Texture2DDesc, initial: ?*const SubresourceData, out: *?*Texture2D) HRESULT {
        return method(self, 5, fn (*Device, *const Texture2DDesc, ?*const SubresourceData, *?*Texture2D) callconv(.winapi) HRESULT)(self, desc, initial, out);
    }

    pub fn createShaderResourceView(self: *Device, res: *Resource, desc: ?*const ShaderResourceViewDesc, out: *?*ShaderResourceView) HRESULT {
        return method(self, 7, fn (*Device, *Resource, ?*const ShaderResourceViewDesc, *?*ShaderResourceView) callconv(.winapi) HRESULT)(self, res, desc, out);
    }

    pub fn createRenderTargetView(self: *Device, res: *Resource, desc: ?*const RenderTargetViewDesc, out: *?*RenderTargetView) HRESULT {
        return method(self, 9, fn (*Device, *Resource, ?*const RenderTargetViewDesc, *?*RenderTargetView) callconv(.winapi) HRESULT)(self, res, desc, out);
    }

    pub fn createInputLayout(self: *Device, elements: []const InputElementDesc, bytecode: []const u8, out: *?*InputLayout) HRESULT {
        return method(self, 11, fn (*Device, [*]const InputElementDesc, u32, [*]const u8, usize, *?*InputLayout) callconv(.winapi) HRESULT)(self, elements.ptr, @intCast(elements.len), bytecode.ptr, bytecode.len, out);
    }

    pub fn createVertexShader(self: *Device, bytecode: []const u8, out: *?*VertexShader) HRESULT {
        return method(self, 12, fn (*Device, [*]const u8, usize, ?*anyopaque, *?*VertexShader) callconv(.winapi) HRESULT)(self, bytecode.ptr, bytecode.len, null, out);
    }

    pub fn createPixelShader(self: *Device, bytecode: []const u8, out: *?*PixelShader) HRESULT {
        return method(self, 15, fn (*Device, [*]const u8, usize, ?*anyopaque, *?*PixelShader) callconv(.winapi) HRESULT)(self, bytecode.ptr, bytecode.len, null, out);
    }

    pub fn createBlendState(self: *Device, desc: *const BlendDesc, out: *?*BlendState) HRESULT {
        return method(self, 20, fn (*Device, *const BlendDesc, *?*BlendState) callconv(.winapi) HRESULT)(self, desc, out);
    }

    pub fn createRasterizerState(self: *Device, desc: *const RasterizerDesc, out: *?*RasterizerState) HRESULT {
        return method(self, 22, fn (*Device, *const RasterizerDesc, *?*RasterizerState) callconv(.winapi) HRESULT)(self, desc, out);
    }

    pub fn createSamplerState(self: *Device, desc: *const SamplerDesc, out: *?*SamplerState) HRESULT {
        return method(self, 23, fn (*Device, *const SamplerDesc, *?*SamplerState) callconv(.winapi) HRESULT)(self, desc, out);
    }

    pub fn getFeatureLevel(self: *Device) FeatureLevel {
        return method(self, 37, fn (*Device) callconv(.winapi) FeatureLevel)(self);
    }

    /// S_OK while the device works; why it went otherwise.
    pub fn getDeviceRemovedReason(self: *Device) HRESULT {
        return method(self, 39, fn (*Device) callconv(.winapi) HRESULT)(self);
    }

    pub fn getImmediateContext(self: *Device) *DeviceContext {
        var out: ?*DeviceContext = null;
        method(self, 40, fn (*Device, *?*DeviceContext) callconv(.winapi) void)(self, &out);
        return out.?;
    }
};

/// ID3D11DeviceContext (the immediate context).
pub const DeviceContext = opaque {
    pub fn vsSetConstantBuffers(self: *DeviceContext, start: u32, bufs: []const ?*Buffer) void {
        method(self, 7, fn (*DeviceContext, u32, u32, [*]const ?*Buffer) callconv(.winapi) void)(self, start, @intCast(bufs.len), bufs.ptr);
    }

    pub fn psSetShaderResources(self: *DeviceContext, start: u32, views: []const ?*ShaderResourceView) void {
        method(self, 8, fn (*DeviceContext, u32, u32, [*]const ?*ShaderResourceView) callconv(.winapi) void)(self, start, @intCast(views.len), views.ptr);
    }

    pub fn psSetShader(self: *DeviceContext, shader: ?*PixelShader) void {
        method(self, 9, fn (*DeviceContext, ?*PixelShader, ?*anyopaque, u32) callconv(.winapi) void)(self, shader, null, 0);
    }

    pub fn psSetSamplers(self: *DeviceContext, start: u32, samplers: []const ?*SamplerState) void {
        method(self, 10, fn (*DeviceContext, u32, u32, [*]const ?*SamplerState) callconv(.winapi) void)(self, start, @intCast(samplers.len), samplers.ptr);
    }

    pub fn vsSetShader(self: *DeviceContext, shader: ?*VertexShader) void {
        method(self, 11, fn (*DeviceContext, ?*VertexShader, ?*anyopaque, u32) callconv(.winapi) void)(self, shader, null, 0);
    }

    pub fn draw(self: *DeviceContext, vertex_count: u32, start: u32) void {
        method(self, 13, fn (*DeviceContext, u32, u32) callconv(.winapi) void)(self, vertex_count, start);
    }

    pub fn map(self: *DeviceContext, res: *Resource, subresource: u32, kind: Map, out: *MappedSubresource) HRESULT {
        return method(self, 14, fn (*DeviceContext, *Resource, u32, Map, u32, *MappedSubresource) callconv(.winapi) HRESULT)(self, res, subresource, kind, 0, out);
    }

    pub fn unmap(self: *DeviceContext, res: *Resource, subresource: u32) void {
        method(self, 15, fn (*DeviceContext, *Resource, u32) callconv(.winapi) void)(self, res, subresource);
    }

    pub fn psSetConstantBuffers(self: *DeviceContext, start: u32, bufs: []const ?*Buffer) void {
        method(self, 16, fn (*DeviceContext, u32, u32, [*]const ?*Buffer) callconv(.winapi) void)(self, start, @intCast(bufs.len), bufs.ptr);
    }

    pub fn iaSetInputLayout(self: *DeviceContext, layout: ?*InputLayout) void {
        method(self, 17, fn (*DeviceContext, ?*InputLayout) callconv(.winapi) void)(self, layout);
    }

    pub fn iaSetVertexBuffers(self: *DeviceContext, start: u32, bufs: []const ?*Buffer, strides: []const u32, offsets: []const u32) void {
        std.debug.assert(bufs.len == strides.len and bufs.len == offsets.len);
        method(self, 18, fn (*DeviceContext, u32, u32, [*]const ?*Buffer, [*]const u32, [*]const u32) callconv(.winapi) void)(self, start, @intCast(bufs.len), bufs.ptr, strides.ptr, offsets.ptr);
    }

    pub fn drawInstanced(self: *DeviceContext, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        method(self, 21, fn (*DeviceContext, u32, u32, u32, u32) callconv(.winapi) void)(self, vertex_count, instance_count, start_vertex, start_instance);
    }

    pub fn iaSetPrimitiveTopology(self: *DeviceContext, topology: Topology) void {
        method(self, 24, fn (*DeviceContext, Topology) callconv(.winapi) void)(self, topology);
    }

    pub fn vsSetShaderResources(self: *DeviceContext, start: u32, views: []const ?*ShaderResourceView) void {
        method(self, 25, fn (*DeviceContext, u32, u32, [*]const ?*ShaderResourceView) callconv(.winapi) void)(self, start, @intCast(views.len), views.ptr);
    }

    pub fn vsSetSamplers(self: *DeviceContext, start: u32, samplers: []const ?*SamplerState) void {
        method(self, 26, fn (*DeviceContext, u32, u32, [*]const ?*SamplerState) callconv(.winapi) void)(self, start, @intCast(samplers.len), samplers.ptr);
    }

    pub fn omSetRenderTargets(self: *DeviceContext, views: []const ?*RenderTargetView) void {
        method(self, 33, fn (*DeviceContext, u32, [*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(self, @intCast(views.len), views.ptr, null);
    }

    pub fn omSetBlendState(self: *DeviceContext, state: ?*BlendState) void {
        method(self, 35, fn (*DeviceContext, ?*BlendState, ?*const [4]f32, u32) callconv(.winapi) void)(self, state, null, 0xffffffff);
    }

    pub fn rsSetState(self: *DeviceContext, state: ?*RasterizerState) void {
        method(self, 43, fn (*DeviceContext, ?*RasterizerState) callconv(.winapi) void)(self, state);
    }

    pub fn rsSetViewports(self: *DeviceContext, viewports: []const Viewport) void {
        method(self, 44, fn (*DeviceContext, u32, [*]const Viewport) callconv(.winapi) void)(self, @intCast(viewports.len), viewports.ptr);
    }

    pub fn rsSetScissorRects(self: *DeviceContext, rects: []const Rect) void {
        method(self, 45, fn (*DeviceContext, u32, [*]const Rect) callconv(.winapi) void)(self, @intCast(rects.len), rects.ptr);
    }

    pub fn copySubresourceRegion(self: *DeviceContext, dst: *Resource, dst_sub: u32, x: u32, y: u32, src: *Resource, src_sub: u32, box: ?*const Box) void {
        method(self, 46, fn (*DeviceContext, *Resource, u32, u32, u32, u32, *Resource, u32, ?*const Box) callconv(.winapi) void)(self, dst, dst_sub, x, y, 0, src, src_sub, box);
    }

    pub fn copyResource(self: *DeviceContext, dst: *Resource, src: *Resource) void {
        method(self, 47, fn (*DeviceContext, *Resource, *Resource) callconv(.winapi) void)(self, dst, src);
    }

    pub fn updateSubresource(self: *DeviceContext, dst: *Resource, sub: u32, box: ?*const Box, data: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
        method(self, 48, fn (*DeviceContext, *Resource, u32, ?*const Box, *const anyopaque, u32, u32) callconv(.winapi) void)(self, dst, sub, box, data, row_pitch, depth_pitch);
    }

    pub fn clearRenderTargetView(self: *DeviceContext, view: *RenderTargetView, color: *const [4]f32) void {
        method(self, 50, fn (*DeviceContext, *RenderTargetView, *const [4]f32) callconv(.winapi) void)(self, view, color);
    }

    pub fn clearState(self: *DeviceContext) void {
        method(self, 110, fn (*DeviceContext) callconv(.winapi) void)(self);
    }

    pub fn flush(self: *DeviceContext) void {
        method(self, 111, fn (*DeviceContext) callconv(.winapi) void)(self);
    }
};

test "layouts" {
    const t = std.testing;
    try t.expectEqual(24, @sizeOf(BufferDesc));
    try t.expectEqual(44, @sizeOf(Texture2DDesc));
    try t.expectEqual(24, @sizeOf(ShaderResourceViewDesc));
    try t.expectEqual(20, @sizeOf(RenderTargetViewDesc));
    try t.expectEqual(32, @sizeOf(RenderTargetBlendDesc));
    try t.expectEqual(264, @sizeOf(BlendDesc));
    try t.expectEqual(40, @sizeOf(RasterizerDesc));
    try t.expectEqual(52, @sizeOf(SamplerDesc));
    try t.expectEqual(24, @sizeOf(Viewport));
    try t.expectEqual(24, @sizeOf(Box));
    // Offsets as mingw-w64's headers give them (checked with zig cc).
    try t.expectEqual(28, @offsetOf(SamplerDesc, "BorderColor"));
    try t.expectEqual(48, @offsetOf(SamplerDesc, "MaxLOD"));
    try t.expectEqual(28, @offsetOf(Texture2DDesc, "Usage"));
    if (@sizeOf(usize) == 8) {
        try t.expectEqual(28, @offsetOf(InputElementDesc, "InstanceDataStepRate"));
        try t.expectEqual(16, @sizeOf(SubresourceData));
        try t.expectEqual(16, @sizeOf(MappedSubresource));
        try t.expectEqual(32, @sizeOf(InputElementDesc));
    }
}
