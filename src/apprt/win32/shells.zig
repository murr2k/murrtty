//! The shells the config editor offers for `command` and
//! `initial-command` (roadmap F1e): those installed here, each as the
//! value a configuration file takes for it. Each is a `direct:` command
//! naming its program by full path, quoted (config/command.zig keeps a
//! quoted path with spaces one argument on Windows), so nothing searches
//! for a bare name. PowerShell gets `-NoLogo`, the start-up flag murrtty's
//! default has, with which its shell integration is still injected.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const c = @import("c.zig");
const text_util = @import("text.zig");
const default_shell = @import("../../os/default_shell.zig");

pub const Shell = struct {
    /// As the menu lists it.
    label: []const u8,
    /// As the file takes it.
    value: []const u8,
};

/// The installed shells, in `alloc` (an arena: nothing is freed one by
/// one): PowerShell 7 (found as murrtty finds the shell it starts with
/// `command` unset), Windows PowerShell, the Command Prompt (`COMSPEC`),
/// each WSL distribution, at its Linux home, and Git Bash.
pub fn list(alloc: Allocator, env: *const EnvMap) ![]Shell {
    var out: std.ArrayList(Shell) = .empty;
    if (try default_shell.findPwsh(alloc, env)) |pwsh| {
        try out.append(alloc, .{ .label = "PowerShell 7", .value = try direct(alloc, pwsh, "-NoLogo") });
    }
    const system = try systemDir(alloc);
    if (system) |sys| {
        const ps = try std.fs.path.join(alloc, &.{ sys, "WindowsPowerShell", "v1.0", "powershell.exe" });
        if (isFile(alloc, ps)) try out.append(alloc, .{ .label = "Windows PowerShell", .value = try direct(alloc, ps, "-NoLogo") });
    }
    const cmd: ?[]const u8 = env.get("COMSPEC") orelse if (system) |sys| try std.fs.path.join(alloc, &.{ sys, "cmd.exe" }) else null;
    if (cmd) |path| if (isFile(alloc, path)) {
        try out.append(alloc, .{ .label = "Command Prompt", .value = try direct(alloc, path, "") });
    };
    if (system) |sys| {
        const wsl = try std.fs.path.join(alloc, &.{ sys, "wsl.exe" });
        if (isFile(alloc, wsl)) for (try wslDistributions(alloc)) |name| {
            const args = try std.fmt.allocPrint(alloc, "-d {s} --cd ~", .{name});
            try out.append(alloc, .{
                .label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{name}),
                .value = try direct(alloc, wsl, args),
            });
        };
    }
    if (env.get("ProgramFiles")) |pf| {
        const bash = try std.fs.path.join(alloc, &.{ pf, "Git", "bin", "bash.exe" });
        if (isFile(alloc, bash)) try out.append(alloc, .{ .label = "Git Bash", .value = try direct(alloc, bash, "--login -i") });
    }
    return out.toOwnedSlice(alloc);
}

/// `program` (a full path, quoted) with `args`, as a `direct:` command.
pub fn direct(alloc: Allocator, program: []const u8, args: []const u8) ![]const u8 {
    if (args.len == 0) return std.fmt.allocPrint(alloc, "direct:\"{s}\"", .{program});
    return std.fmt.allocPrint(alloc, "direct:\"{s}\" {s}", .{ program, args });
}

/// Windows' system folder (System32), or null.
fn systemDir(alloc: Allocator) !?[]u8 {
    var buf: [261]u16 = undefined;
    const n = c.GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
}

fn isFile(alloc: Allocator, path: []const u8) bool {
    const wide = text_util.utf16Lossy(alloc, path) catch return false;
    const attrs = c.GetFileAttributesW(wide.ptr);
    return attrs != c.INVALID_FILE_ATTRIBUTES and attrs & c.FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// The WSL distributions registered for the user (each a subkey of Lxss
/// with its `DistributionName`), in the registry's order. A name holds no
/// spaces (WSL refuses them), so it goes on the command line as it is;
/// one that does is left out.
fn wslDistributions(alloc: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var key: ?c.HKEY = null;
    if (c.RegOpenKeyExW(c.HKEY_CURRENT_USER, c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"), 0, c.KEY_READ, &key) != 0) return out.toOwnedSlice(alloc);
    const lxss = key orelse return out.toOwnedSlice(alloc);
    defer _ = c.RegCloseKey(lxss);
    var i: c.DWORD = 0;
    while (i < 64) : (i += 1) {
        var sub: [256]u16 = undefined;
        var sub_len: c.DWORD = sub.len;
        if (c.RegEnumKeyExW(lxss, i, &sub, &sub_len, null, null, null, null) != 0) break;
        sub[sub_len] = 0;
        var name: [256]u16 = undefined;
        var size: c.DWORD = @sizeOf(@TypeOf(name));
        if (c.RegGetValueW(lxss, @ptrCast(&sub), c.L("DistributionName"), c.RRF_RT_REG_SZ, null, &name, &size) != 0) continue;
        const units = std.mem.sliceTo(&name, 0);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, units) catch continue;
        if (utf8.len == 0 or std.mem.indexOfAny(u8, utf8, " \t\"") != null) continue;
        try out.append(alloc, utf8);
    }
    return out.toOwnedSlice(alloc);
}

test "shells: what is installed, as values the loader takes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: EnvMap = .init(a);
    const shells = try list(a, &env);
    var cmd = false;
    for (shells) |s| {
        try std.testing.expect(std.mem.startsWith(u8, s.value, "direct:\""));
        if (std.mem.eql(u8, s.label, "Command Prompt")) cmd = true;
        const option_list = @import("../../config/option_list.zig");
        if (try option_list.check(std.testing.allocator, "command", s.value)) |message| {
            defer std.testing.allocator.free(message);
            std.debug.print("{s}: {s}\n", .{ s.value, message });
            return error.TestUnexpectedResult;
        }
    }
    // With no COMSPEC, System32's cmd.exe.
    try std.testing.expect(cmd);

    // A program in a folder with spaces stays one argument.
    const Command = @import("../../config/command.zig").Command;
    var parsed: Command = undefined;
    try parsed.parseCLI(a, try direct(a, "C:\\Program Files\\Git\\bin\\bash.exe", "--login -i"));
    try std.testing.expectEqual(@as(usize, 3), parsed.direct.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", parsed.direct[0]);
    try std.testing.expectEqualStrings("-i", parsed.direct[2]);
}
