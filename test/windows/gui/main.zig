//! GUI tests for the Windows port. Usage:
//!
//!   ghostty-gui-test --ghostty <path to a Debug murrtty.exe> [options] [scenario...]
//!
//!   --visible             run on the user's desktop instead of a hidden one
//!   --verbose             print every passing check
//!   --list                list the scenarios, then the tools
//!   --skip <name>         leave a scenario out (repeatable)
//!   --expect-skip <name>  a scenario this machine is known to skip, such as
//!                         pixels where no display is driven (repeatable)
//!
//! GHOSTTY_GUI_GOLDEN (a folder) compares the on-screen scenarios'
//! captures with this machine's golden samples (Harness.golden); a
//! scenario whose captures differ fails.
//!
//! With no scenario names, every scenario runs; tools (picture makers that
//! check nothing) run only when named. A scenario skips because it is an
//! opt-in whose switch is off, because it isn't for this build (the other
//! renderer's), or because this machine can't run it now (no display, a
//! picture on the clipboard, a hot key taken). The summary counts each
//! kind and lists the machine's skips --expect-skip didn't name; under
//! GitHub Actions each becomes a warning, so a run that left scenarios out
//! says so. Exit code 0 when none failed. One run at a time per session: a
//! second run waits for the first. Each run's folder is made under
//! GHOSTTY_GUI_TEST_DIR if set, else %TEMP%.
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
    var skip: std.ArrayList([]const u8) = .empty;
    defer skip.deinit(alloc);
    var expect: std.ArrayList([]const u8) = .empty;
    defer expect.deinit(alloc);
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (std.mem.eql(u8, a, "--ghostty") and i + 1 < args.items.len) {
            i += 1;
            exe = args.items[i];
        } else if (std.mem.eql(u8, a, "--skip") and i + 1 < args.items.len) {
            i += 1;
            if (!known(args.items[i])) return 2;
            try skip.append(alloc, args.items[i]);
        } else if (std.mem.eql(u8, a, "--expect-skip") and i + 1 < args.items.len) {
            i += 1;
            if (!known(args.items[i])) return 2;
            try expect.append(alloc, args.items[i]);
        } else if (std.mem.eql(u8, a, "--visible")) {
            visible = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            for (scenarios.all) |s| if (!s.tool) std.debug.print("{s:<16} {s}\n", .{ s.name, s.about });
            std.debug.print("\ntools, run only when named:\n", .{});
            for (scenarios.all) |s| if (s.tool) std.debug.print("{s:<16} {s}\n", .{ s.name, s.about });
            return 0;
        } else {
            if (!known(a)) return 2;
            try only.append(alloc, a);
        }
    }
    const ghostty = exe orelse {
        std.debug.print("usage: ghostty-gui-test --ghostty <Debug murrtty.exe> [--visible] [--verbose] [--skip <name>] [--expect-skip <name>] [scenario...]\n", .{});
        return 2;
    };

    // Runs in one session share its clipboard and the HKCU registrations
    // the link scenarios make, so a second run (CI next to a development
    // run) waits for the first.
    const lock = w.CreateMutexW(null, w.FALSE, w.L("Local\\GhosttyGuiTest")) orelse {
        std.debug.print("CreateMutexW failed ({d})\n", .{w.GetLastError()});
        return 2;
    };
    defer _ = w.CloseHandle(lock);
    var waited = w.WaitForSingleObject(lock, 0);
    if (waited == w.WAIT_TIMEOUT) {
        std.debug.print("waiting for another GUI test run in this session\n", .{});
        waited = w.WaitForSingleObject(lock, 60 * 60 * 1000);
    }
    if (waited != w.WAIT_OBJECT_0 and waited != w.WAIT_ABANDONED) {
        std.debug.print("gave up waiting for the other GUI test run\n", .{});
        return 2;
    }
    defer _ = w.ReleaseMutex(lock);

    var h = Harness.init(alloc, ghostty, !visible) catch |err| {
        std.debug.print("could not set up the harness: {t}\n", .{err});
        return 2;
    };
    defer h.deinit();
    h.verbose = verbose;
    std.debug.print("ghostty: {s}\ndesktop: {s}\n", .{ ghostty, if (visible) "the user's" else "hidden" });

    const Unexpected = struct { name: []const u8, why: []u8 };
    var unexpected: std.ArrayList(Unexpected) = .empty;
    defer {
        for (unexpected.items) |u| alloc.free(u.why);
        unexpected.deinit(alloc);
    }
    var expected_ran: std.ArrayList([]const u8) = .empty;
    defer expected_ran.deinit(alloc);

    var failed: usize = 0;
    var skipped = std.EnumArray(Harness.SkipKind, usize).initFill(0);
    var ran: usize = 0;
    scenario: for (scenarios.all) |s| {
        if (only.items.len > 0) {
            if (!listed(only.items, s.name)) continue;
        } else if (s.tool) continue;
        if (listed(skip.items, s.name)) continue :scenario;
        ran += 1;
        std.debug.print("{s:<16} ", .{s.name});
        if (verbose) std.debug.print("\n", .{});
        Harness.last_skip = .{};
        const goldens_differing = Harness.golden_stats.differ;
        if (s.run(&h)) |_| {
            if (Harness.golden_stats.differ > goldens_differing) {
                failed += 1;
                std.debug.print("FAILED (golden samples differ)\n", .{});
            } else std.debug.print("ok\n", .{});
            if (listed(expect.items, s.name)) try expected_ran.append(alloc, s.name);
        } else |err| switch (err) {
            error.Skipped => {
                const kind = Harness.last_skip.kind;
                skipped.getPtr(kind).* += 1;
                std.debug.print("skipped\n", .{});
                if (kind == .machine and !listed(expect.items, s.name)) {
                    try unexpected.append(alloc, .{ .name = s.name, .why = try alloc.dupe(u8, Harness.last_skip.why()) });
                }
            },
            else => {
                failed += 1;
                std.debug.print("FAILED ({t})\n", .{err});
                if (listed(expect.items, s.name)) try expected_ran.append(alloc, s.name);
            },
        }
    }

    var total_skipped: usize = 0;
    for (std.enums.values(Harness.SkipKind)) |k| total_skipped += skipped.get(k);
    std.debug.print("{d} of {d} passed", .{ ran - failed - total_skipped, ran });
    if (total_skipped > 0) {
        std.debug.print(", {d} skipped (", .{total_skipped});
        var first = true;
        const parts = [_]struct { Harness.SkipKind, []const u8 }{
            .{ .opt_in, "opt-in" },
            .{ .build, "not for this build" },
            .{ .machine, "by this machine" },
        };
        for (parts) |part| {
            const n = skipped.get(part[0]);
            if (n == 0) continue;
            std.debug.print("{s}{d} {s}", .{ if (first) "" else ", ", n, part[1] });
            first = false;
        }
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});

    const gs = Harness.golden_stats;
    if (gs.matched + gs.recorded + gs.differ > 0) {
        std.debug.print("golden samples ({s}): {d} match, {d} recorded, {d} differ\n", .{
            if (h.golden_key) |k| k else "?", gs.matched, gs.recorded, gs.differ,
        });
    }

    if (unexpected.items.len > 0) {
        std.debug.print("skipped by this machine, not expected (--expect-skip):\n", .{});
        const actions = Harness.optIn("GITHUB_ACTIONS");
        for (unexpected.items) |u| {
            std.debug.print("  {s}: {s}\n", .{ u.name, u.why });
            if (actions) annotate(alloc, u.name, u.why);
        }
    }
    for (expected_ran.items) |name| {
        std.debug.print("expected {s} to skip (--expect-skip), but it ran\n", .{name});
    }

    if (failed == 0) {
        h.cleanup();
        return 0;
    }
    std.debug.print("configs, state dumps and logs kept in {s}\n", .{h.temp_dir});
    return 1;
}

/// A GitHub Actions warning for a scenario the machine skipped, on stdout
/// (where the runner reads workflow commands).
fn annotate(alloc: std.mem.Allocator, name: []const u8, why: []const u8) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    line.print(alloc, "::warning title=GUI scenario skipped::{s}: ", .{name}) catch return;
    // A command's message escapes %, CR and LF.
    for (why) |ch| switch (ch) {
        '%' => line.appendSlice(alloc, "%25") catch return,
        '\r' => line.appendSlice(alloc, "%0D") catch return,
        '\n' => line.appendSlice(alloc, "%0A") catch return,
        else => line.append(alloc, ch) catch return,
    };
    line.append(alloc, '\n') catch return;
    const out = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return;
    var written: w.DWORD = 0;
    _ = w.WriteFile(out, line.items.ptr, @intCast(line.items.len), &written, null);
}

fn listed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Whether `name` is a scenario; prints an error if not.
fn known(name: []const u8) bool {
    for (scenarios.all) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    std.debug.print("unknown scenario '{s}' (try --list)\n", .{name});
    return false;
}
