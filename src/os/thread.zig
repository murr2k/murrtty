const std = @import("std");
const builtin = @import("builtin");

/// The config to spawn Ghostty's long-lived threads with (each terminal's
/// renderer, IO, pty reader and search threads).
///
/// On Windows, std.Thread passes `stack_size` to NtCreateThreadEx as the
/// stack's initial commit, not its reservation (CreateThread treats a size
/// the same way unless told it is a reservation), so every thread committed
/// its whole 16 MB stack up front: 48 MB of commit charge for each terminal
/// (64 MB while it searches), though little of it is ever touched. The
/// reservation is then the process image's stack reserve. When that is at
/// least std's default, a small commit gives the same depth and commits the
/// stack only as it grows. A host whose image reserves less (an app
/// embedding libghostty, 1 MB by MSVC's default) keeps std's default, so its
/// threads keep their 16 MB.
pub fn spawnConfig() std.Thread.SpawnConfig {
    if (comptime builtin.os.tag != .windows) return .{};
    if (imageStackReserve() < std.Thread.SpawnConfig.default_stack_size) return .{};

    // std raises anything smaller to 64 KB, the allocation granularity.
    return .{ .stack_size = 64 * 1024 };
}

/// The process image's SizeOfStackReserve: the stack a new thread reserves
/// when its creator names no reservation.
fn imageStackReserve() usize {
    const base: [*]const u8 = @ptrCast(std.os.windows.peb().ImageBaseAddress);

    // The DOS header's e_lfanew gives the NT headers: a 4-byte signature
    // and the 20-byte file header, then the optional header, whose
    // SizeOfStackReserve is at offset 72 in both PE32 (4 bytes) and PE32+
    // (8 bytes).
    const nt = std.mem.readInt(u32, base[0x3c..][0..4], .little);
    const optional = base + nt + 24;
    return switch (std.mem.readInt(u16, optional[0..2], .little)) {
        0x20b => @intCast(std.mem.readInt(u64, optional[72..][0..8], .little)),
        0x10b => std.mem.readInt(u32, optional[72..][0..4], .little),
        else => 0,
    };
}

test "spawnConfig: a thread reserves the full stack and commits little" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const MEMORY_BASIC_INFORMATION = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };
    const MEM_COMMIT = 0x1000;

    const Usage = struct { reserved: usize = 0, committed: usize = 0 };
    const S = struct {
        extern "kernel32" fn VirtualQuery(
            lpAddress: ?*const anyopaque,
            lpBuffer: *MEMORY_BASIC_INFORMATION,
            dwLength: usize,
        ) callconv(.winapi) usize;

        /// The reservation holding this thread's stack, and how much of it
        /// is committed (guard pages included).
        fn run(out: *Usage) void {
            var probe: u8 = 0;
            std.mem.doNotOptimizeAway(&probe);
            var info: MEMORY_BASIC_INFORMATION = undefined;
            if (VirtualQuery(&probe, &info, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) return;
            const allocation = info.AllocationBase;
            var at: [*]const u8 = @ptrCast(allocation orelse return);
            while (VirtualQuery(at, &info, @sizeOf(MEMORY_BASIC_INFORMATION)) != 0 and
                info.AllocationBase == allocation)
            {
                out.reserved += info.RegionSize;
                if (info.State == MEM_COMMIT) out.committed += info.RegionSize;
                at += info.RegionSize;
            }
        }
    };

    // The test binary reserves std's default, as murrtty.exe does.
    try std.testing.expect(imageStackReserve() >= std.Thread.SpawnConfig.default_stack_size);

    var usage: Usage = .{};
    const thread = try std.Thread.spawn(spawnConfig(), S.run, .{&usage});
    thread.join();
    try std.testing.expect(usage.reserved >= std.Thread.SpawnConfig.default_stack_size);
    try std.testing.expect(usage.committed < 1024 * 1024);
}
