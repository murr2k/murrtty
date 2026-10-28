//! The configuration options as the config editor (roadmap F1) lists them,
//! from the core's own metadata: `Config`'s fields and their types, and
//! each option's documentation (`help_strings`, what `+explain-config`
//! shows). Options upstream adds appear here after a merge with no editor
//! work; a new kind of value lands as text until it is given a kind.
const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const Config = @import("Config.zig");
const formatter = @import("formatter.zig");
const args = @import("../cli/args.zig");

/// How an option's value is edited.
pub const Kind = enum {
    /// True or false.
    toggle,
    /// One of the names in `Option.names` (an enum).
    choice,
    /// A set of the flags in `Option.names`, written `a,no-b`.
    flags,
    /// A whole or real number (some take `unlimited`).
    number,
    /// A color: `#rrggbb` or a name (some take keywords such as
    /// `cell-foreground`).
    color,
    /// A file or folder.
    path,
    /// Several values, a line each (`keybind`, `palette`, `font-family`,
    /// `config-file`, ...).
    list,
    /// Anything else, edited as the text the file holds.
    text,
};

/// When a changed value takes effect, as its documentation says.
pub const Reload = enum {
    /// At once, with the soft reload.
    live,
    /// In terminals opened afterwards.
    new_terminals,
    /// Once murrtty starts again.
    restart,
};

pub const Option = struct {
    name: []const u8,
    kind: Kind,

    /// The names a `choice` takes, or the flags of `flags`; else empty.
    names: []const []const u8,

    /// Whether an empty value unsets it.
    optional: bool,

    /// Its documentation as written above it (Markdown), or above the
    /// option it is grouped under (`font-family-bold` under
    /// `font-family`).
    doc: []const u8,

    pub fn reload(self: *const Option) Reload {
        const restart = [_][]const u8{
            "full restart",
            "application restart",
            "cannot be reloaded",
        };
        const new = [_][]const u8{
            "only affect new",
            "only applies to new",
            "only new terminals",
            "all new terminal surfaces",
            "next terminal surface",
            "applies to new windows",
            "not affect existing",
            "only apply to the next",
        };
        for (restart) |p| if (mentions(self.doc, p)) return .restart;
        for (new) |p| if (mentions(self.doc, p)) return .new_terminals;
        return .live;
    }
};

/// Whether `text` holds `phrase`, ignoring case, with any run of
/// whitespace (a line break within the documentation) matching its space.
fn mentions(text: []const u8, phrase: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        var t = start;
        var p: usize = 0;
        while (p < phrase.len) {
            if (phrase[p] == ' ') {
                if (t >= text.len or !std.ascii.isWhitespace(text[t])) break;
                while (t < text.len and std.ascii.isWhitespace(text[t])) t += 1;
            } else {
                if (t >= text.len or std.ascii.toLower(text[t]) != std.ascii.toLower(phrase[p])) break;
                t += 1;
            }
            p += 1;
        }
        if (p == phrase.len) return true;
    }
    return false;
}

const field_names = @typeInfo(Config).@"struct".field_names;

const option_count = count: {
    var n: usize = 0;
    for (field_names) |f| {
        if (f[0] != '_') n += 1;
    }
    break :count n;
};

const options: [option_count]Option = options: {
    @setEvalBranchQuota(1_000_000);
    var out: [option_count]Option = undefined;
    var i: usize = 0;
    var doc: []const u8 = "";
    for (field_names) |f| {
        if (f[0] == '_') continue;
        if (@hasDecl(help_strings.Config, f)) doc = @field(help_strings.Config, f);
        const T = @FieldType(Config, f);
        const optional = @typeInfo(T) == .optional;
        const V = if (optional) @typeInfo(T).optional.child else T;
        out[i] = .{
            .name = f,
            .kind = kindOf(V),
            .names = namesOf(V),
            .optional = optional,
            .doc = doc,
        };
        i += 1;
    }
    break :options out;
};

/// Every option, in the order `Config` declares them.
pub const all: []const Option = &options;

/// The option named `name`, or null.
pub fn find(name: []const u8) ?*const Option {
    for (all) |*o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

/// The types whose values are lists, a line each. Upstream names its
/// repeatable types `Repeatable...`, so new ones are found without being
/// listed; these are the others.
const list_types = [_][]const u8{ "Keybinds", "Palette", "RemapSet" };

fn kindOf(comptime T: type) Kind {
    if (T == bool) return .toggle;
    if (T == Config.Color or T == Config.TerminalColor or T == Config.BoldColor) return .color;
    if (T == Config.Path) return .path;
    switch (@typeInfo(T)) {
        .int, .float => return .number,
        .@"enum" => return .choice,
        .@"struct" => |info| {
            const short = shortName(T);
            if (std.mem.startsWith(u8, short, "Repeatable")) return .list;
            for (list_types) |n| if (std.mem.eql(u8, short, n)) return .list;
            // A limit: a whole number or `unlimited`.
            if (@hasField(T, "value") and @hasDecl(T, "optional") and @hasDecl(T, "default")) return .number;
            if (info.layout == .@"packed" and !@hasDecl(T, "parseCLI")) {
                for (info.field_names) |name| {
                    if (@FieldType(T, name) != bool) return .text;
                }
                return .flags;
            }
            return .text;
        },
        else => return .text,
    }
}

fn namesOf(comptime T: type) []const []const u8 {
    switch (@typeInfo(T)) {
        .@"enum" => |info| return info.field_names,
        .@"struct" => |info| if (kindOf(T) == .flags) return info.field_names,
        else => {},
    }
    return &.{};
}

/// A type's name without its namespaces: `Config.RepeatableString` is
/// `RepeatableString`, `key_mods.RemapSet` is `RemapSet`.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const generic = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const dot = std.mem.lastIndexOfScalar(u8, full[0..generic], '.');
    return full[if (dot) |d| d + 1 else 0..generic];
}

/// `name`'s value in `config` as a file holds it. A list has a value for
/// each line the formatter writes (an empty list is one empty value, and
/// one the formatter writes nothing for, `link`, has none); any other
/// option has one, taken whole (a value can hold a line break the file
/// can't, which `EditableFile` refuses to write). The caller frees the
/// result with `freeValues`.
pub fn values(alloc: Allocator, config: *const Config, name: []const u8) ![][]u8 {
    const option = find(name) orelse return error.UnknownOption;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    inline for (field_names) |f| {
        if (comptime f[0] == '_') continue;
        if (std.mem.eql(u8, f, option.name)) {
            // The allocating writer fails only when it can't grow.
            formatter.formatEntry(@FieldType(Config, f), f, @field(config, f), &text.writer) catch |err|
                return if (err == error.WriteFailed) error.OutOfMemory else err;
        }
    }

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |v| alloc.free(v);
        out.deinit(alloc);
    }
    // Each entry is "name = value\n": the name and " = " come first.
    const prefix = name.len + 3;
    const written = text.written();
    if (option.kind != .list) {
        if (written.len > 0) {
            const body = std.mem.trimEnd(u8, written, "\n");
            try out.append(alloc, try alloc.dupe(u8, body[@min(body.len, prefix)..]));
        }
        return out.toOwnedSlice(alloc);
    }
    var lines = std.mem.splitScalar(u8, written, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const value = try alloc.dupe(u8, line[@min(line.len, prefix)..]);
        errdefer alloc.free(value);
        try out.append(alloc, value);
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeValues(alloc: Allocator, list: []const []u8) void {
    for (list) |v| alloc.free(v);
    alloc.free(list);
}

/// Whether the loader takes `value` for `name` (null for a bare key),
/// before it is written: null when it does, else the loader's message,
/// owned by the caller. The value is parsed as a file's line is, old
/// spellings through the compatibility handlers included, into a fresh
/// default configuration each time, so one check never sways the next. A
/// `keybind = chain=...` is judged after the defaults' last binding, not
/// the file's line before it; saving checks the whole file.
pub fn check(alloc: Allocator, name: []const u8, value: ?[]const u8) Allocator.Error!?[]u8 {
    var config: Config = try .default(alloc);
    defer config.deinit();
    const arg = if (value) |v|
        try std.fmt.allocPrint(alloc, "--{s}={s}", .{ name, v })
    else
        try std.fmt.allocPrint(alloc, "--{s}", .{name});
    defer alloc.free(arg);
    var iter = args.sliceIterator(&.{arg});
    args.parse(Config, alloc, &config, &iter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try alloc.dupe(u8, @errorName(err)),
    };
    const found = config._diagnostics.items();
    if (found.len == 0) return null;
    return try alloc.dupe(u8, found[0].message);
}

const testing = std.testing;

test "option_list: every option, once" {
    try testing.expectEqual(@typeInfo(@import("key.zig").Key).@"enum".field_names.len, all.len);
    for (all, 0..) |a, i| {
        try testing.expect(a.name[0] != '_');
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}

test "option_list: kinds" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "font-size", .number },
        .{ "window-decoration", .choice },
        .{ "confirm-close-surface", .choice },
        .{ "shell-integration-features", .flags },
        .{ "background", .color },
        .{ "cursor-color", .color },
        .{ "keybind", .list },
        .{ "palette", .list },
        .{ "font-family", .list },
        .{ "config-file", .list },
        .{ "env", .list },
        .{ "key-remap", .list },
        .{ "scrollback-limit-bytes", .number },
        .{ "background-image", .path },
        .{ "theme", .text },
        .{ "working-directory", .text },
        .{ "focus-follows-mouse", .toggle },
        .{ "title", .text },
    };
    for (cases) |c| {
        const o = find(c[0]) orelse return error.TestUnexpectedResult;
        testing.expectEqual(c[1], o.kind) catch |err| {
            std.debug.print("{s}: {t}\n", .{ c[0], o.kind });
            return err;
        };
    }

    const wd = find("window-decoration").?;
    try testing.expect(wd.names.len >= 4);
    try testing.expectEqualStrings("auto", wd.names[0]);
    try testing.expect(find("cursor-color").?.optional);
    try testing.expect(!find("background").?.optional);
    try testing.expect(find("shell-integration-features").?.names.len > 1);
}

test "option_list: documentation, grouped and on its own" {
    const family = find("font-family").?;
    try testing.expect(std.ascii.findIgnoreCase(family.doc, "font") != null);
    try testing.expectEqualStrings(family.doc, find("font-family-bold").?.doc);
    try testing.expect(!std.mem.eql(u8, family.doc, find("font-size").?.doc));
}

test "option_list: when a change takes effect" {
    try testing.expectEqual(Reload.restart, find("language").?.reload());
    try testing.expectEqual(Reload.new_terminals, find("font-codepoint-map").?.reload());
    try testing.expectEqual(Reload.new_terminals, find("command").?.reload());
    try testing.expectEqual(Reload.new_terminals, find("initial-command").?.reload());
    try testing.expectEqual(Reload.new_terminals, find("maximize").?.reload());
    try testing.expectEqual(Reload.live, find("font-size").?.reload());

    // A phrase broken across the documentation's lines still counts.
    try testing.expect(mentions("it applies\nto  new\twindows", "applies to new windows"));
    try testing.expect(!mentions("applies to newer", "applies to new windows"));
}

test "option_list: values as the file holds them" {
    var config: Config = try .default(testing.allocator);
    defer config.deinit();

    const size = try values(testing.allocator, &config, "window-decoration");
    defer freeValues(testing.allocator, size);
    try testing.expectEqual(1, size.len);
    try testing.expectEqualStrings("auto", size[0]);

    const family = try values(testing.allocator, &config, "font-family");
    defer freeValues(testing.allocator, family);
    try testing.expectEqual(1, family.len);
    try testing.expectEqualStrings("", family[0]);

    const palette = try values(testing.allocator, &config, "palette");
    defer freeValues(testing.allocator, palette);
    try testing.expectEqual(256, palette.len);

    const keybind = try values(testing.allocator, &config, "keybind");
    defer freeValues(testing.allocator, keybind);
    try testing.expect(keybind.len > 10);

    // Spaces a value ends with are its own.
    try testing.expect((try check(testing.allocator, "title", "build ")) == null);
    config.title = "build ";
    const title = try values(testing.allocator, &config, "title");
    defer freeValues(testing.allocator, title);
    try testing.expectEqualStrings("build ", title[0]);
    config.title = null;

    try testing.expectError(error.UnknownOption, values(testing.allocator, &config, "no-such-option"));
}

test "option_list: values frees what it made when it fails" {
    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = n });
        const got = values(failing.allocator(), &config, "keybind") catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        freeValues(failing.allocator(), got);
        break;
    }
}

test "option_list: check parses as the loader does" {
    const alloc = testing.allocator;
    const taken = [_]struct { []const u8, ?[]const u8 }{
        .{ "font-size", "14" },
        .{ "window-decoration", "none" },
        .{ "keybind", "ctrl+a=copy_to_clipboard" },
        .{ "focus-follows-mouse", null },
        // Old spellings the compatibility handlers take.
        .{ "copy-on-select", "true" },
        .{ "scrollback-limit", "10000" },
    };
    for (taken) |c| {
        if (try check(alloc, c[0], c[1])) |message| {
            defer alloc.free(message);
            std.debug.print("{s}: {s}\n", .{ c[0], message });
            return error.TestUnexpectedResult;
        }
    }

    const refused = [_]struct { []const u8, ?[]const u8 }{
        .{ "font-size", "big" },
        .{ "window-decoration", "sideways" },
        .{ "no-such-option", "1" },
        .{ "font-size", null },
    };
    for (refused) |c| {
        const message = (try check(alloc, c[0], c[1])) orelse return error.TestUnexpectedResult;
        defer alloc.free(message);
        try testing.expect(message.len > 0);
    }

    // One check doesn't sway the next.
    if (try check(alloc, "keybind", "clear")) |m| {
        alloc.free(m);
        return error.TestUnexpectedResult;
    }
    try testing.expect((try check(alloc, "keybind", "ctrl+b=paste_from_clipboard")) == null);
}
