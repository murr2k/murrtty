//! GUI tests for the Windows port. Usage:
//!
//!   ghostty-gui-test --ghostty <path to a Debug ghostty.exe> [options] [scenario...]
//!
//!   --visible   run on the user's desktop instead of a hidden one
//!   --verbose   print every passing check
//!   --list      list the scenarios
//!
//! With no scenario names, all run. Exit code 0 when all pass.
const std = @import("std");
const w = @import("win.zig");
const Harness = @import("Harness.zig");
const scenarios = @import("scenarios.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    // The command line, from Windows directly.
    var argc: c_int = 0;
    const argv = w.CommandLineToArgvW(w.GetCommandLineW(), &argc) orelse return error.BadCommandLine;
    defer _ = w.LocalFree(@ptrCast(argv));
    var args: std.ArrayList([]u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    for (1..@intCast(argc)) |i| try args.append(alloc, try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv[i])));

    var exe: ?[]const u8 = null;
    var visible = false;
    var verbose = false;
    var only: std.ArrayList([]const u8) = .empty;
    defer only.deinit(alloc);
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (std.mem.eql(u8, a, "--ghostty") and i + 1 < args.items.len) {
            i += 1;
            exe = args.items[i];
        } else if (std.mem.eql(u8, a, "--visible")) {
            visible = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            for (scenarios.all) |s| std.debug.print("{s:<16} {s}\n", .{ s.name, s.about });
            return 0;
        } else {
            for (scenarios.all) |s| {
                if (std.mem.eql(u8, s.name, a)) break;
            } else {
                std.debug.print("unknown scenario '{s}' (try --list)\n", .{a});
                return 2;
            }
            try only.append(alloc, a);
        }
    }
    const ghostty = exe orelse {
        std.debug.print("usage: ghostty-gui-test --ghostty <Debug ghostty.exe> [--visible] [--verbose] [scenario...]\n", .{});
        return 2;
    };

    var h = Harness.init(alloc, ghostty, !visible) catch |err| {
        std.debug.print("could not set up the harness: {t}\n", .{err});
        return 2;
    };
    defer h.deinit();
    h.verbose = verbose;
    std.debug.print("ghostty: {s}\ndesktop: {s}\n", .{ ghostty, if (visible) "the user's" else "hidden" });

    var failed: usize = 0;
    var skipped: usize = 0;
    var ran: usize = 0;
    for (scenarios.all) |s| {
        if (only.items.len > 0) {
            for (only.items) |o| {
                if (std.mem.eql(u8, o, s.name)) break;
            } else continue;
        }
        ran += 1;
        std.debug.print("{s:<16} ", .{s.name});
        if (verbose) std.debug.print("\n", .{});
        if (s.run(&h)) |_| {
            std.debug.print("ok\n", .{});
        } else |err| switch (err) {
            error.Skipped => {
                skipped += 1;
                std.debug.print("skipped\n", .{});
            },
            else => {
                failed += 1;
                std.debug.print("FAILED ({t})\n", .{err});
            },
        }
    }
    std.debug.print("{d} of {d} passed", .{ ran - failed - skipped, ran });
    if (skipped > 0) std.debug.print(", {d} skipped", .{skipped});
    std.debug.print("\n", .{});
    if (failed == 0) {
        h.cleanup();
        return 0;
    }
    std.debug.print("configs, state dumps and logs kept in {s}\n", .{h.temp_dir});
    return 1;
}
