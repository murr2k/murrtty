//! Buffers of equal items (opengl/buffer.zig's counterpart): dynamic,
//! written whole each sync through a discarding Map, grown to twice what
//! is asked when too small.
const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    gpu: *d3d.Device,
    ctx: *d3d.DeviceContext,
    kind: Kind,

    pub const Kind = enum {
        /// Per-instance data (slot 0).
        vertex,
        /// The uniforms (b1).
        constant,
        /// A storage buffer: a structured buffer and its view (t2 on).
        storage,
    };
};

/// What a render pass step binds.
pub const Raw = struct {
    buf: *d3d.Buffer,
    /// A storage buffer's view.
    srv: ?*d3d.ShaderResourceView = null,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: Raw,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Allocated length, in `T`s.
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            const n = @max(len, 1);
            return .{ .buffer = try create(opts, n, null), .opts = opts, .len = n };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            if (data.len == 0) return init(opts, 1);
            return .{ .buffer = try create(opts, data.len, data), .opts = opts, .len = data.len };
        }

        pub fn deinit(self: Self) void {
            release(self.buffer);
        }

        /// Replace the contents with `data`, growing the buffer (to twice
        /// `data`'s length) when it doesn't fit.
        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len > self.len) try self.grow(data.len * 2);
            if (data.len == 0) return;
            const dst = try self.map();
            defer self.opts.ctx.unmap(self.buffer.buf.resource(), 0);
            @memcpy(dst[0..data.len], data);
        }

        /// sync from several lists, one after another. Returns the items
        /// written.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total: usize = 0;
            for (lists) |list| total += list.items.len;
            if (total > self.len) try self.grow(total * 2);
            if (total == 0) return 0;
            const dst = try self.map();
            defer self.opts.ctx.unmap(self.buffer.buf.resource(), 0);
            var i: usize = 0;
            for (lists) |list| {
                @memcpy(dst[i..][0..list.items.len], list.items);
                i += list.items.len;
            }
            return total;
        }

        fn grow(self: *Self, len: usize) !void {
            const next = try create(self.opts, len, null);
            release(self.buffer);
            self.buffer = next;
            self.len = len;
        }

        fn map(self: *Self) ![*]T {
            var mapped: d3d.MappedSubresource = .{};
            const hr = self.opts.ctx.map(self.buffer.buf.resource(), 0, .write_discard, &mapped);
            if (!com.succeeded(hr)) {
                log.warn("mapping a buffer failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
                return error.D3D11Failed;
            }
            return @ptrCast(@alignCast(mapped.pData.?));
        }

        fn create(opts: Options, len: usize, data: ?[]const T) !Raw {
            var bytes: u32 = @intCast(len * @sizeOf(T));
            if (opts.kind == .constant) bytes = std.mem.alignForward(u32, bytes, 16);
            const desc: d3d.BufferDesc = .{
                .ByteWidth = bytes,
                .Usage = .dynamic,
                .BindFlags = switch (opts.kind) {
                    .vertex => d3d.BIND_VERTEX_BUFFER,
                    .constant => d3d.BIND_CONSTANT_BUFFER,
                    .storage => d3d.BIND_SHADER_RESOURCE,
                },
                .CPUAccessFlags = d3d.CPU_ACCESS_WRITE,
                .MiscFlags = if (opts.kind == .storage) d3d.RESOURCE_MISC_BUFFER_STRUCTURED else 0,
                .StructureByteStride = if (opts.kind == .storage) @sizeOf(T) else 0,
            };
            // A constant buffer rounds up: copy the data into its size.
            var initial: ?d3d.SubresourceData = null;
            var padded: [256]u8 align(16) = @splat(0);
            if (data) |d| {
                if (opts.kind == .constant and bytes != d.len * @sizeOf(T)) {
                    if (bytes > padded.len) return error.D3D11Failed;
                    @memcpy(padded[0 .. d.len * @sizeOf(T)], std.mem.sliceAsBytes(d));
                    initial = .{ .pSysMem = &padded };
                } else {
                    initial = .{ .pSysMem = d.ptr };
                }
            }
            var buf: ?*d3d.Buffer = null;
            const hr = opts.gpu.createBuffer(&desc, if (initial) |*i| i else null, &buf);
            if (!com.succeeded(hr)) {
                log.warn("creating a buffer of {d} bytes failed hr=0x{x:0>8}", .{ bytes, @as(u32, @bitCast(hr)) });
                return error.D3D11Failed;
            }
            errdefer com.release(buf.?);
            var srv: ?*d3d.ShaderResourceView = null;
            if (opts.kind == .storage) {
                const view: d3d.ShaderResourceViewDesc = .{
                    .Format = .unknown,
                    .ViewDimension = .buffer,
                    .u = .{ .Buffer = .{ .FirstElement = 0, .NumElements = @intCast(len) } },
                };
                if (!com.succeeded(opts.gpu.createShaderResourceView(buf.?.resource(), &view, &srv))) return error.D3D11Failed;
            }
            return .{ .buf = buf.?, .srv = srv };
        }

        fn release(raw: Raw) void {
            if (raw.srv) |v| com.release(v);
            com.release(raw.buf);
        }
    };
}
