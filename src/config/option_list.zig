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
const Binding = @import("../input/Binding.zig");

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

    /// For `flags`, each flag's state before a value names it: the loader
    /// starts a set of flags from its type's own defaults (`T{}`) and
    /// changes only those the value names. Else empty.
    flag_defaults: []const bool,

    /// Whether an empty value unsets it.
    optional: bool,

    /// For a `number`, whether the file holds a whole number (an integer
    /// type, or a limit).
    integer: bool = false,

    /// For a `number`, whether `unlimited` is a value it takes (a limit).
    unlimited: bool = false,

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
            .flag_defaults = flagDefaultsOf(V),
            .optional = optional,
            .integer = integerOf(V),
            .unlimited = kindOf(V) == .number and @typeInfo(V) == .@"struct",
            .doc = doc,
        };
        i += 1;
    }
    break :options out;
};

/// Every option, in the order `Config` declares them.
pub const all: []const Option = &options;

/// A key binding's action, as the editor's binding page lists it (roadmap
/// F1c): from `Binding.Action`'s fields, so actions upstream adds appear
/// after a merge, each with its documentation (`+list-actions`').
pub const Action = struct {
    name: []const u8,
    /// Whether it takes a value after a colon (`goto_tab:2`); some take
    /// one only optionally.
    takes_value: bool,
    doc: []const u8,
};

const action_fields = @typeInfo(Binding.Action).@"union".field_names;

const action_count = count: {
    var n: usize = 0;
    for (action_fields) |f| {
        if (f[0] != '_') n += 1;
    }
    break :count n;
};

const action_list: [action_count]Action = list: {
    @setEvalBranchQuota(100_000);
    var out: [action_count]Action = undefined;
    var i: usize = 0;
    for (action_fields) |f| {
        if (f[0] == '_') continue;
        out[i] = .{
            .name = f,
            .takes_value = @FieldType(Binding.Action, f) != void,
            .doc = if (@hasDecl(help_strings.KeybindAction, f)) @field(help_strings.KeybindAction, f) else "",
        };
        i += 1;
    }
    break :list out;
};

/// Every action a key binding can take, in the order `Binding.Action`
/// declares them.
pub const actions: []const Action = &action_list;

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

/// Whether a number's file value is a whole number: an integer type, or a
/// limit of one (`Limit(usize, ...)`).
fn integerOf(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        .@"struct" => kindOf(T) == .number and @typeInfo(@FieldType(T, "value")) == .int,
        else => false,
    };
}

fn namesOf(comptime T: type) []const []const u8 {
    switch (@typeInfo(T)) {
        .@"enum" => |info| return info.field_names,
        .@"struct" => |info| if (kindOf(T) == .flags) return info.field_names,
        else => {},
    }
    return &.{};
}

fn flagDefaultsOf(comptime T: type) []const bool {
    if (comptime kindOf(T) != .flags) return &.{};
    const names = @typeInfo(T).@"struct".field_names;
    const d: T = .{};
    var out: [names.len]bool = undefined;
    for (names, 0..) |name, i| out[i] = @field(d, name);
    const final = out;
    return &final;
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

/// Take `value` for `name` into `config` as a file's line would (the config
/// editor's preview, roadmap F1d). The caller has checked it (`check`).
pub fn apply(alloc: Allocator, config: *Config, name: []const u8, value: []const u8) !void {
    const arg = try std.fmt.allocPrint(alloc, "--{s}={s}", .{ name, value });
    defer alloc.free(arg);
    var iter = args.sliceIterator(&.{arg});
    try args.parse(Config, alloc, config, &iter);
}

/// The unit a number shows in (roadmap F1d): a fraction as a percentage,
/// bytes as megabytes, else what its documentation measures it in.
pub const Unit = enum {
    percent,
    points,
    columns,
    rows,
    lines,
    pixels,
    milliseconds,
    seconds,
    /// Millions of bytes (`scrollback-limit-bytes`' default is 50 MB).
    megabytes,
    /// 2^20 bytes (`clipboard-write-limit-bytes`' default is 64 MiB).
    mebibytes,
    /// A contrast ratio, `4.5:1`.
    ratio,
    plain,

    /// A file's number as shown, and back: each by one multiplication or
    /// division by a whole number, so 94.5% is the file's 0.945 and 0.5 MB
    /// its 500000 exactly.
    pub fn toShown(self: Unit, n: f64) f64 {
        return switch (self) {
            .percent => n * 100,
            .megabytes => n / 1e6,
            .mebibytes => n / 1048576,
            else => n,
        };
    }

    pub fn fromShown(self: Unit, n: f64) f64 {
        return switch (self) {
            .percent => n / 100,
            .megabytes => n * 1e6,
            .mebibytes => n * 1048576,
            else => n,
        };
    }

    /// The decimals shown.
    pub fn decimals(self: Unit) u8 {
        return switch (self) {
            .percent, .points, .megabytes, .mebibytes, .ratio => 1,
            .seconds => 2,
            else => 0,
        };
    }

    /// What follows the shown number `n`.
    pub fn suffix(self: Unit, n: f64) []const u8 {
        const one = n == 1;
        return switch (self) {
            .percent => "%",
            .points => " pt",
            .columns => if (one) " column" else " columns",
            .rows => if (one) " row" else " rows",
            .lines => if (one) " line" else " lines",
            .pixels => " px",
            .milliseconds => " ms",
            .seconds => " s",
            .megabytes => " MB",
            .mebibytes => " MiB",
            .ratio => ":1",
            .plain => "",
        };
    }
};

/// How the editor shows and edits a number (roadmap F1d): its unit, a
/// slider for a bounded range or a field with a step down and up
/// (libadwaita's spin row), and the values it takes.
pub const Scale = struct {
    unit: Unit,
    slider: bool = false,
    /// The least and the most it takes, in the file's numbers: the loader
    /// clamps a value beyond them, or it means nothing (a 0 pt font), so the
    /// editor refuses one rather than write what the file wouldn't mean.
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    /// A slider's right end, for a range with no most
    /// (`background-image-opacity` goes past 100%).
    slider_max: ?f64 = null,
    /// A step of the buttons and the arrow keys, in the file's numbers.
    step: f64,
    /// What 0 shows as, where it means something of its own.
    zero: ?[]const u8 = null,

    /// The slider's ends.
    pub fn ends(self: Scale) struct { f64, f64 } {
        return .{ self.min, self.slider_max orelse self.max };
    }

    pub fn takes(self: Scale, n: f64) bool {
        return n >= self.min and n <= self.max;
    }
};

/// The numbers the editor shows as more than their text, from their
/// documentation (the core clamps the opacities and the contrast).
const scales = [_]struct { []const u8, Scale }{
    .{ "background-opacity", .{ .unit = .percent, .slider = true, .min = 0, .max = 1, .step = 0.01 } },
    .{ "background-image-opacity", .{ .unit = .percent, .slider = true, .min = 0, .slider_max = 2, .step = 0.01 } },
    .{ "cursor-opacity", .{ .unit = .percent, .slider = true, .min = 0, .max = 1, .step = 0.01 } },
    .{ "faint-opacity", .{ .unit = .percent, .slider = true, .min = 0, .max = 1, .step = 0.01 } },
    .{ "unfocused-split-opacity", .{ .unit = .percent, .slider = true, .min = 0.15, .max = 1, .step = 0.01 } },
    .{ "bell-audio-volume", .{ .unit = .percent, .slider = true, .min = 0, .max = 1, .step = 0.01 } },
    .{ "minimum-contrast", .{ .unit = .ratio, .slider = true, .min = 1, .max = 21, .step = 0.1 } },
    .{ "font-thicken-strength", .{ .unit = .plain, .slider = true, .min = 0, .max = 255, .step = 1 } },
    .{ "font-size", .{ .unit = .points, .min = 1, .step = 1 } },
    .{ "window-width", .{ .unit = .columns, .min = 0, .step = 1, .zero = "Default" } },
    .{ "window-height", .{ .unit = .rows, .min = 0, .step = 1, .zero = "Default" } },
    .{ "window-position-x", .{ .unit = .pixels, .step = 10 } },
    .{ "window-position-y", .{ .unit = .pixels, .step = 10 } },
    .{ "click-repeat-interval", .{ .unit = .milliseconds, .min = 0, .step = 50, .zero = "System setting" } },
    .{ "abnormal-command-exit-runtime", .{ .unit = .milliseconds, .min = 0, .step = 50, .zero = "Off" } },
    .{ "quick-terminal-animation-duration", .{ .unit = .seconds, .min = 0, .step = 0.05, .zero = "Off" } },
    .{ "image-storage-limit", .{ .unit = .megabytes, .min = 0, .step = 10e6, .zero = "Off" } },
    .{ "scrollback-limit-bytes", .{ .unit = .megabytes, .min = 0, .step = 10e6 } },
    .{ "scrollback-limit-lines", .{ .unit = .lines, .min = 0, .step = 1000 } },
    .{ "clipboard-write-limit-bytes", .{ .unit = .mebibytes, .min = 0, .step = 1048576 } },
};

/// `name`'s scale, if the editor shows it as more than its text.
pub fn scaleOf(name: []const u8) ?Scale {
    for (scales) |s| if (std.mem.eql(u8, s[0], name)) return s[1];
    return null;
}

/// A file's value as a number, or null (not one: `unlimited`, a typo).
pub fn numberOf(value: []const u8) ?f64 {
    const n = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return null;
    return if (std.math.isFinite(n)) n else null;
}

/// `n`, a file's number, as `scale` shows it: in its unit, rounded to the
/// unit's decimals, trailing zeros dropped (94.5%, 100%), with the unit's
/// name or (for a field to type in) bare.
pub fn formatShown(buf: []u8, scale: Scale, n: f64, with_unit: bool) []const u8 {
    if (n == 0 and with_unit) if (scale.zero) |z| return z;
    const decimals = scale.unit.decimals();
    const shown = roundTo(scale.unit.toShown(n), decimals);
    const text = formatFixed(buf, shown, decimals) catch return "";
    if (!with_unit) return text;
    const unit = scale.unit.suffix(shown);
    if (text.len + unit.len > buf.len) return text;
    @memcpy(buf[text.len..][0..unit.len], unit);
    return buf[0 .. text.len + unit.len];
}

/// What was typed into a number's field, in its unit ("94.5", "94.5 %",
/// "13pt"), as a file's number; null if it isn't a number.
pub fn parseShown(scale: Scale, text: []const u8) ?f64 {
    var t = std.mem.trim(u8, text, " \t");
    const unit = std.mem.trim(u8, scale.unit.suffix(2), " ");
    const one = std.mem.trim(u8, scale.unit.suffix(1), " ");
    for ([_][]const u8{ unit, one }) |u| {
        if (u.len > 0 and t.len >= u.len and std.ascii.eqlIgnoreCase(t[t.len - u.len ..], u)) {
            t = std.mem.trimEnd(u8, t[0 .. t.len - u.len], " \t");
            break;
        }
    }
    const n = std.fmt.parseFloat(f64, t) catch return null;
    if (!std.math.isFinite(n)) return null;
    return scale.unit.fromShown(n);
}

/// The decimals a file keeps of a number: a whole number for an integer
/// type, else the shown decimals' worth (94.5% is 0.945).
fn fileDecimals(scale: Scale, integer: bool) u8 {
    if (integer) return 0;
    const extra: u8 = switch (scale.unit) {
        .percent => 2,
        else => 0,
    };
    return scale.unit.decimals() + extra;
}

/// `n` as the file spells it for an option of `scale`, rounded to what the
/// file keeps (`fileDecimals`), trailing zeros dropped.
pub fn fileValue(buf: []u8, scale: Scale, integer: bool, n: f64) []const u8 {
    if (integer) {
        const r = std.math.clamp(@round(n), -9.2e18, 1.8e19);
        if (r < 0) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(r))}) catch "";
        return std.fmt.bufPrint(buf, "{d}", .{@as(u64, @intFromFloat(r))}) catch "";
    }
    const decimals = fileDecimals(scale, integer);
    return formatFixed(buf, roundTo(n, decimals), decimals) catch "";
}

/// `n` moved by `delta` (a step, or a part of one), kept to the range (not
/// the slider's ends: background-image-opacity steps on past 200%), and
/// rounded to what the file keeps.
pub fn stepped(scale: Scale, integer: bool, n: f64, delta: f64) f64 {
    var v = n + delta;
    // A value already past an end (a file's own) moves back toward it, never further.
    if (v > scale.max) v = if (delta > 0) @max(n, scale.max) else scale.max;
    if (v < scale.min) v = if (delta < 0) @min(n, scale.min) else scale.min;
    return roundTo(v, fileDecimals(scale, integer));
}

/// What was typed, as the file spells it: a whole number for an integer
/// type, else to six places (13.25 pt stays 13.25, though shown 13.3), so a
/// typed value Ghostty takes isn't rounded unasked.
pub fn fileValueTyped(buf: []u8, scale: Scale, integer: bool, n: f64) []const u8 {
    if (integer) return fileValue(buf, scale, true, n);
    return formatFixed(buf, roundTo(n, 6), 6) catch "";
}

fn roundTo(v: f64, decimals: u8) f64 {
    const p = std.math.pow(f64, 10, @floatFromInt(decimals));
    const r = @round(v * p) / p;
    // No "-0".
    return if (r == 0) 0 else r;
}

/// `v` to `decimals` places, its trailing zeros (and point) dropped.
fn formatFixed(buf: []u8, v: f64, decimals: u8) ![]const u8 {
    const text = switch (decimals) {
        0 => try std.fmt.bufPrint(buf, "{d:.0}", .{v}),
        1 => try std.fmt.bufPrint(buf, "{d:.1}", .{v}),
        2 => try std.fmt.bufPrint(buf, "{d:.2}", .{v}),
        3 => try std.fmt.bufPrint(buf, "{d:.3}", .{v}),
        4 => try std.fmt.bufPrint(buf, "{d:.4}", .{v}),
        else => try std.fmt.bufPrint(buf, "{d:.6}", .{v}),
    };
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end -= 1;
    return text[0..end];
}

/// The editor's pages, named as a preferences window's would be. Labels
/// say "and", not "&": the group picker is a menu, where "&" marks an
/// access key.
pub const Group = enum {
    fonts,
    colors,
    background,
    cursor,
    window,
    tabs,
    mouse,
    clipboard,
    keyboard,
    shell,
    scrollback,
    notifications,
    quick_terminal,
    gtk,
    terminal,
    platforms,
    other,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .fonts => "Fonts",
            .colors => "Colors",
            .background => "Background",
            .cursor => "Cursor",
            .window => "Window",
            .tabs => "Tabs and Splits",
            .mouse => "Mouse and Selection",
            .clipboard => "Clipboard",
            .keyboard => "Keyboard",
            .shell => "Shell and Commands",
            .scrollback => "Scrollback",
            .notifications => "Notifications and Bell",
            .quick_terminal => "Quick Terminal",
            .gtk => "GTK",
            .terminal => "Terminal",
            .platforms => "macOS and Linux",
            .other => "Other",
        };
    }
};

/// Which page an option goes on, by its name: the first rule it matches,
/// the most particular first (`window-new-tab-position` is a tab's before
/// a window's). An option upstream adds lands by its prefix, else in Other.
pub fn groupOf(name: []const u8) Group {
    const Rule = struct { []const u8, Group, enum { exact, prefix } };
    const rules = [_]Rule{
        .{ "window-new-tab-position", .tabs, .exact },
        .{ "window-show-tab-bar", .tabs, .exact },
        .{ "tab-inherit-working-directory", .tabs, .exact },
        .{ "split-inherit-working-directory", .tabs, .exact },
        .{ "window-inherit-working-directory", .window, .exact },
        .{ "notify-on-command-finish", .notifications, .prefix },
        .{ "gtk-quick-terminal-", .quick_terminal, .prefix },
        .{ "quick-terminal-", .quick_terminal, .prefix },
        .{ "clipboard-codepoint-map", .clipboard, .exact },
        .{ "cursor-", .cursor, .prefix },
        .{ "adjust-cursor-", .cursor, .prefix },
        .{ "font-", .fonts, .prefix },
        .{ "adjust-", .fonts, .prefix },
        .{ "grapheme-width-method", .fonts, .exact },
        .{ "freetype-load-flags", .fonts, .exact },
        .{ "background-", .background, .prefix },
        .{ "theme", .colors, .exact },
        .{ "background", .colors, .exact },
        .{ "foreground", .colors, .exact },
        .{ "palette", .colors, .prefix },
        .{ "selection-foreground", .colors, .exact },
        .{ "selection-background", .colors, .exact },
        .{ "search-", .colors, .prefix },
        .{ "minimum-contrast", .colors, .exact },
        .{ "bold-color", .colors, .exact },
        .{ "faint-opacity", .colors, .exact },
        .{ "alpha-blending", .colors, .exact },
        .{ "selection-", .mouse, .prefix },
        .{ "mouse-", .mouse, .prefix },
        .{ "scroll-to-bottom", .mouse, .exact },
        .{ "copy-on-select", .mouse, .exact },
        .{ "right-click-action", .mouse, .exact },
        .{ "middle-click-action", .mouse, .exact },
        .{ "click-repeat-interval", .mouse, .exact },
        .{ "focus-follows-mouse", .mouse, .exact },
        .{ "link", .mouse, .prefix },
        .{ "clipboard-", .clipboard, .prefix },
        .{ "split-", .tabs, .prefix },
        .{ "unfocused-split-", .tabs, .prefix },
        .{ "window-", .window, .prefix },
        .{ "maximize", .window, .exact },
        .{ "fullscreen", .window, .exact },
        .{ "title", .window, .exact },
        .{ "class", .window, .exact },
        .{ "x11-instance-name", .window, .exact },
        .{ "initial-window", .window, .exact },
        .{ "resize-overlay", .window, .prefix },
        .{ "drag-handle", .window, .exact },
        .{ "confirm-close-surface", .window, .exact },
        .{ "quit-after-last-window-closed", .window, .prefix },
        .{ "undo-timeout", .window, .exact },
        .{ "keybind", .keyboard, .exact },
        .{ "key-remap", .keyboard, .exact },
        .{ "command-palette-entry", .keyboard, .exact },
        .{ "command", .shell, .exact },
        .{ "initial-command", .shell, .exact },
        .{ "working-directory", .shell, .exact },
        .{ "shell-integration", .shell, .prefix },
        .{ "env", .shell, .exact },
        .{ "input", .shell, .exact },
        .{ "wait-after-command", .shell, .exact },
        .{ "abnormal-command-exit-runtime", .shell, .exact },
        .{ "scrollback-", .scrollback, .prefix },
        .{ "scrollbar", .scrollback, .exact },
        .{ "bell-", .notifications, .prefix },
        .{ "app-notifications", .notifications, .exact },
        .{ "desktop-notifications", .notifications, .exact },
        .{ "progress-style", .notifications, .exact },
        .{ "gtk-", .gtk, .prefix },
        .{ "macos-", .platforms, .prefix },
        .{ "linux-", .platforms, .prefix },
        .{ "term", .terminal, .exact },
        .{ "enquiry-response", .terminal, .exact },
        .{ "osc-", .terminal, .prefix },
        .{ "vt-", .terminal, .prefix },
        .{ "title-report", .terminal, .exact },
        .{ "image-storage-limit", .terminal, .exact },
        .{ "custom-shader", .terminal, .prefix },
        .{ "async-backend", .terminal, .exact },
    };
    for (rules) |r| {
        const hit = switch (r[2]) {
            .exact => std.mem.eql(u8, name, r[0]),
            .prefix => std.mem.startsWith(u8, name, r[0]),
        };
        if (hit) return r[1];
    }
    return .other;
}

/// An option's documentation in a line: its first sentence (up to a
/// period and a space or line break, or a blank line), line breaks as
/// spaces and Markdown's backticks dropped, cut to fit `buf`.
pub fn summary(doc: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < doc.len and n < buf.len) : (i += 1) {
        const ch = doc[i];
        if (ch == '\n' and i + 1 < doc.len and doc[i + 1] == '\n') break;
        if (ch == '`') continue;
        buf[n] = if (ch == '\n' or ch == '\r') ' ' else ch;
        n += 1;
        if (ch == '.' and (i + 1 == doc.len or doc[i + 1] == ' ' or doc[i + 1] == '\n')) break;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

/// Whether `option` matches what was typed into the search: every word of
/// it, ignoring case, in its name or its documentation.
pub fn matches(option: *const Option, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t");
    while (words.next()) |word| {
        if (std.ascii.findIgnoreCase(option.name, word) == null and
            std.ascii.findIgnoreCase(option.doc, word) == null) return false;
    }
    return true;
}

/// Whether Ghostty refuses `value` for `name`: values murrtty takes of its
/// own, which would make a configuration Ghostty also reads report an
/// error there (roadmap F1, compatibility with Ghostty's files).
pub fn ghosttyLacks(name: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, name, "shell-integration")) {
        // Windows' shells (roadmap 2.2, 2.3).
        return std.mem.eql(u8, value, "cmd") or std.mem.eql(u8, value, "powershell");
    }
    return false;
}

/// Old spellings the loader still takes for an option renamed since
/// (`Config.compatibility`'s `compatibilityRenamed` entries): the editor
/// reads a line with the old name as the new one's, and a line it changes
/// keeps the name it has (any Ghostty since the rename reads both; one from
/// before reads only the old).
pub const renamed = [_]struct { old: []const u8, new: []const u8 }{
    .{ .old = "background-blur-radius", .new = "background-blur" },
    .{ .old = "adw-toolbar-style", .new = "gtk-toolbar-style" },
    .{ .old = "scrollback-limit", .new = "scrollback-limit-bytes" },
};

/// `Config.compatibility`'s other entries for names no option has now: a
/// removed option whose value the loader maps onto another option's
/// (`bold-is-bright = true` is `bold-color = bright`). The editor shows
/// these lines as they are and doesn't edit them.
const mapped_away = [_][]const u8{
    "cursor-invert-fg-bg",
    "selection-invert-fg-bg",
    "bold-is-bright",
};

/// Whether a line keyed `written` sets the option `name`: its own name, or
/// an old spelling of it (`renamed`).
pub fn keyFor(written: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, written, name)) return true;
    for (renamed) |r| {
        if (std.mem.eql(u8, written, r.old) and std.mem.eql(u8, name, r.new)) return true;
    }
    return false;
}

const testing = std.testing;

test "option_list: every compatibility entry classified" {
    // A new entry upstream fails here until it is put in `renamed` (a plain
    // rename) or `mapped_away` (a removed option's value moved elsewhere),
    // or is an option of today's whose old values the loader maps.
    for (Config.compatibility.keys()) |key| {
        if (find(key) != null) continue;
        const is_renamed = for (renamed) |r| {
            if (std.mem.eql(u8, r.old, key)) break true;
        } else false;
        const is_mapped = for (mapped_away) |m| {
            if (std.mem.eql(u8, m, key)) break true;
        } else false;
        if (!is_renamed and !is_mapped) {
            std.debug.print("unclassified compatibility entry: {s}\n", .{key});
            return error.TestUnexpectedResult;
        }
    }

    // Each rename is one: the old name sets the new option as the new name
    // does, from a value that isn't its default.
    const samples = [_][]const u8{ "20", "flat", "1000" };
    for (renamed, samples) |r, sample| {
        try testing.expect(find(r.new) != null);
        try testing.expect(find(r.old) == null);
        var formatted: [2][]u8 = undefined;
        for ([_][]const u8{ r.old, r.new }, 0..) |key, i| {
            var config: Config = try .default(testing.allocator);
            defer config.deinit();
            const arg = try std.fmt.allocPrint(testing.allocator, "--{s}={s}", .{ key, sample });
            defer testing.allocator.free(arg);
            var iter = args.sliceIterator(&.{arg});
            try args.parse(Config, testing.allocator, &config, &iter);
            try testing.expectEqual(0, config._diagnostics.items().len);
            const v = try values(testing.allocator, &config, r.new);
            defer freeValues(testing.allocator, v);
            formatted[i] = try testing.allocator.dupe(u8, v[0]);
        }
        defer for (formatted) |f| testing.allocator.free(f);
        try testing.expectEqualStrings(formatted[1], formatted[0]);
        var defaults: Config = try .default(testing.allocator);
        defer defaults.deinit();
        const d = try values(testing.allocator, &defaults, r.new);
        defer freeValues(testing.allocator, d);
        try testing.expect(!std.mem.eql(u8, d[0], formatted[0]));
    }

    try testing.expect(keyFor("scrollback-limit", "scrollback-limit-bytes"));
    try testing.expect(keyFor("scrollback-limit-bytes", "scrollback-limit-bytes"));
    try testing.expect(!keyFor("scrollback-limit-bytes", "scrollback-limit"));
    try testing.expect(!keyFor("scrollback-limit", "scrollback-limit-lines"));
}

test "option_list: the actions a binding takes" {
    var new_window: ?Action = null;
    var goto_tab: ?Action = null;
    for (actions) |a| {
        if (std.mem.eql(u8, a.name, "new_window")) new_window = a;
        if (std.mem.eql(u8, a.name, "goto_tab")) goto_tab = a;
        try testing.expect(a.name[0] != '_');
    }
    try testing.expect(!new_window.?.takes_value and new_window.?.doc.len > 0);
    try testing.expect(goto_tab.?.takes_value);
}

test "option_list: flags start from their type's defaults" {
    const o = find("shell-integration-features").?;
    try testing.expectEqual(o.names.len, o.flag_defaults.len);
    const T = Config.ShellIntegrationFeatures;
    const d: T = .{};
    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, i| {
        try testing.expectEqual(@field(d, name), o.flag_defaults[i]);
    }
    try testing.expectEqual(0, find("font-size").?.flag_defaults.len);
}

test "option_list: every option on a page, the particular before the general" {
    try testing.expectEqual(Group.tabs, groupOf("window-new-tab-position"));
    try testing.expectEqual(Group.window, groupOf("window-decoration"));
    try testing.expectEqual(Group.cursor, groupOf("cursor-style"));
    try testing.expectEqual(Group.cursor, groupOf("adjust-cursor-thickness"));
    try testing.expectEqual(Group.fonts, groupOf("adjust-cell-width"));
    try testing.expectEqual(Group.colors, groupOf("background"));
    try testing.expectEqual(Group.background, groupOf("background-opacity"));
    try testing.expectEqual(Group.colors, groupOf("selection-foreground"));
    try testing.expectEqual(Group.mouse, groupOf("selection-word-chars"));
    try testing.expectEqual(Group.notifications, groupOf("notify-on-command-finish-after"));
    try testing.expectEqual(Group.quick_terminal, groupOf("gtk-quick-terminal-layer"));
    try testing.expectEqual(Group.gtk, groupOf("gtk-titlebar"));
    try testing.expectEqual(Group.platforms, groupOf("macos-option-as-alt"));
    try testing.expectEqual(Group.shell, groupOf("command"));
    try testing.expectEqual(Group.other, groupOf("auto-update"));
    // No page is left empty, and Other holds only a few.
    var counts: [@typeInfo(Group).@"enum".field_names.len]usize = @splat(0);
    for (all) |o| counts[@intFromEnum(groupOf(o.name))] += 1;
    for (counts, 0..) |n, g| {
        testing.expect(n > 0) catch |err| {
            std.debug.print("empty page {t}\n", .{@as(Group, @enumFromInt(g))});
            return err;
        };
    }
    try testing.expect(counts[@intFromEnum(Group.other)] < 12);
}

test "option_list: summary, search and what Ghostty lacks" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("The x option.", summary("The `x` option. More", &buf));
    try testing.expectEqualStrings("Cut at", summary("Cut at the buffer", buf[0..7]));
    try testing.expectEqualStrings("Font size in points.", summary("Font size in\npoints. This value can be", &buf));
    try testing.expectEqualStrings("A first paragraph", summary("A first paragraph\n\nThe second.", &buf));
    try testing.expectEqualStrings("Uses x.y in it.", summary("Uses x.y in it. Then", &buf));

    const size = find("font-size").?;
    try testing.expect(matches(size, ""));
    try testing.expect(matches(size, "FONT size"));
    try testing.expect(matches(size, "points"));
    try testing.expect(!matches(size, "font palette"));

    try testing.expect(ghosttyLacks("shell-integration", "powershell"));
    try testing.expect(ghosttyLacks("shell-integration", "cmd"));
    try testing.expect(!ghosttyLacks("shell-integration", "detect"));
    try testing.expect(!ghosttyLacks("font-family", "cmd"));
}

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

test "option_list: every scale is a number's, its range one the file takes" {
    for (scales) |s| {
        const o = find(s[0]) orelse {
            std.debug.print("scale for no option: {s}\n", .{s[0]});
            return error.TestUnexpectedResult;
        };
        testing.expectEqual(Kind.number, o.kind) catch |err| {
            std.debug.print("{s}: {t}\n", .{ s[0], o.kind });
            return err;
        };
        const lo, const hi = s[1].ends();
        try testing.expect(lo < hi);
        if (s[1].slider) try testing.expect(std.math.isFinite(lo) and std.math.isFinite(hi));
        try testing.expect(s[1].step > 0);
        // A step either way from the default is a value the loader takes,
        // as the file spells it.
        var defaults: Config = try .default(testing.allocator);
        defer defaults.deinit();
        const d = try values(testing.allocator, &defaults, s[0]);
        defer freeValues(testing.allocator, d);
        if (d.len == 0) continue;
        const n = numberOf(d[0]) orelse continue;
        for ([_]f64{ -s[1].step, s[1].step }) |delta| {
            var buf: [64]u8 = undefined;
            const v = fileValue(&buf, s[1], o.integer, stepped(s[1], o.integer, n, delta));
            if (try check(testing.allocator, s[0], v)) |message| {
                defer testing.allocator.free(message);
                std.debug.print("{s} = {s}: {s}\n", .{ s[0], v, message });
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expect(find("font-thicken-strength").?.integer);
    try testing.expect(find("window-width").?.integer);
    try testing.expect(!find("background-opacity").?.integer);
    try testing.expect(find("scrollback-limit-bytes").?.integer);
    try testing.expect(find("scrollback-limit-bytes").?.unlimited);
    try testing.expect(!find("window-width").?.unlimited);
    try testing.expect(scaleOf("background-opacity").?.slider);
    try testing.expect(scaleOf("title") == null);
}

test "option_list: numbers as the editor shows them and the file keeps them" {
    var buf: [64]u8 = undefined;
    const opacity = scaleOf("background-opacity").?;
    try testing.expectEqualStrings("94.5%", formatShown(&buf, opacity, 0.945, true));
    try testing.expectEqualStrings("94.5", formatShown(&buf, opacity, 0.945, false));
    try testing.expectEqualStrings("100%", formatShown(&buf, opacity, 1, true));
    try testing.expectEqualStrings("100%", formatShown(&buf, opacity, 0.99999, true));
    try testing.expectEqualStrings("0%", formatShown(&buf, opacity, 0, true));
    try testing.expectEqualStrings("0%", formatShown(&buf, opacity, -0.0001, true));
    try testing.expectEqualStrings("0.945", fileValue(&buf, opacity, false, 0.945));
    try testing.expectEqualStrings("0.95", fileValue(&buf, opacity, false, 0.95));
    try testing.expectEqualStrings("1", fileValue(&buf, opacity, false, 1));
    try testing.expectEqualStrings("0.945", fileValue(&buf, opacity, false, 0.94500000001));

    try testing.expectEqualStrings("Default", formatShown(&buf, scaleOf("window-width").?, 0, true));
    try testing.expectEqualStrings("0", formatShown(&buf, scaleOf("window-width").?, 0, false));
    try testing.expectEqualStrings("80 columns", formatShown(&buf, scaleOf("window-width").?, 80, true));
    try testing.expectEqualStrings("1 row", formatShown(&buf, scaleOf("window-height").?, 1, true));
    try testing.expectEqualStrings("4.5:1", formatShown(&buf, scaleOf("minimum-contrast").?, 4.5, true));
    try testing.expectEqualStrings("320 MB", formatShown(&buf, scaleOf("image-storage-limit").?, 320e6, true));
    try testing.expectEqualStrings("64 MiB", formatShown(&buf, scaleOf("clipboard-write-limit-bytes").?, 64 * 1048576, true));
    try testing.expectEqualStrings("0.2 s", formatShown(&buf, scaleOf("quick-terminal-animation-duration").?, 0.2, true));
    try testing.expectEqualStrings("13.5 pt", formatShown(&buf, scaleOf("font-size").?, 13.5, true));
    try testing.expectEqualStrings("-20 px", formatShown(&buf, scaleOf("window-position-x").?, -20, true));

    // Typed in the shown unit, with or without its name.
    try testing.expectEqual(@as(?f64, 0.945), parseShown(opacity, "94.5"));
    try testing.expectEqual(@as(?f64, 0.945), parseShown(opacity, " 94.5 % "));
    try testing.expectEqual(@as(?f64, 13.5), parseShown(scaleOf("font-size").?, "13.5pt"));
    try testing.expectEqual(@as(?f64, 1), parseShown(scaleOf("window-height").?, "1 row"));
    try testing.expectEqual(@as(?f64, 500000), parseShown(scaleOf("image-storage-limit").?, "0.5 MB"));
    try testing.expectEqual(@as(?f64, null), parseShown(opacity, "lots"));
    try testing.expectEqual(@as(?f64, null), parseShown(opacity, "inf"));
    try testing.expectEqual(@as(?f64, null), parseShown(opacity, ""));
    try testing.expectEqualStrings("500000", fileValue(&buf, scaleOf("image-storage-limit").?, true, 500000.4));
    try testing.expectEqualStrings("-20", fileValue(&buf, scaleOf("window-position-x").?, true, -20));

    try testing.expect(opacity.takes(0) and opacity.takes(1) and !opacity.takes(1.01));
    try testing.expect(!scaleOf("unfocused-split-opacity").?.takes(0.1));

    // Steps stay within the slider, rounded to what the file keeps.
    try testing.expectEqual(@as(f64, 0.955), stepped(opacity, false, 0.945, 0.01));
    try testing.expectEqual(@as(f64, 1), stepped(opacity, false, 0.995, 0.01));
    try testing.expectEqual(@as(f64, 0), stepped(opacity, false, 0.004, -0.01));
    try testing.expectEqual(@as(f64, 0.946), stepped(opacity, false, 0.945, 0.001));
    // A file's value past the end only moves back toward it.
    try testing.expectEqual(@as(f64, 1.5), stepped(opacity, false, 1.5, 0.01));
    try testing.expectEqual(@as(f64, 1), stepped(opacity, false, 1.5, -0.01));
    try testing.expectEqual(@as(f64, 14), stepped(scaleOf("font-size").?, false, 13, 1));
    // Past the slider's end where the range goes on.
    const image = scaleOf("background-image-opacity").?;
    try testing.expectEqual(@as(f64, 3.01), stepped(image, false, 3, 0.01));
    try testing.expectEqual(@as(f64, 2.99), stepped(image, false, 3, -0.01));

    // Typed values keep their places.
    try testing.expectEqualStrings("13.25", fileValueTyped(&buf, scaleOf("font-size").?, false, 13.25));
    try testing.expectEqualStrings("0.9455", fileValueTyped(&buf, opacity, false, 0.9455));
    try testing.expectEqualStrings("0.945", fileValueTyped(&buf, opacity, false, 0.945));
    try testing.expectEqualStrings("14", fileValueTyped(&buf, scaleOf("window-width").?, true, 13.6));
}

test "option_list: apply takes a value as a file's line" {
    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    try apply(testing.allocator, &config, "background-opacity", "0.945");
    try testing.expectEqual(@as(f64, 0.945), config.@"background-opacity");
    try apply(testing.allocator, &config, "window-width", "120");
    try testing.expectEqual(@as(u32, 120), config.@"window-width");
    try testing.expectEqual(0, config._diagnostics.items().len);
}
