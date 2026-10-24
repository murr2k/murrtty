//! Deciding whether a link from terminal output may open (roadmap 0.1).
//!
//! The core marks the links that terminal output controls as untrusted:
//! OSC 8 hyperlink targets (`osc8`) and text matched by a `link` pattern
//! (`unknown`). It leaves vetting them to the runtime, and if the runtime
//! declines a link it falls back to the generic opener, `rundll32
//! url.dll,FileProtocolHandler`, which hands anything to the shell:
//! programs, shortcuts, UNC paths (opening one sends the user's credentials
//! to that host), any protocol handler. So the runtime takes every link and
//! this decides what happens to it. The policy follows the macOS app's
//! (macos/Sources/Helpers/UntrustedURL.swift):
//!
//! - Text with control, bidirectional or invisible characters is denied: it
//!   can make the target read differently from what opens.
//! - http and https with a host, and mailto with an address, open.
//! - A local file of an inert type (text, source code, images, media, PDF)
//!   opens. A file that could run code is denied, judged by its extension
//!   and by the program that opens it; any other file asks first, naming
//!   the file and that program. A directory opens in the default file
//!   manager.
//! - Remote (UNC), device and relative paths are denied, and so are file
//!   URLs that name a host and paths through a symbolic link, which can
//!   lead to another computer.
//! - A few schemes with a history of abuse are denied. Any other scheme
//!   asks first, showing the whole target.
//! - URLs reach their handler percent-encoded where its command line would
//!   split them, as browsers do.
//!
//! `classify` judges the text alone; `decide` adds what only the file
//! system can answer.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32);

/// Longer targets are denied: a confirmation has to show all of one.
pub const max_len = 4096;

pub const Reason = enum {
    malformed,
    unsafe_characters,
    invalid_web_url,
    remote_file,
    special_path,
    relative_path,
    symbolic_link,
    not_found,
    unsafe_file,
    blocked_scheme,
    too_long,

    pub fn message(self: Reason) []const u8 {
        return switch (self) {
            .malformed => "The target is not a valid link.",
            .unsafe_characters => "The target contains control, invisible or text-reversing characters.",
            .invalid_web_url => "The web link does not name a valid host.",
            .remote_file => "The target is a file on another computer. Opening it would connect to that computer.",
            .special_path => "The target is a device, a stream or another special path.",
            .relative_path => "The target is not an absolute path.",
            .symbolic_link => "The path goes through a symbolic link, which can lead anywhere, including another computer.",
            .not_found => "The file does not exist or cannot be accessed.",
            .unsafe_file => "Opening this file could run code.",
            .blocked_scheme => "Links of this type can run code and are always blocked.",
            .too_long => "The target is too long to show.",
        };
    }
};

pub const Verb = enum {
    /// The target's default verb: what a double-click in Explorer does.
    default,
    /// No verb: show the item selected in its folder.
    select,
};

/// Something to open.
pub const Target = struct {
    verb: Verb = .default,
    /// A URL for its scheme's handler; with `item`, an absolute path.
    value: []u8,
    /// Open `value` as exactly that file system item (see `launch`).
    item: bool = false,
};

pub const Decision = union(enum) {
    open: Target,
    /// Ask first: a URL whose scheme nothing here vetted, or a file of a
    /// type not known to be inert.
    confirm: Target,
    deny: Denial,

    pub fn deinit(self: Decision, alloc: Allocator) void {
        switch (self) {
            .open, .confirm => |t| alloc.free(t.value),
            .deny => |d| alloc.free(d.target),
        }
    }
};

pub const Denial = struct {
    reason: Reason,
    /// The target escaped for display (see `display`).
    target: []u8,
    /// False if `target` is only the start of it (a target too long to
    /// show), so there is nothing whole to copy.
    complete: bool = true,
};

/// What the text of a link says it is.
pub const Class = union(enum) {
    deny: Reason,
    /// http, https or mailto: opens as it is.
    web,
    /// Any other scheme: asks first.
    custom,
    /// A drive-absolute path, still to be checked on disk (owned).
    path: []u8,
};

/// Schemes denied outright: their handlers have run code from a link
/// (ms-msdt, search-ms, ms-officecmd, ms-appinstaller, hcp), or they are
/// script, help-file or shell-namespace protocols.
const blocked_schemes = [_][]const u8{
    "ms-msdt",         "search-ms", "search",      "ms-search", "ms-officecmd",
    "ms-appinstaller", "ms-cxh",    "ms-cxh-full", "hcp",       "ms-its",
    "its",             "mk",        "mhtml",       "vbscript",  "javascript",
    "jscript",         "shell",
};

/// Extensions that run code, or open something other than themselves,
/// whatever this machine's settings say.
const unsafe_extensions = [_][]const u8{
    // Programs and scripts (the default %PATHEXT%, and more).
    ".exe",         ".com",          ".bat",               ".cmd",        ".vbs",                ".vbe",
    ".js",          ".jse",          ".wsf",               ".wsh",        ".msc",                ".ps1",
    ".psm1",        ".psd1",         ".scr",               ".pif",        ".cpl",                ".hta",
    ".jar",         ".jnlp",         ".msi",               ".msp",        ".mst",                ".dll",
    ".sys",         ".ocx",          ".reg",               ".inf",        ".chm",                ".gadget",
    ".application", ".appref-ms",    ".diagcab",           ".diagcfg",    ".diagpkg",            ".xbap",
    ".vsto",        ".xll",          ".py",                ".pyw",        ".pyz",                ".pyzw",
    ".pyc",         ".pyo",          ".rb",                ".rbw",        ".pl",                 ".tcl",
    ".ahk",         ".au3",          ".sh",                ".msstyles",   ".themepack",          ".deskthemepack",
    ".rdp",         ".msrcincident", ".wcx",
    // Shortcuts, redirects and installers, which open another target.
                  ".lnk",        ".url",                ".website",
    ".scf",         ".library-ms",   ".settingcontent-ms", ".search-ms",  ".searchconnector-ms", ".appinstaller",
    ".appx",        ".appxbundle",   ".msix",              ".msixbundle",
    // Disk images: they mount, and what they hold escapes the download
    // warning.
    ".iso",                ".img",
    ".vhd",         ".vhdx",
};

/// Types that open as data: these open without asking, unless the program
/// registered for them runs code (see `code_runners`).
const inert_extensions = [_][]const u8{
    // Text and data.
    ".txt",   ".log",   ".md",  ".markdown", ".rst", ".csv",  ".tsv",  ".json",
    ".jsonl", ".yaml",  ".yml", ".toml",     ".ini", ".cfg",  ".conf", ".xml",
    ".diff",  ".patch",
    // Source code.
    ".c",   ".h",        ".cc",  ".cpp",  ".cxx",  ".hh",
    ".hpp",   ".hxx",   ".zig", ".zon",      ".rs",  ".go",   ".java", ".kt",
    ".cs",    ".swift", ".m",   ".mm",       ".s",   ".asm",  ".v",    ".sv",
    ".svh",   ".vhdl",  ".xdc", ".css",
    // Images, audio, video and PDF.
         ".png", ".jpg",  ".jpeg", ".gif",
    ".bmp",   ".webp",  ".tif", ".tiff",     ".ico", ".heic", ".avif", ".mp3",
    ".wav",   ".flac",  ".ogg", ".opus",     ".m4a", ".aac",  ".mp4",  ".m4v",
    ".mkv",   ".webm",  ".mov", ".avi",      ".wmv", ".pdf",
};

/// Programs that run the file they are given, or load code from it. A file
/// whose registered program is one of these is denied, whatever its
/// extension. Names without ".exe"; "python" and "autohotkey" also match as
/// prefixes (python3.12, autohotkey64).
const code_runners = [_][]const u8{
    "py",         "pyw",              "python", "pythonw",  "wscript",  "cscript",
    "powershell", "powershell_ise",   "pwsh",   "cmd",      "bash",     "sh",
    "wsl",        "mshta",            "msdt",   "rundll32", "regsvr32", "regedit",
    "msiexec",    "presentationhost", "mstsc",  "msra",     "xwizard",  "hh",
    "mmc",        "control",          "java",   "javaw",    "javaws",   "node",
    "perl",       "ruby",             "rubyw",  "tclsh",    "wish",     "autoit3",
    "dfsvc",      "autohotkey",
};

/// Judge a link by its text: deny it, open or confirm it, or check the
/// path it names on disk.
pub fn classify(alloc: Allocator, raw: []const u8) Allocator.Error!Class {
    if (raw.len == 0) return .{ .deny = .malformed };
    if (raw.len > max_len) return .{ .deny = .too_long };
    if (!safeText(raw)) return .{ .deny = .unsafe_characters };

    const end = schemeEnd(raw) orelse return pathClass(alloc, raw);
    // A one-letter scheme is a drive: C:\x, or the drive-relative C:x.
    if (end == 1) return pathClass(alloc, raw);
    const scheme = raw[0..end];
    const rest = raw[end + 1 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        return webClass(rest);
    }
    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
        // A bare "mailto:" would open an empty message.
        const address = rest[0 .. std.mem.indexOfAny(u8, rest, "?#") orelse rest.len];
        return if (address.len == 0) .{ .deny = .malformed } else .web;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return fileUrlClass(alloc, rest);
    for (blocked_schemes) |b| {
        if (std.ascii.eqlIgnoreCase(scheme, b)) return .{ .deny = .blocked_scheme };
    }
    return .custom;
}

/// Decide what to do with an untrusted link.
pub fn decide(alloc: Allocator, raw: []const u8) Allocator.Error!Decision {
    switch (try classify(alloc, raw)) {
        .deny => |reason| return deny(alloc, reason, raw),
        .web => return .{ .open = .{ .value = try escapeForHandler(alloc, raw) } },
        .custom => return .{ .confirm = .{ .value = try escapeForHandler(alloc, raw) } },
        .path => |path| {
            defer alloc.free(path);
            return vetPath(alloc, path);
        },
    }
}

fn deny(alloc: Allocator, reason: Reason, target: []const u8) Allocator.Error!Decision {
    // Every other target is at most max_len long, so it is shown and copied
    // whole.
    const complete = reason != .too_long;
    return .{ .deny = .{
        .reason = reason,
        .target = try display(alloc, if (complete) target else text_util.truncate(target, 1024)),
        .complete = complete,
    } };
}

/// The index of the colon that ends a URL scheme (RFC 3986: a letter, then
/// letters, digits, "+", "-" or "."), or null if `s` starts with none.
fn schemeEnd(s: []const u8) ?usize {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return null;
    for (s[1..], 1..) |b, i| switch (b) {
        ':' => return i,
        'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
        else => return null,
    };
    return null;
}

fn webClass(rest: []const u8) Class {
    // "https:relative" has a scheme but no host, and handlers resolve it
    // against different bases.
    if (!std.mem.startsWith(u8, rest, "//")) return .{ .deny = .invalid_web_url };
    const after = rest[2..];
    const authority = after[0 .. std.mem.indexOfAny(u8, after, "/?#") orelse after.len];
    // Browsers read a backslash as a slash, so one here makes the host
    // read differently from where the link goes.
    if (std.mem.indexOfScalar(u8, authority, '\\') != null) return .{ .deny = .invalid_web_url };
    const host = authority[if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| i + 1 else 0..];
    if (host.len == 0 or host[0] == ':') return .{ .deny = .invalid_web_url };
    return .web;
}

fn fileUrlClass(alloc: Allocator, rest: []const u8) Allocator.Error!Class {
    // A query or fragment names no part of a file, and handlers differ on
    // what they mean.
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return .{ .deny = .malformed };
    var path = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const host = after[0..host_end];
        if (std.mem.eql(u8, host, ".") or std.mem.eql(u8, host, "?")) return .{ .deny = .special_path };
        // file://server/share is a UNC path: opening it connects there.
        if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return .{ .deny = .remote_file };
        path = after[host_end..];
    }

    const decoded = (try percentDecode(alloc, path)) orelse return .{ .deny = .malformed };
    defer alloc.free(decoded);
    // Escapes can spell what the raw text may not contain.
    if (!safeText(decoded)) return .{ .deny = .unsafe_characters };
    // file:///C:/x has the path /C:/x.
    const drive = decoded.len >= 3 and decoded[0] == '/' and
        std.ascii.isAlphabetic(decoded[1]) and decoded[2] == ':';
    return pathClass(alloc, if (drive) decoded[1..] else decoded);
}

fn pathClass(alloc: Allocator, s: []const u8) Allocator.Error!Class {
    const path = try alloc.dupe(u8, s);
    std.mem.replaceScalar(u8, path, '/', '\\');
    if (checkPath(path)) |reason| {
        alloc.free(path);
        return .{ .deny = reason };
    }
    return .{ .path = path };
}

/// Why `path` (with backslashes) may not open, going by its spelling.
fn checkPath(path: []const u8) ?Reason {
    // \\server\share, and the device namespaces \\.\ and \\?\.
    if (std.mem.startsWith(u8, path, "\\\\")) {
        if (path.len > 2 and (path[2] == '.' or path[2] == '?')) return .special_path;
        return .remote_file;
    }
    if (std.mem.startsWith(u8, path, "\\??\\")) return .special_path;
    // Only C:\... is absolute: C:x is relative to the drive's current
    // folder and \x to the current drive.
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') {
        return .relative_path;
    }
    const rest = path[3..];
    // Another colon names a stream (file.txt:payload).
    if (std.mem.indexOfScalar(u8, rest, ':') != null) return .special_path;
    // Wildcards, including the DOS ones (" < >) that FindFirstFileExW in
    // `walk` would expand.
    if (std.mem.indexOfAny(u8, rest, "*?\"<>|") != null) return .malformed;
    var it = std.mem.splitScalar(u8, rest, '\\');
    while (it.next()) |part| {
        if (reservedName(part) or clsidName(part)) return .special_path;
    }
    return null;
}

/// Whether a path component is a DOS device name (CON, NUL, COM1, ...),
/// with or without an extension. Windows 11 treats fewer of these as
/// devices than earlier versions did; all are denied.
fn reservedName(part: []const u8) bool {
    const base = std.mem.trimEnd(u8, part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len], " ");
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |n| {
        if (std.ascii.eqlIgnoreCase(base, n)) return true;
    }
    if (base.len < 4) return false;
    const head = base[0..3];
    if (!std.ascii.eqlIgnoreCase(head, "com") and !std.ascii.eqlIgnoreCase(head, "lpt")) return false;
    const tail = base[3..];
    if (tail.len == 1) return std.ascii.isDigit(tail[0]);
    // COM¹, COM², COM³ and the same for LPT.
    for ([_][]const u8{ "\u{B9}", "\u{B2}", "\u{B3}" }) |sup| {
        if (std.mem.eql(u8, tail, sup)) return true;
    }
    return false;
}

/// Whether a component ends in a class id (name.{GUID}), which makes
/// Explorer open the folder as that shell extension.
fn clsidName(part: []const u8) bool {
    return std.mem.endsWith(u8, part, "}") and std.mem.indexOf(u8, part, ".{") != null;
}

/// `s` with %XX escapes decoded, or null if an escape is malformed.
fn percentDecode(alloc: Allocator, s: []const u8) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            out.appendAssumeCapacity(s[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= s.len) {
            out.deinit(alloc);
            return null;
        }
        const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
            out.deinit(alloc);
            return null;
        };
        const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
            out.deinit(alloc);
            return null;
        };
        out.appendAssumeCapacity(hi << 4 | lo);
        i += 3;
    }
    return try out.toOwnedSlice(alloc);
}

/// `s` percent-encoded for a URL handler's command line. The shell puts a
/// URL into the handler's command (`"app.exe" "%1"`) as plain text, so a
/// quote, space or backslash in it could end the argument and add others.
/// Like Chromium's EscapeExternalHandlerValue, this keeps letters, digits,
/// -_.!~*'(), the reserved ;/?:@&=+$,#[] and valid %XX escapes, and
/// encodes every other byte, non-ASCII included: a program that reads its
/// command line in the ANSI code page gets look-alikes such as U+FF02 and
/// U+3000 "best fit" into a quote and a space.
fn escapeForHandler(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s, 0..) |b, i| {
        const keep = std.ascii.isAlphanumeric(b) or
            std.mem.indexOfScalar(u8, "-_.!~*'();/?:@&=+$,#[]", b) != null or
            (b == '%' and i + 2 < s.len and
                std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]));
        if (keep) {
            try out.append(alloc, b);
        } else {
            try out.print(alloc, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Whether `s` is valid UTF-8 free of control, bidirectional-control and
/// invisible formatting characters. Those can make a target read
/// differently from what it opens, so a target containing one is denied.
pub fn safeText(s: []const u8) bool {
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (unsafeCodepoint(cp)) return false;
    }
    return true;
}

/// The macOS app's set.
fn unsafeCodepoint(cp: u21) bool {
    return switch (cp) {
        // C0 and C1 controls, including CR, LF and NEL.
        0x00...0x1F, 0x7F...0x9F => true,
        // Bidirectional marks and overrides, and zero-width characters.
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true,
        // Line and paragraph separators.
        0x2028, 0x2029 => true,
        // Word joiner and byte order mark.
        0x2060, 0xFEFF => true,
        else => false,
    };
}

/// `s` for showing in a dialog: unsafe characters become \u{...} and
/// invalid bytes \x.., so nothing in it is invisible, reorders the text or
/// starts a new line.
pub fn display(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const cp: ?u21 = if (n > 0 and i + n <= s.len)
            std.unicode.utf8Decode(s[i..][0..n]) catch null
        else
            null;
        if (cp) |v| {
            if (unsafeCodepoint(v)) {
                try out.print(alloc, "\\u{{{X}}}", .{v});
            } else {
                try out.appendSlice(alloc, s[i..][0..n]);
            }
            i += n;
        } else {
            try out.print(alloc, "\\x{X:0>2}", .{s[i]});
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The checks only the file system can answer: what the path names once
/// Windows has resolved "..", trailing dots and spaces, and device names
/// (GetFullPathNameW); the long name of each component, without following
/// links (`walk`); whether it exists; and whether it is a directory or a
/// file that is inert, could run code, or neither.
fn vetPath(alloc: Allocator, path: []const u8) Allocator.Error!Decision {
    const path16 = try text_util.utf16Lossy(alloc, path);
    defer alloc.free(path16);
    const full = try fullPath(alloc, path16) orelse return deny(alloc, .not_found, path);
    defer alloc.free(full);
    if (full.len < 3 or full[1] != ':' or full[2] != '\\') {
        // A device: GetFullPathNameW turns C:\x\nul into \\.\nul.
        return deny(alloc, .special_path, path);
    }
    const found = switch (try walk(alloc, full, 0)) {
        .found => |f| f,
        .deny => |reason| return deny(alloc, reason, path),
    };
    defer alloc.free(found.path);
    const resolved = found.path;

    // The names on disk get the same rule as the text that led to them: an
    // 8.3 alias is plain ASCII, but the long name it stands for may not be.
    if (!safeText(resolved)) return deny(alloc, .unsafe_characters, resolved);
    if (checkPath(resolved)) |reason| return deny(alloc, reason, resolved);
    if (found.attrs & c.FILE_ATTRIBUTE_DEVICE != 0) return deny(alloc, .special_path, resolved);
    if (found.attrs & c.FILE_ATTRIBUTE_DIRECTORY != 0) {
        // Media in a CD drive or a mounted image can define verbs of its
        // own for its root (autorun.inf), any verb name included, so no
        // verb is invoked on one: the drive is shown selected instead.
        const root16 = [_]u16{ resolved[0], ':', '\\', 0 };
        const removable = resolved.len == 3 and c.GetDriveTypeW(@ptrCast(&root16)) != c.DRIVE_FIXED;
        return .{ .open = .{
            .verb = if (removable) .select else .default,
            .value = try alloc.dupe(u8, resolved),
            .item = true,
        } };
    }
    return fileDecision(alloc, resolved);
}

/// GetFullPathNameW into an owned copy, or null if it fails.
fn fullPath(alloc: Allocator, path: [:0]const u16) Allocator.Error!?[:0]u16 {
    // The longest path Windows accepts.
    const buf = try alloc.alloc(u16, 32768);
    defer alloc.free(buf);
    const n = c.GetFullPathNameW(path, @intCast(buf.len), buf.ptr, null);
    if (n == 0 or n >= buf.len) return null;
    return try alloc.dupeSentinel(u16, buf[0..n], 0);
}

const Walked = union(enum) {
    /// The path with each component's long name (owned), and the last
    /// component's attributes.
    found: struct { path: []u8, attrs: c.DWORD },
    deny: Reason,
};

/// Look up a drive-absolute path one component at a time, reading each
/// entry from its parent directory (FindFirstFileExW) so that no link along
/// the way is followed. A symbolic link can point at another computer, and
/// following one, even to read attributes, connects there and sends the
/// user's credentials; so a path through one is denied. A junction is
/// followed by reading its target and walking that, since its target can
/// itself pass through a symbolic link; a volume mount point (a junction
/// to a volume's root) is fine as it is. Cloud files (OneDrive) are
/// reparse points that lead nowhere else. The entry's name is the long one
/// even where the path spelled an 8.3 name, which could hide an extension.
/// `hops` counts the junctions followed so far.
fn walk(alloc: Allocator, full: []const u16, hops: u8) Allocator.Error!Walked {
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, full[0..3]);
    var attrs: ?c.DWORD = null;
    var it = std.mem.splitScalar(u16, full[3..], '\\');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (attrs != null) try out.append(alloc, '\\');
        const parent_len = out.items.len;
        try out.appendSlice(alloc, part);
        try out.append(alloc, 0);
        var data: c.WIN32_FIND_DATAW = undefined;
        const find = c.FindFirstFileExW(
            @ptrCast(out.items.ptr),
            c.FindExInfoBasic,
            &data,
            c.FindExSearchNameMatch,
            null,
            0,
        );
        if (find == c.INVALID_HANDLE_VALUE) return .{ .deny = .not_found };
        _ = c.FindClose(find);
        const name = std.mem.sliceTo(&data.cFileName, 0);
        // Win32 drops a trailing dot or space from every path it is given,
        // so a name ending in one (reached here by its 8.3 alias) can't be
        // opened by name: the shell would open a sibling without it.
        if (name.len == 0 or name[name.len - 1] == '.' or name[name.len - 1] == ' ') {
            return .{ .deny = .special_path };
        }
        out.shrinkRetainingCapacity(parent_len);
        try out.appendSlice(alloc, name);
        attrs = data.dwFileAttributes;

        if (data.dwFileAttributes & c.FILE_ATTRIBUTE_REPARSE_POINT == 0) continue;
        const tag = data.dwReserved0;
        // Only "name surrogate" reparse points lead to another name.
        if (tag & c.IO_REPARSE_TAG_NAME_SURROGATE == 0) continue;
        switch (tag) {
            // A WSL symbolic link, which Windows doesn't follow.
            c.IO_REPARSE_TAG_LX_SYMLINK => {},
            c.IO_REPARSE_TAG_MOUNT_POINT => {
                try out.append(alloc, 0);
                const target = try junctionTarget(alloc, @ptrCast(out.items.ptr));
                _ = out.pop();
                switch (target) {
                    .volume => {},
                    .other => return .{ .deny = .special_path },
                    .path => |t| {
                        defer alloc.free(t);
                        if (hops >= 31) return .{ .deny = .special_path };
                        // Walk the target, then what the path names inside it.
                        var next: std.ArrayList(u16) = .empty;
                        defer next.deinit(alloc);
                        try next.appendSlice(alloc, t);
                        const rest = it.rest();
                        if (rest.len > 0) {
                            try next.append(alloc, '\\');
                            try next.appendSlice(alloc, rest);
                        }
                        try next.append(alloc, 0);
                        const joined = try fullPath(alloc, next.items[0 .. next.items.len - 1 :0]) orelse return .{ .deny = .not_found };
                        defer alloc.free(joined);
                        if (joined.len < 3 or joined[1] != ':' or joined[2] != '\\') return .{ .deny = .special_path };
                        return walk(alloc, joined, hops + 1);
                    },
                }
            },
            else => return .{ .deny = .symbolic_link },
        }
    }

    // A drive's root has no entry to find.
    const final = attrs orelse root: {
        try out.append(alloc, 0);
        const a = c.GetFileAttributesW(@ptrCast(out.items.ptr));
        _ = out.pop();
        if (a == c.INVALID_FILE_ATTRIBUTES) return .{ .deny = .not_found };
        break :root a;
    };
    const path = std.unicode.utf16LeToUtf8Alloc(alloc, out.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // An unpaired surrogate: no valid text names it.
        else => return .{ .deny = .malformed },
    };
    return .{ .found = .{ .path = path, .attrs = final } };
}

const JunctionTarget = union(enum) {
    /// A volume's root (\??\Volume{...}\): a volume mount point.
    volume,
    /// A drive-absolute path (owned).
    path: []u16,
    /// Anything else, or unreadable.
    other,
};

/// Where the junction at `path` leads, read from the junction itself
/// without following it. Its parent was already walked.
fn junctionTarget(alloc: Allocator, path: c.LPCWSTR) Allocator.Error!JunctionTarget {
    const file = c.CreateFileW(
        path,
        c.FILE_READ_ATTRIBUTES,
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE,
        null,
        c.OPEN_EXISTING,
        c.FILE_FLAG_OPEN_REPARSE_POINT | c.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (file == c.INVALID_HANDLE_VALUE) return .other;
    defer _ = c.CloseHandle(file);
    // MAXIMUM_REPARSE_DATA_BUFFER_SIZE.
    const buf = try alloc.alignedAlloc(u8, .of(u32), 16 * 1024);
    defer alloc.free(buf);
    var got: c.DWORD = 0;
    if (c.DeviceIoControl(file, c.FSCTL_GET_REPARSE_POINT, null, 0, buf.ptr, @intCast(buf.len), &got, null) == 0) return .other;

    // REPARSE_DATA_BUFFER: tag, data length, reserved, then for a mount
    // point the substitute name's offset and length (bytes, relative to
    // the path buffer at offset 16), the print name's, and the names.
    if (got < 16 or std.mem.readInt(u32, buf[0..4], .little) != c.IO_REPARSE_TAG_MOUNT_POINT) return .other;
    const offset = std.mem.readInt(u16, buf[8..10], .little);
    const len = std.mem.readInt(u16, buf[10..12], .little);
    if (offset % 2 != 0 or len % 2 != 0 or 16 + @as(usize, offset) + len > got) return .other;
    const bytes = buf[16 + offset ..][0..len];
    const name = try alloc.alloc(u16, len / 2);
    defer alloc.free(name);
    for (name, 0..) |*unit, i| unit.* = std.mem.readInt(u16, bytes[2 * i ..][0..2], .little);

    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    if (!std.mem.startsWith(u16, name, prefix)) return .other;
    const rest = name[prefix.len..];
    if (std.mem.startsWith(u16, rest, std.unicode.utf8ToUtf16LeStringLiteral("Volume{"))) return .volume;
    if (rest.len < 3 or rest[0] > 0x7F or !std.ascii.isAlphabetic(@intCast(rest[0])) or
        rest[1] != ':' or rest[2] != '\\') return .other;
    return .{ .path = try alloc.dupe(u16, rest) };
}

/// A file opens without asking only if its type is inert; it is denied if
/// opening it could run code; anything else, including a file without an
/// extension, asks first. The shell picks the program by extension, so a
/// file is judged by its extension (our list, %PATHEXT%, and the shell's
/// own list of dangerous types, AssocIsDangerous) and by the program
/// registered to open it.
fn fileDecision(alloc: Allocator, path: []const u8) Allocator.Error!Decision {
    const ext = extension(path) orelse
        return .{ .confirm = .{ .value = try alloc.dupe(u8, path), .item = true } };
    if (try unsafeType(alloc, ext) or try handlerRunsCode(alloc, ext)) return deny(alloc, .unsafe_file, path);
    const target: Target = .{ .value = try alloc.dupe(u8, path), .item = true };
    return if (listed(&inert_extensions, ext)) .{ .open = target } else .{ .confirm = target };
}

fn unsafeType(alloc: Allocator, ext: []const u8) Allocator.Error!bool {
    if (listed(&unsafe_extensions, ext)) return true;
    if (try inPathext(alloc, ext)) return true;
    const ext16 = try text_util.utf16Lossy(alloc, ext);
    defer alloc.free(ext16);
    return c.AssocIsDangerous(ext16) != 0;
}

/// Whether the program registered for `ext`, for the default verb or for
/// "open", is one that runs code (see `code_runners`).
fn handlerRunsCode(alloc: Allocator, ext: []const u8) Allocator.Error!bool {
    for ([_]?c.LPCWSTR{ null, c.L("open") }) |verb| {
        const exe = try assocString(alloc, ext, c.ASSOCSTR_EXECUTABLE, verb) orelse continue;
        defer alloc.free(exe);
        if (runsCode(exe)) return true;
    }
    return false;
}

/// Whether the program at `exe` (a path or a file name) is a code runner.
fn runsCode(exe: []const u8) bool {
    var name = exe[if (std.mem.lastIndexOfAny(u8, exe, "\\/")) |i| i + 1 else 0..];
    if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) name = name[0 .. name.len - 4];
    if (std.ascii.startsWithIgnoreCase(name, "python") or
        std.ascii.startsWithIgnoreCase(name, "autohotkey")) return true;
    return listed(&code_runners, name);
}

/// The extension of the last component of an absolute path, with its dot.
fn extension(path: []const u8) ?[]const u8 {
    const name = path[(std.mem.lastIndexOfScalar(u8, path, '\\') orelse return null) + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot + 1 == name.len) return null;
    return name[dot..];
}

fn listed(list: []const []const u8, s: []const u8) bool {
    for (list) |e| {
        if (std.ascii.eqlIgnoreCase(s, e)) return true;
    }
    return false;
}

fn inPathext(alloc: Allocator, ext: []const u8) Allocator.Error!bool {
    const name = c.L("PATHEXT");
    const size = c.GetEnvironmentVariableW(name, null, 0);
    if (size == 0) return false;
    const buf = try alloc.alloc(u16, size);
    defer alloc.free(buf);
    const n = c.GetEnvironmentVariableW(name, buf.ptr, size);
    if (n == 0 or n >= size) return false;
    const list = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer alloc.free(list);
    return pathextHas(list, ext);
}

/// Whether `ext` is in a %PATHEXT%-style list (".COM;.EXE;...").
fn pathextHas(list: []const u8, ext: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ';');
    while (it.next()) |entry| {
        const e = std.mem.trim(u8, entry, " ");
        if (e.len > 0 and std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return false;
}

/// AssocQueryStringW for `assoc` (an extension, or a URL scheme, which is
/// a ProgID), or null if nothing is registered.
fn assocString(alloc: Allocator, assoc: []const u8, which: c_int, verb: ?c.LPCWSTR) Allocator.Error!?[]u8 {
    const assoc16 = try text_util.utf16Lossy(alloc, assoc);
    defer alloc.free(assoc16);
    var buf: [1024]u16 = undefined;
    var len: c.DWORD = buf.len;
    const hr = c.AssocQueryStringW(c.ASSOCF_INIT_IGNOREUNKNOWN, which, assoc16, verb, &buf, &len);
    // len counts the terminating NUL.
    if (hr < 0 or len <= 1 or len > buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0 .. len - 1]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

/// The name of the application that would open `target` (registered for
/// its scheme, or for a file's extension), for the confirmation, or null
/// if there is none or it can't be found.
pub fn handlerName(alloc: Allocator, target: Target) ?[]u8 {
    const assoc = if (target.item)
        extension(target.value) orelse return null
    else
        target.value[0 .. schemeEnd(target.value) orelse return null];
    const name = (assocString(alloc, assoc, c.ASSOCSTR_FRIENDLYAPPNAME, null) catch return null) orelse return null;
    // The name is shown as plain text, so it gets the same rule as targets.
    if (!safeText(name)) {
        alloc.free(name);
        return null;
    }
    return name;
}

/// Open `target` with the shell and wait for it to start. Run this from the
/// message loop in a modal scope, because the shell can show dialogs of
/// its own (no handler, "Open with"). Returns false if it failed.
pub fn launch(alloc: Allocator, owner: ?c.HWND, target: Target) bool {
    const value = text_util.utf16Lossy(alloc, target.value) catch return false;
    defer alloc.free(value);
    var info: c.SHELLEXECUTEINFOW = .{
        .fMask = c.SEE_MASK_NOASYNC,
        .hwnd = owner,
        .nShow = c.SW_SHOWNORMAL,
    };

    // A path is opened as the item that was checked. Given the path as
    // text, the shell would look the name up again, and it tries
    // executable extensions for a name that doesn't exist.
    var pidl: ?*anyopaque = null;
    defer if (pidl) |p| c.ILFree(p);
    if (target.item) {
        pidl = c.ILCreateFromPathW(value) orelse {
            log.warn("ILCreateFromPathW failed for a link target err={d}", .{c.GetLastError()});
            return false;
        };
        // The shell must have parsed the path into the item that was
        // checked, not something it normalized it into.
        if (!sameItem(alloc, pidl.?, value)) {
            log.warn("a link target's shell item is not the path that was checked", .{});
            return false;
        }
        if (target.verb == .select) {
            const hr = c.SHOpenFolderAndSelectItems(pidl.?, 0, null, 0);
            if (hr < 0) log.warn("SHOpenFolderAndSelectItems failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return hr >= 0;
        }
        info.fMask |= c.SEE_MASK_INVOKEIDLIST;
        info.lpIDList = pidl;
    } else {
        info.lpFile = value;
    }

    if (c.ShellExecuteExW(&info) == 0) {
        log.warn("ShellExecuteExW failed for a link err={d}", .{c.GetLastError()});
        return false;
    }
    return true;
}

/// Whether the file system path of `pidl` is `path`, ignoring case as the
/// file system does.
fn sameItem(alloc: Allocator, pidl: *anyopaque, path: []const u16) bool {
    const buf = alloc.alloc(u16, 32768) catch return false;
    defer alloc.free(buf);
    if (c.SHGetPathFromIDListEx(pidl, buf.ptr, @intCast(buf.len), 0) == 0) return false;
    const got = std.mem.sliceTo(buf, 0);
    return c.CompareStringOrdinal(got.ptr, @intCast(got.len), path.ptr, @intCast(path.len), c.TRUE) == c.CSTR_EQUAL;
}

// Tests. The decision table for text (classify), then the file system
// checks against files every Windows install has and files the tests
// create in %TEMP%.

fn expectClass(expected: std.meta.Tag(Class), raw: []const u8) !void {
    const alloc = std.testing.allocator;
    const got = try classify(alloc, raw);
    defer if (got == .path) alloc.free(got.path);
    std.testing.expectEqual(expected, std.meta.activeTag(got)) catch |err| {
        std.debug.print("classify({s}) = {t}\n", .{ raw, got });
        return err;
    };
}

fn expectDenied(reason: Reason, raw: []const u8) !void {
    const got = try classify(std.testing.allocator, raw);
    if (got == .path) std.testing.allocator.free(got.path);
    std.testing.expect(got == .deny and got.deny == reason) catch |err| {
        std.debug.print("classify({s}) = {t}, expected deny {t}\n", .{ raw, got, reason });
        return err;
    };
}

fn expectPath(expected: []const u8, raw: []const u8) !void {
    const alloc = std.testing.allocator;
    const got = try classify(alloc, raw);
    if (got != .path) {
        std.debug.print("classify({s}) = {t}, expected a path\n", .{ raw, got });
        return error.TestUnexpectedResult;
    }
    defer alloc.free(got.path);
    try std.testing.expectEqualStrings(expected, got.path);
}

test "url: web and mail links open" {
    try expectClass(.web, "https://example.com");
    try expectClass(.web, "HTTP://example.com/a?b#c");
    try expectClass(.web, "https://user@example.com:8443/x");
    try expectClass(.web, "https://[::1]:8080/");
    try expectClass(.web, "mailto:someone@example.com");
    try expectClass(.web, "mailto:someone@example.com?subject=hi");
}

test "url: malformed web and mail links are denied" {
    try expectDenied(.invalid_web_url, "https:relative");
    try expectDenied(.invalid_web_url, "https://");
    try expectDenied(.invalid_web_url, "https:///path");
    try expectDenied(.invalid_web_url, "https://user@/x");
    try expectDenied(.invalid_web_url, "https://:443/x");
    try expectDenied(.invalid_web_url, "https://evil.example\\@good.example/");
    try expectDenied(.malformed, "mailto:");
    try expectDenied(.malformed, "mailto:?subject=x");
    try expectDenied(.malformed, "");
}

test "url: unsafe characters are denied" {
    try expectDenied(.unsafe_characters, "https://example.com/\x00");
    try expectDenied(.unsafe_characters, "https://example.com/a\nb");
    try expectDenied(.unsafe_characters, "https://example.com/\x1b[31m");
    try expectDenied(.unsafe_characters, "https://example.com/\x7f");
    try expectDenied(.unsafe_characters, "https://example.com/\u{85}"); // NEL
    try expectDenied(.unsafe_characters, "https://example.com/\u{202E}gpj.exe"); // RLO
    try expectDenied(.unsafe_characters, "https://exa\u{200B}mple.com/"); // ZWSP
    try expectDenied(.unsafe_characters, "https://example.com/\u{2066}x\u{2069}");
    try expectDenied(.unsafe_characters, "https://example.com/\u{061C}");
    try expectDenied(.unsafe_characters, "https://example.com/\u{2028}");
    try expectDenied(.unsafe_characters, "https://example.com/\u{2060}");
    try expectDenied(.unsafe_characters, "\u{FEFF}https://example.com/");
    // Invalid UTF-8.
    try expectDenied(.unsafe_characters, "https://example.com/\xff");
    // Escapes in a file URL are decoded before the check.
    try expectDenied(.unsafe_characters, "file:///C:/a%00b.txt");
    try expectDenied(.unsafe_characters, "file:///C:/x%E2%80%AEtxt.exe");
    // Ordinary Unicode is fine.
    try expectClass(.web, "https://example.com/caf\u{E9}/\u{1F680}");
}

test "url: other schemes ask, abused ones are blocked" {
    try expectClass(.custom, "vscode://file/C:/x");
    try expectClass(.custom, "ssh://host");
    try expectClass(.custom, "ms-settings:display");
    try expectClass(.custom, "ghostty-gui-test:hello");
    try expectDenied(.blocked_scheme, "ms-msdt:/id PCWDiagnostic");
    try expectDenied(.blocked_scheme, "SEARCH-MS:query=x");
    try expectDenied(.blocked_scheme, "javascript:alert(1)");
    try expectDenied(.blocked_scheme, "shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}");
}

test "url: file URLs and paths" {
    try expectPath("C:\\Windows\\notepad.exe", "file:///C:/Windows/notepad.exe");
    try expectPath("C:\\Program Files\\x.txt", "file:///C:/Program%20Files/x.txt");
    try expectPath("C:\\a\\b", "file://localhost/C:/a/b");
    try expectPath("C:\\a\\b", "file:/C:/a/b");
    try expectPath("C:\\a\\b", "file:C:/a/b");
    try expectPath("C:\\a\\b", "C:\\a\\b");
    try expectPath("d:\\a\\b", "d:/a/b");
    try expectPath("C:\\", "C:\\");
    // An escaped backslash is still a backslash.
    try expectPath("C:\\a\\b", "file:///C:%5Ca%5Cb");
}

test "url: remote, special and relative paths are denied" {
    try expectDenied(.remote_file, "file://server/share/x.txt");
    try expectDenied(.remote_file, "file:////server/share/x.txt");
    try expectDenied(.remote_file, "\\\\server\\share\\x.txt");
    try expectDenied(.remote_file, "//server/share/x.txt");
    try expectDenied(.remote_file, "file:///%5C%5Cserver/share");
    try expectDenied(.special_path, "file://./C:/x");
    try expectDenied(.special_path, "\\\\.\\PhysicalDrive0");
    try expectDenied(.special_path, "\\\\?\\C:\\x.txt");
    try expectDenied(.special_path, "\\??\\C:\\x.txt");
    try expectDenied(.special_path, "C:\\x\\file.txt:payload.exe");
    try expectDenied(.special_path, "C:\\x\\CON");
    try expectDenied(.special_path, "C:\\x\\nul.txt");
    try expectDenied(.special_path, "C:\\x\\com1.log");
    try expectDenied(.special_path, "C:\\x\\LPT9");
    try expectDenied(.special_path, "C:\\x\\COM\u{B9}");
    try expectDenied(.special_path, "C:\\x\\conout$");
    try expectDenied(.special_path, "C:\\x\\aux .txt");
    try expectDenied(.special_path, "C:\\x\\folder.{20D04FE0-3AEA-1069-A2D8-08002B30309D}");
    try expectDenied(.relative_path, "notes.txt");
    try expectDenied(.relative_path, "..\\x");
    try expectDenied(.relative_path, "\\Windows\\notepad.exe");
    try expectDenied(.relative_path, "/etc/passwd");
    try expectDenied(.relative_path, "C:x.txt");
    try expectDenied(.relative_path, "C:");
    try expectDenied(.relative_path, "file:///etc/passwd");
    try expectDenied(.malformed, "C:\\x\\*.txt");
    try expectDenied(.malformed, "C:\\x\\a<b");
    try expectDenied(.malformed, "file:///C:/x.txt?y");
    try expectDenied(.malformed, "file:///C:/x.txt#y");
    try expectDenied(.malformed, "file:///C:/x%2");
    try expectDenied(.malformed, "file:///C:/x%zz");
    // Names that only look reserved.
    try expectClass(.path, "C:\\x\\console.txt");
    try expectClass(.path, "C:\\x\\com10");
    try expectClass(.path, "C:\\x\\auxiliary");
    try expectClass(.path, "C:\\x\\{notes}");
}

test "url: too long" {
    const alloc = std.testing.allocator;
    const long = try alloc.alloc(u8, max_len + 1);
    defer alloc.free(long);
    @memcpy(long[0..8], "https://");
    @memset(long[8..], 'a');
    try expectDenied(.too_long, long);
    try expectClass(.web, long[0..max_len]);

    // Only the start of it is shown, and it is marked as not whole.
    const d = try decide(alloc, long);
    defer d.deinit(alloc);
    try std.testing.expect(d == .deny and !d.deny.complete and d.deny.target.len == 1024);
}

test "url: display escapes what it can't show" {
    const alloc = std.testing.allocator;
    const out = try display(alloc, "a\u{202E}b\x00c\xffd\u{E9}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a\\u{202E}b\\u{0}c\\xFFd\u{E9}", out);
}

fn expectEscaped(expected: []const u8, raw: []const u8) !void {
    const out = try escapeForHandler(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "url: escaping for a handler's command line" {
    // A quote or space can't end the argument and start another.
    try expectEscaped("x-test:a%22%20--flag%20%22b", "x-test:a\" --flag \"b");
    try expectEscaped("x-test:a%5C", "x-test:a\\");
    try expectEscaped("x-test:%7B%7C%7D%5E%60%3C%3E", "x-test:{|}^`<>");
    // Valid escapes and reserved characters stay.
    try expectEscaped("https://example.com/a%20b?q=1&r=[2]#f", "https://example.com/a%20b?q=1&r=[2]#f");
    // Non-ASCII is encoded: an ANSI program would turn these look-alikes
    // into a quote and a space.
    try expectEscaped("https://example.com/caf%C3%A9", "https://example.com/caf\u{E9}");
    try expectEscaped("x-test:a%EF%BC%82%E3%80%80b", "x-test:a\u{FF02}\u{3000}b");
    // A % that starts no escape is encoded itself.
    try expectEscaped("x-test:%25zz%25", "x-test:%zz%");
}

test "url: extensions and code runners" {
    try std.testing.expectEqualStrings(".exe", extension("C:\\x\\calc.exe").?);
    try std.testing.expectEqualStrings(".gz", extension("C:\\x\\a.tar.gz").?);
    try std.testing.expectEqualStrings(".exe", extension("C:\\x\\.exe").?);
    try std.testing.expect(extension("C:\\x.d\\README") == null);
    try std.testing.expect(listed(&unsafe_extensions, ".LNK"));
    try std.testing.expect(listed(&unsafe_extensions, ".pyw"));
    try std.testing.expect(listed(&unsafe_extensions, ".settingcontent-ms"));
    try std.testing.expect(!listed(&unsafe_extensions, ".txt"));
    try std.testing.expect(listed(&inert_extensions, ".TXT"));
    // Nothing is on both lists.
    for (inert_extensions) |e| try std.testing.expect(!listed(&unsafe_extensions, e));
    try std.testing.expect(pathextHas(".COM;.EXE; .PY ;", ".py"));
    try std.testing.expect(!pathextHas(".COM;.EXE;;", ".txt"));
    try std.testing.expect(!pathextHas(".COM;.EXE;;", ""));
    try std.testing.expect(runsCode("C:\\Windows\\py.exe"));
    try std.testing.expect(runsCode("C:\\Python312\\PYTHONW.EXE"));
    try std.testing.expect(runsCode("C:\\x\\python3.12.exe"));
    try std.testing.expect(runsCode("AutoHotkey64.exe"));
    try std.testing.expect(runsCode("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"));
    try std.testing.expect(!runsCode("C:\\Windows\\System32\\notepad.exe"));
    try std.testing.expect(!runsCode("C:\\x\\cmdlet-viewer.exe"));
}

fn expectDecision(raw: []const u8, comptime check: fn (Decision) bool) !void {
    const alloc = std.testing.allocator;
    const d = try decide(alloc, raw);
    defer d.deinit(alloc);
    std.testing.expect(check(d)) catch |err| {
        switch (d) {
            .open, .confirm => |t| std.debug.print("decide({s}) = {t} {t} {s}\n", .{ raw, d, t.verb, t.value }),
            .deny => |v| std.debug.print("decide({s}) = deny {t} {s}\n", .{ raw, v.reason, v.target }),
        }
        return err;
    };
}

test "url: decide checks the file system" {
    // A program is denied, however it is spelled.
    try expectDecision("file:///C:/Windows/System32/calc.exe", struct {
        fn f(d: Decision) bool {
            return d == .deny and d.deny.reason == .unsafe_file;
        }
    }.f);
    try expectDecision("C:\\Windows\\System32\\..\\System32\\CALC.EXE", struct {
        fn f(d: Decision) bool {
            return d == .deny and d.deny.reason == .unsafe_file;
        }
    }.f);
    // Trailing dots and spaces are dropped by Windows, so they don't hide
    // the extension.
    try expectDecision("C:\\Windows\\System32\\calc.exe. . ", struct {
        fn f(d: Decision) bool {
            return d == .deny and d.deny.reason == .unsafe_file;
        }
    }.f);
    // A directory opens with its default verb, at its resolved path.
    try expectDecision("file:///C:/Windows/System32/../", struct {
        fn f(d: Decision) bool {
            return d == .open and d.open.verb == .default and d.open.item and
                std.ascii.eqlIgnoreCase(d.open.value, "C:\\Windows");
        }
    }.f);
    try expectDecision("C:\\", struct {
        fn f(d: Decision) bool {
            return d == .open and d.open.item and std.ascii.eqlIgnoreCase(d.open.value, "C:\\");
        }
    }.f);
    // An inert file opens as itself; a file without an extension asks.
    try expectDecision("C:\\Windows\\win.ini", struct {
        fn f(d: Decision) bool {
            return d == .open and d.open.verb == .default and d.open.item;
        }
    }.f);
    try expectDecision("C:\\Windows\\System32\\drivers\\etc\\hosts", struct {
        fn f(d: Decision) bool {
            return d == .confirm and d.confirm.item;
        }
    }.f);
    try expectDecision("C:\\Windows\\no-such-file-for-ghostty.txt", struct {
        fn f(d: Decision) bool {
            return d == .deny and d.deny.reason == .not_found;
        }
    }.f);
    // A device name GetFullPathNameW maps to \\.\nul.
    try expectDecision("C:\\Windows\\nul", struct {
        fn f(d: Decision) bool {
            return d == .deny and d.deny.reason == .special_path;
        }
    }.f);
    // Web links open, escaped for the handler.
    try expectDecision("https://example.com/a b", struct {
        fn f(d: Decision) bool {
            return d == .open and !d.open.item and std.mem.eql(u8, d.open.value, "https://example.com/a%20b");
        }
    }.f);
    try expectDecision("ghostty-gui-test:x", struct {
        fn f(d: Decision) bool {
            return d == .confirm and !d.confirm.item;
        }
    }.f);
}

test "url: links in the path are checked, not followed" {
    const alloc = std.testing.allocator;
    // Windows' own symbolic link, C:\Users\All Users -> C:\ProgramData.
    {
        if (c.GetFileAttributesW(c.L("C:\\Users\\All Users")) == c.INVALID_FILE_ATTRIBUTES) return error.SkipZigTest;
        const d = try decide(alloc, "C:\\Users\\All Users\\Microsoft");
        defer d.deinit(alloc);
        try std.testing.expect(d == .deny and d.deny.reason == .symbolic_link);
    }
    // And its junction, C:\Documents and Settings -> C:\Users, which is
    // followed by reading its target.
    {
        if (c.GetFileAttributesW(c.L("C:\\Documents and Settings")) == c.INVALID_FILE_ATTRIBUTES) return error.SkipZigTest;
        const d = try decide(alloc, "C:\\Documents and Settings");
        defer d.deinit(alloc);
        try std.testing.expect(d == .open);
        try std.testing.expectEqualStrings("C:\\Users", d.open.value);
    }
}

/// The 8.3 alias of the item at `path` (UTF-16, may use \\?\), or null if
/// the volume made none.
fn shortName(path: [:0]const u16) ?[13:0]u16 {
    var data: c.WIN32_FIND_DATAW = undefined;
    const find = c.FindFirstFileExW(path, c.FindExInfoStandard, &data, c.FindExSearchNameMatch, null, 0);
    if (find == c.INVALID_HANDLE_VALUE) return null;
    _ = c.FindClose(find);
    if (data.cAlternateFileName[0] == 0) return null;
    var out: [13:0]u16 = @splat(0);
    @memcpy(out[0..13], data.cAlternateFileName[0..13]);
    return out;
}

test "url: names Win32 can't spell, reached by their 8.3 alias, are denied" {
    const alloc = std.testing.allocator;
    var tmp: [261]u16 = undefined;
    const n = c.GetTempPathW(tmp.len, &tmp);
    if (n == 0 or n >= tmp.len) return error.SkipZigTest;
    const dir = try std.unicode.utf16LeToUtf8Alloc(alloc, tmp[0..n]);
    defer alloc.free(dir);
    const pid = c.GetCurrentProcessId();

    // A directory "x.txt." next to a file "x.txt": by name, Win32 only
    // reaches the file.
    const dotted = try std.fmt.allocPrint(alloc, "\\\\?\\{s}ghostty-url-test-{d}-x.txt.", .{ dir, pid });
    defer alloc.free(dotted);
    const dotted16 = try text_util.utf16Lossy(alloc, dotted);
    defer alloc.free(dotted16);
    if (c.CreateDirectoryW(dotted16, null) == 0) return error.SkipZigTest;
    defer _ = c.RemoveDirectoryW(dotted16);
    const sibling = try TempFile.create("x.txt");
    defer sibling.deinit();
    {
        const short = shortName(dotted16) orelse return error.SkipZigTest;
        const alias = try std.fmt.allocPrint(alloc, "{s}{f}", .{ dir, std.unicode.fmtUtf16Le(std.mem.sliceTo(&short, 0)) });
        defer alloc.free(alias);
        const d = try decide(alloc, alias);
        defer d.deinit(alloc);
        try std.testing.expect(d == .deny and d.deny.reason == .special_path);
    }

    // A long name with a right-to-left override behind a plain alias.
    const rlo = try TempFile.create("budget\u{202E}xcod.docm");
    defer rlo.deinit();
    const rlo16 = try text_util.utf16Lossy(alloc, rlo.path);
    defer alloc.free(rlo16);
    {
        const short = shortName(rlo16) orelse return error.SkipZigTest;
        const alias = try std.fmt.allocPrint(alloc, "{s}{f}", .{ dir, std.unicode.fmtUtf16Le(std.mem.sliceTo(&short, 0)) });
        defer alloc.free(alias);
        const d = try decide(alloc, alias);
        defer d.deinit(alloc);
        try std.testing.expect(d == .deny and d.deny.reason == .unsafe_characters);
    }
}

test "url: 8.3 names are expanded before the extension is judged" {
    const alloc = std.testing.allocator;
    var short: [261]u16 = undefined;
    const n = c.GetShortPathNameW(c.L("C:\\Program Files"), &short, short.len);
    if (n == 0 or n >= short.len) return error.SkipZigTest;
    const short8 = try std.unicode.utf16LeToUtf8Alloc(alloc, short[0..n]);
    defer alloc.free(short8);
    // 8.3 names are off on this volume.
    if (std.ascii.eqlIgnoreCase(short8, "C:\\Program Files")) return error.SkipZigTest;
    const d = try decide(alloc, short8);
    defer d.deinit(alloc);
    try std.testing.expect(d == .open);
    try std.testing.expectEqualStrings("C:\\Program Files", d.open.value);
}

/// A file in %TEMP% for a test, deleted by `deinit`.
const TempFile = struct {
    path: []u8,

    fn create(name: []const u8) !TempFile {
        const alloc = std.testing.allocator;
        var tmp: [261]u16 = undefined;
        const n = c.GetTempPathW(tmp.len, &tmp);
        if (n == 0 or n >= tmp.len) return error.SkipZigTest;
        const dir = try std.unicode.utf16LeToUtf8Alloc(alloc, tmp[0..n]);
        defer alloc.free(dir);
        const path = try std.fmt.allocPrint(alloc, "{s}ghostty-url-test-{d}-{s}", .{ dir, c.GetCurrentProcessId(), name });
        errdefer alloc.free(path);
        const path16 = try text_util.utf16Lossy(alloc, path);
        defer alloc.free(path16);
        const h = c.CreateFileW(path16, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
        if (h == c.INVALID_HANDLE_VALUE) return error.SkipZigTest;
        _ = c.CloseHandle(h);
        return .{ .path = path };
    }

    fn deinit(self: TempFile) void {
        const alloc = std.testing.allocator;
        if (text_util.utf16Lossy(alloc, self.path)) |p| {
            _ = c.DeleteFileW(p);
            alloc.free(p);
        } else |_| {}
        alloc.free(self.path);
    }
};

test "url: scripts are denied, unknown types ask" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "tool.pyw", "addin.xll", "theme.themepack", "session.rdp", "component.wsc" }) |name| {
        const f = try TempFile.create(name);
        defer f.deinit();
        const d = try decide(alloc, f.path);
        defer d.deinit(alloc);
        std.testing.expect(d == .deny and d.deny.reason == .unsafe_file) catch |err| {
            std.debug.print("{s}: {t}\n", .{ name, d });
            return err;
        };
    }
    for ([_][]const u8{ "data.ghosttytestdata", "README" }) |name| {
        const f = try TempFile.create(name);
        defer f.deinit();
        const d = try decide(alloc, f.path);
        defer d.deinit(alloc);
        try std.testing.expect(d == .confirm and d.confirm.item);
    }
    const f = try TempFile.create("notes.txt");
    defer f.deinit();
    const d = try decide(alloc, f.path);
    defer d.deinit(alloc);
    try std.testing.expect(d == .open and d.open.item);
}

test "url: the program registered for a type is checked" {
    const alloc = std.testing.allocator;
    // Python's launcher, where Python is installed.
    const exe = try assocString(alloc, ".pyw", c.ASSOCSTR_EXECUTABLE, null) orelse return error.SkipZigTest;
    defer alloc.free(exe);
    try std.testing.expect(runsCode(exe));
    try std.testing.expect(try handlerRunsCode(alloc, ".pyw"));
    try std.testing.expect(!try handlerRunsCode(alloc, ".txt"));
}

test "url: the shell's own list catches types missing from ours" {
    // .wsc (a Windows Script Component) is on the shell's list but not
    // ours.
    try std.testing.expect(!listed(&unsafe_extensions, ".wsc"));
    try std.testing.expect(try unsafeType(std.testing.allocator, ".wsc"));
    try std.testing.expect(!try unsafeType(std.testing.allocator, ".txt"));
}
