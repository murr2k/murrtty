//! A sampler (opengl/Sampler.zig's counterpart).
const Self = @This();

const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;

pub const Options = struct {
    gpu: *d3d.Device,
    filter: d3d.Filter = .min_mag_mip_linear,
    address: d3d.AddressMode = .clamp,
};

sampler: *d3d.SamplerState,

pub const Error = error{
    /// A Direct3D 11 call failed.
    D3D11Failed,
};

pub fn init(opts: Options) Error!Self {
    var sampler: ?*d3d.SamplerState = null;
    const desc: d3d.SamplerDesc = .{
        .Filter = opts.filter,
        .AddressU = opts.address,
        .AddressV = opts.address,
        .AddressW = opts.address,
    };
    if (!com.succeeded(opts.gpu.createSamplerState(&desc, &sampler))) return error.D3D11Failed;
    return .{ .sampler = sampler.? };
}

pub fn deinit(self: Self) void {
    com.release(self.sampler);
}
