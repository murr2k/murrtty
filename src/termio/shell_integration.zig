const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    cmd,
    elvish,
    fish,
    nushell,
    powershell,
    zsh,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: config.Command,
};

/// Set up the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse
        return null;

    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .cmd => try setupCmd(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .powershell => try setupPowerShell(
            alloc_arena,
            command,
            resource_dir,
        ),

        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },
    } orelse return null;

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".field_names) |field| {
        const shell = @field(Shell, field);

        var res: TmpResourcesDir = try .init(shell);
        defer res.deinit();

        const result = try setup(
            alloc,
            res.path,
            .{ .shell = "sh" },
            &env,
            shell,
        );
        try testing.expectEqual(shell, result.?.shell);
    }
}

test "shell integration failure" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );

    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}

fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    const arg0 = arg_iter.next() orelse return null;
    const exe = std.fs.path.basename(arg0);

    if (std.mem.eql(u8, "bash", exe)) {
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }

    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;

    // On Windows, PowerShell 7 (pwsh), Windows PowerShell (powershell) and
    // cmd, with or without ".exe" and in any case, as Windows names
    // programs. Not bash.exe: on PATH that is usually WSL's launcher in
    // System32, where bash's injection (--posix) would skip the user's
    // bashrc.
    if (comptime builtin.target.os.tag == .windows) {
        const name = if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe[0 .. exe.len - 4] else exe;
        if (std.ascii.eqlIgnoreCase(name, "pwsh") or std.ascii.eqlIgnoreCase(name, "powershell")) {
            return .powershell;
        }
        if (std.ascii.eqlIgnoreCase(name, "cmd")) return .cmd;
    }

    return null;
}

test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }

    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));

    if (comptime builtin.target.os.tag == .windows) {
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh" }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh.exe -NoLogo" }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "PowerShell.EXE" }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .direct = &.{"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"} }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "cmd.exe" }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "CMD /k echo" }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .direct = &.{"C:\\WINDOWS\\system32\\cmd.exe"} }));
        try testing.expect(try detectShell(alloc, .{ .shell = "bash.exe" }) == null);
        try testing.expect(try detectShell(alloc, .{ .shell = "pwsh-preview" }) == null);
    } else {
        try testing.expect(try detectShell(alloc, .{ .shell = "pwsh" }) == null);
        try testing.expect(try detectShell(alloc, .{ .shell = "cmd" }) == null);
    }
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const field_names = @typeInfo(@TypeOf(features)).@"struct".field_names;
    const capacity: usize = capacity: {
        comptime var n: usize = field_names.len - 1; // commas
        inline for (field_names) |name| n += name.len;
        n += ":steady".len; // cursor value
        break :capacity n;
    };

    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Sort the fields so that the output is deterministic. This is
    // done at comptime so it has no runtime cost
    const fields_sorted: [field_names.len][]const u8 = comptime fields: {
        var fields_sorted: [field_names.len][]const u8 = field_names.*;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };

    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);

            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }

    if (writer.end > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buf[0..writer.end]);
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: blinking cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: steady cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var stack_fallback_buf: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buf, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.allocator());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Preserve an existing ENV value. We're about to overwrite it.
    if (env.get("ENV")) |v| {
        try env.put("GHOSTTY_BASH_ENV", v);
    }

    // Set our new ENV to point to our integration script.
    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.mem.print(
        &script_path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        _ = env.swapRemove("GHOSTTY_BASH_ENV");
        return null;
    }

    try env.put("GHOSTTY_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(global.io(), &environ_map, &home_buf)) |home| {
            var histfile_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const histfile = try std.mem.print(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeSentinel(u8, cmd.buffer.written(), 0) };
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", command.?.shell);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("ENV", "env.sh");

    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("GHOSTTY_BASH_ENV").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", command.?.shell);
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", command.?.shell);
    }
}

test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close(global.io());

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_path);

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state_buf: [4096]u8 = undefined;
    var stack_alloc_state: std.heap.BufferFirstAllocator = .init(&stack_alloc_state_buf, alloc);
    const stack_alloc = stack_alloc_state.allocator();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );

    return true;
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try alloc.print("{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}

/// Set up automatic Nushell shell integration. This works by adding our
/// shell resource directory to the `XDG_DATA_DIRS` environment variable,
/// which Nushell will use to load `nushell/vendor/autoload/ghostty.nu`.
///
/// We then add `--execute 'use ghostty ...'` to the nu command line to
/// automatically enable our shelll features.
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Add our XDG_DATA_DIRS entry (for nushell/vendor/autoload/). This
    // makes our 'ghostty' module automatically available, even if any
    // of the later checks abort the rest of our automatic integration.
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;

    var stack_fallback_buf: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buf, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.allocator());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;

    // Tell nu to immediately "use" all of the exported functions in our
    // 'ghostty' module.
    //
    // We can consider making this more specific based on the set of
    // enabled shell features (e.g. `use ghostty sudo`). At the moment,
    // shell features are all runtime-guarded in the nushell script.
    try cmd.appendArg("--execute 'use ghostty *'");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration module.
    //
    // Unsupported options:
    //  -c / --command      -c is always non-interactive
    //  --lsp               --lsp starts the language server
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeSentinel(u8, cmd.buffer.written(), 0) };
}

test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use ghostty *'", command.?.shell);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}

test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}

test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Set up PowerShell (pwsh 7 and Windows PowerShell 5.1): load our script
/// after the profile, with -NoExit -Command, so it wraps the profile's
/// prompt. The script is read as text and run as a script block rather than
/// run as a .ps1 file, which Windows PowerShell's default execution policy
/// (Restricted) refuses. It is injected only when every argument is a
/// start-up flag we know: anything else (a command, a script, -File, an
/// option we don't know) runs as given, without the integration.
///
/// The result is a direct command (an argv): on Windows a shell command
/// string is split on whitespace, which would break the -Command argument.
fn setupPowerShell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
) !?config.Command {
    const script = try std.fs.path.join(alloc, &.{ resource_dir, "shell-integration", "powershell", "ghostty.ps1" });
    std.Io.Dir.accessAbsolute(global.io(), script, .{}) catch |err| {
        log.warn("unable to find {s}: {}", .{ script, err });
        return null;
    };

    var args: std.ArrayList([:0]const u8) = .empty;
    var iter = try command.argIterator(alloc);
    defer iter.deinit();
    const exe = iter.next() orelse return null;
    try args.append(alloc, try alloc.dupeSentinel(u8, exe, 0));
    var no_exit = false;
    while (iter.next()) |arg| {
        switch (powershellArg(arg)) {
            .flag => {},
            .no_exit => no_exit = true,
            .with_value => {
                try args.append(alloc, try alloc.dupeSentinel(u8, arg, 0));
                const value = iter.next() orelse return null;
                try args.append(alloc, try alloc.dupeSentinel(u8, value, 0));
                continue;
            },
            .other => return null,
        }
        try args.append(alloc, try alloc.dupeSentinel(u8, arg, 0));
    }

    if (!no_exit) try args.append(alloc, "-NoExit");
    try args.append(alloc, "-Command");
    try args.append(alloc, try powershellLoadCommand(alloc, script));
    return .{ .direct = try args.toOwnedSlice(alloc) };
}

/// The PowerShell command that loads `script`: as text into a script block,
/// dot-sourced so its functions land in the session; a failure (a locked
/// down language mode, say) leaves the session as it was.
fn powershellLoadCommand(alloc: Allocator, script: []const u8) ![:0]const u8 {
    // In a single-quoted string, a quote is written twice. PowerShell takes
    // the typographic single quotes (U+2018 to U+201B) as quotes too.
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(alloc);
    var i: usize = 0;
    while (i < script.len) {
        const len: usize = if (std.mem.startsWith(u8, script[i..], "\u{2018}") or
            std.mem.startsWith(u8, script[i..], "\u{2019}") or
            std.mem.startsWith(u8, script[i..], "\u{201a}") or
            std.mem.startsWith(u8, script[i..], "\u{201b}"))
            3
        else if (script[i] == '\'') 1 else 0;
        if (len > 0) {
            try quoted.appendSlice(alloc, script[i..][0..len]);
            try quoted.appendSlice(alloc, script[i..][0..len]);
            i += len;
        } else {
            try quoted.append(alloc, script[i]);
            i += 1;
        }
    }
    return try std.fmt.allocPrintSentinel(
        alloc,
        "try {{ . ([scriptblock]::Create([IO.File]::ReadAllText('{s}'))) }} catch {{}}",
        .{quoted.items},
        0,
    );
}

const PowerShellArg = enum { flag, no_exit, with_value, other };

/// How a start-up argument affects the integration, by the names and the
/// documented abbreviations pwsh and Windows PowerShell both take (with a
/// leading "-", "--" or "/"). Flags that only change how the session starts
/// keep it; anything that runs something or that we don't know doesn't.
fn powershellArg(arg: []const u8) PowerShellArg {
    if (arg.len < 2 or (arg[0] != '-' and arg[0] != '/')) return .other;
    var name = arg[1..];
    if (name[0] == '-') name = name[1..];
    const flags = [_][]const u8{
        "nologo",      "nol", "noprofile", "nop", "noprofileloadtime",
        "interactive", "i",   "login",     "l",   "mta",
        "sta",
    };
    const with_value = [_][]const u8{
        "executionpolicy",  "ex", "ep",
        "workingdirectory", "wd", "wo",
        "windowstyle",      "w",  "settingsfile",
    };
    if (std.ascii.eqlIgnoreCase(name, "noexit") or std.ascii.eqlIgnoreCase(name, "noe")) return .no_exit;
    for (flags) |f| if (std.ascii.eqlIgnoreCase(name, f)) return .flag;
    for (with_value) |f| if (std.ascii.eqlIgnoreCase(name, f)) return .with_value;
    return .other;
}

test "powershell: injected after start-up flags, never with a command" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();
    const script = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "powershell", "ghostty.ps1" });
    const load = try powershellLoadCommand(alloc, script);

    {
        const result = (try setupPowerShell(alloc, .{ .shell = "pwsh" }, res.path)).?;
        try testing.expectEqual(@as(usize, 4), result.direct.len);
        try testing.expectEqualStrings("pwsh", result.direct[0]);
        try testing.expectEqualStrings("-NoExit", result.direct[1]);
        try testing.expectEqualStrings("-Command", result.direct[2]);
        try testing.expectEqualStrings(load, result.direct[3]);
    }
    {
        // Flags stay, with their values; -NoExit isn't given twice.
        const result = (try setupPowerShell(alloc, .{ .shell = "powershell.exe -NoLogo -nop -ExecutionPolicy Bypass --NoExit" }, res.path)).?;
        const want = [_][]const u8{ "powershell.exe", "-NoLogo", "-nop", "-ExecutionPolicy", "Bypass", "--NoExit", "-Command" };
        try testing.expectEqual(want.len + 1, result.direct.len);
        for (want, result.direct[0..want.len]) |a, b| try testing.expectEqualStrings(a, b);
    }
    // A command, a script, an encoded command, no input, an unknown option,
    // or a flag missing its value: left alone.
    for ([_][:0]const u8{
        "pwsh -Command Get-Date",
        "pwsh -c Get-Date",
        "pwsh -File x.ps1",
        "pwsh -f x.ps1",
        "pwsh x.ps1",
        "pwsh -EncodedCommand ZQBjAGgAbwA=",
        "pwsh -ec ZQBjAGgAbwA=",
        "pwsh -NonInteractive",
        "pwsh -CommandWithArgs x",
        "pwsh -NoLog",
        "pwsh -ExecutionPolicy",
    }) |cmd| {
        try testing.expect(try setupPowerShell(alloc, .{ .shell = cmd }, res.path) == null);
    }
    // No script, no injection.
    try testing.expect(try setupPowerShell(alloc, .{ .shell = "pwsh" }, "/nonexistent") == null);
}

test "powershell: the load command quotes the path" {
    const testing = std.testing;
    const cmd = try powershellLoadCommand(testing.allocator, "C:\\it's\\ghostty.ps1");
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings(
        "try { . ([scriptblock]::Create([IO.File]::ReadAllText('C:\\it''s\\ghostty.ps1'))) } catch {}",
        cmd,
    );
    // Typographic quotes end the string too.
    const typographic = try powershellLoadCommand(testing.allocator, "C:\\O\u{2019}Brien\\\u{2018}x\u{201b}\\ghostty.ps1");
    defer testing.allocator.free(typographic);
    try testing.expectEqualStrings(
        "try { . ([scriptblock]::Create([IO.File]::ReadAllText('C:\\O\u{2019}\u{2019}Brien\\\u{2018}\u{2018}x\u{201b}\u{201b}\\ghostty.ps1'))) } catch {}",
        typographic,
    );
}

/// Set up cmd. It has no start-up script to inject, so the integration is
/// in its environment. PROMPT wraps the user's prompt (cmd's default, $P$G,
/// when unset) to report the end of the last command (OSC 133;D, with no
/// status: a prompt can't show %ERRORLEVEL%), the folder as the title (the
/// title feature) and the working directory (OSC 9;9), then 133;P;k=i, the
/// prompt and 133;I. P rather than A: A's fresh-line moves Ghostty's cursor
/// without ConPTY's, which keeps its own and would draw a row off from then
/// on. cmd runs nothing before a command, so there is no 133;C; with 133;I,
/// the line feed after Enter ends the input anyway. A PROMPT that already
/// sends OSC 133 is left alone.
///
/// CLINK_PATH gains our cmd folder, so Clink (https://chrisant996.github.io/clink/),
/// when the user runs it, loads ghostty.lua: it sends the same codes around
/// any Clink prompt, plus 133;C and the exit status.
fn setupCmd(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    const dir = try std.fs.path.join(alloc, &.{ resource_dir, "shell-integration", "cmd" });
    std.Io.Dir.accessAbsolute(global.io(), dir, .{}) catch |err| {
        log.warn("unable to find {s}: {}", .{ dir, err });
        return null;
    };

    const prompt = env.get("PROMPT") orelse "$P$G";
    if (std.ascii.findIgnoreCase(prompt, "]133;") == null) {
        const title = if (hasFeature(env, "title")) "$E]2;$P$E\\" else "";
        try env.put("PROMPT", try std.mem.concat(alloc, u8, &.{
            "$E]133;D$E\\",
            title,
            "$E]9;9;$P$E\\$E]133;P;k=i$E\\",
            prompt,
            "$E]133;I$E\\",
        }));
    }

    if (env.get("CLINK_PATH")) |paths| {
        var it = std.mem.tokenizeScalar(u8, paths, ';');
        const present = while (it.next()) |p| {
            if (std.ascii.eqlIgnoreCase(p, dir)) break true;
        } else false;
        if (!present) try env.put("CLINK_PATH", try std.mem.concat(alloc, u8, &.{ paths, ";", dir }));
    } else {
        try env.put("CLINK_PATH", dir);
    }

    return try command.clone(alloc);
}

/// Whether GHOSTTY_SHELL_FEATURES (see setupFeatures) lists `name`.
fn hasFeature(env: *const EnvMap, name: []const u8) bool {
    const features = env.get("GHOSTTY_SHELL_FEATURES") orelse return false;
    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |feature| {
        const end = std.mem.indexOfScalar(u8, feature, ':') orelse feature.len;
        if (std.mem.eql(u8, feature[0..end], name)) return true;
    }
    return false;
}

test "cmd: PROMPT and CLINK_PATH" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.cmd);
    defer res.deinit();
    const dir = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "cmd" });

    {
        // cmd's default prompt, with the title.
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try env.put("GHOSTTY_SHELL_FEATURES", "cursor:blink,title");
        const result = (try setupCmd(alloc, .{ .shell = "cmd.exe" }, res.path, &env)).?;
        try testing.expectEqualStrings("cmd.exe", result.shell);
        try testing.expectEqualStrings(
            "$E]133;D$E\\$E]2;$P$E\\$E]9;9;$P$E\\$E]133;P;k=i$E\\$P$G$E]133;I$E\\",
            env.get("PROMPT").?,
        );
        try testing.expectEqualStrings(dir, env.get("CLINK_PATH").?);
    }
    {
        // The user's prompt, without the title; their Clink scripts first.
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try env.put("PROMPT", "$T $P$_$G");
        try env.put("CLINK_PATH", "C:\\clink");
        _ = (try setupCmd(alloc, .{ .shell = "cmd.exe" }, res.path, &env)).?;
        try testing.expectEqualStrings(
            "$E]133;D$E\\$E]9;9;$P$E\\$E]133;P;k=i$E\\$T $P$_$G$E]133;I$E\\",
            env.get("PROMPT").?,
        );
        try testing.expectEqualStrings(
            try std.mem.concat(alloc, u8, &.{ "C:\\clink;", dir }),
            env.get("CLINK_PATH").?,
        );
        // Ghostty started from an integrated cmd inherits its environment:
        // nothing doubles.
        try env.put("PROMPT", "$e]133;A$e\\$P$G");
        _ = (try setupCmd(alloc, .{ .shell = "cmd.exe" }, res.path, &env)).?;
        try testing.expectEqualStrings("$e]133;A$e\\$P$G", env.get("PROMPT").?);
        try testing.expectEqualStrings(
            try std.mem.concat(alloc, u8, &.{ "C:\\clink;", dir }),
            env.get("CLINK_PATH").?,
        );
    }
    {
        // No resources, no changes.
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try testing.expect(try setupCmd(alloc, .{ .shell = "cmd.exe" }, "/nonexistent", &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test hasFeature {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try testing.expect(!hasFeature(&env, "title"));
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor:steady,path,title");
    try testing.expect(hasFeature(&env, "cursor"));
    try testing.expect(hasFeature(&env, "title"));
    try testing.expect(!hasFeature(&env, "sudo"));
    try testing.expect(!hasFeature(&env, "tit"));
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Preserve an existing ZDOTDIR value. We're about to overwrite it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR to point to our shell resource directory.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close(global.io());
    try env.put("ZDOTDIR", integ_path);

    return try command.clone(alloc);
}

test "zsh" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("GHOSTTY_ZSH_ZDOTDIR") == null);
}

test "zsh: ZDOTDIR" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("ZDOTDIR", "$HOME/.config/zsh");

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("GHOSTTY_ZSH_ZDOTDIR").?);
}

test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Test helper that creates a temporary resources directory with shell integration paths.
const TmpResourcesDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,
    shell_path: []const u8,

    fn init(shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.mem.print(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.createDirPath(std.testing.io, relative_shell_path);

        const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);

        const shell_path = try std.testing.allocator.print(
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer std.testing.allocator.free(shell_path);

        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/bash/ghostty.bash",
                .data = "",
            }),
            .powershell => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/powershell/ghostty.ps1",
                .data = "",
            }),
            else => {},
        }

        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }

    fn deinit(self: *TmpResourcesDir) void {
        std.testing.allocator.free(self.shell_path);
        std.testing.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
