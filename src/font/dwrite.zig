//! DirectWrite for Windows font discovery (murrtty's roadmap 6.1): the
//! system font collection (every installed font, wherever the registry
//! has its file, found by any of its localized family names) and its
//! locale-aware fallback (IDWriteFontFallback::MapCharacters). Discovery
//! only: the files found are still rasterized by FreeType. Hand-written
//! COM bindings for the few methods used, each vtable laid out up to its
//! last slot used (dwrite.h, dwrite_2.h).
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dwrite);

const HRESULT = i32;
const BOOL = i32;
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const Slot = ?*const anyopaque;

const IID_IDWriteFactory2: GUID = .{ .a = 0x0439fc60, .b = 0xca44, .c = 0x4994, .d = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };
const IID_IDWriteLocalFontFileLoader: GUID = .{ .a = 0xb2d9f3ec, .b = 0xc9fe, .c = 0x4a11, .d = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 } };
const IID_IDWriteTextAnalysisSource: GUID = .{ .a = 0x688e1a58, .b = 0x5094, .c = 0x47c8, .d = .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b } };
const IID_IUnknown: GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };

const DWRITE_FACTORY_TYPE_SHARED = 0;
const DWRITE_FONT_WEIGHT_NORMAL = 400;
const DWRITE_FONT_WEIGHT_BOLD = 700;
const DWRITE_FONT_STYLE_NORMAL = 0;
const DWRITE_FONT_STYLE_ITALIC = 2;
const DWRITE_FONT_STRETCH_NORMAL = 5;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
/// LOCALE_NAME_MAX_LENGTH, its terminator included.
pub const locale_max = 85;

extern "dwrite" fn DWriteCreateFactory(factory_type: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "kernel32" fn GetUserDefaultLocaleName(name: [*]u16, len: c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetUserPreferredUILanguages(flags: u32, count: *u32, buf: ?[*]u16, len: *u32) callconv(.winapi) BOOL;
const MUI_LANGUAGE_NAME = 0x8;

fn IUnknownSlots(comptime T: type) type {
    return extern struct {
        QueryInterface: *const fn (*T, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*T) callconv(.winapi) u32,
        Release: *const fn (*T) callconv(.winapi) u32,
    };
}

fn release(obj: anytype) void {
    _ = obj.vtable.unknown.Release(obj);
}

/// IDWriteFactory2.
const Factory = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(Factory),
        GetSystemFontCollection: *const fn (*Factory, *?*FontCollection, BOOL) callconv(.winapi) HRESULT, // 3
        _4_25: [22]Slot,
        GetSystemFontFallback: *const fn (*Factory, *?*FontFallback) callconv(.winapi) HRESULT, // 26
    },
};

/// IDWriteFontCollection.
const FontCollection = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontCollection),
        GetFontFamilyCount: *const fn (*FontCollection) callconv(.winapi) u32, // 3
        GetFontFamily: *const fn (*FontCollection, u32, *?*FontFamily) callconv(.winapi) HRESULT, // 4
        FindFamilyName: *const fn (*FontCollection, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT, // 5
    },
};

/// IDWriteFontFamily (an IDWriteFontList).
const FontFamily = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontFamily),
        _3: Slot, // GetFontCollection
        GetFontCount: *const fn (*FontFamily) callconv(.winapi) u32, // 4
        GetFont: *const fn (*FontFamily, u32, *?*Font) callconv(.winapi) HRESULT, // 5
    },
};

/// IDWriteFont.
const Font = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(Font),
        _3_9: [7]Slot, // GetFontFamily ... GetInformationalStrings
        GetSimulations: *const fn (*Font) callconv(.winapi) u32, // 10
        _11: Slot, // GetMetrics
        HasCharacter: *const fn (*Font, u32, *BOOL) callconv(.winapi) HRESULT, // 12
        CreateFontFace: *const fn (*Font, *?*FontFace) callconv(.winapi) HRESULT, // 13
    },
};

/// IDWriteFontFace.
const FontFace = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontFace),
        _3: Slot, // GetType
        GetFiles: *const fn (*FontFace, *u32, ?[*]?*FontFile) callconv(.winapi) HRESULT, // 4
        GetIndex: *const fn (*FontFace) callconv(.winapi) u32, // 5
    },
};

/// IDWriteFontFile.
const FontFile = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontFile),
        GetReferenceKey: *const fn (*FontFile, *?*const anyopaque, *u32) callconv(.winapi) HRESULT, // 3
        GetLoader: *const fn (*FontFile, *?*FontFileLoader) callconv(.winapi) HRESULT, // 4
    },
};

/// IDWriteFontFileLoader.
const FontFileLoader = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontFileLoader),
    },
};

/// IDWriteLocalFontFileLoader: a loader for files on disk.
const LocalFontFileLoader = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(LocalFontFileLoader),
        _3: Slot, // CreateStreamFromKey
        GetFilePathLengthFromKey: *const fn (*LocalFontFileLoader, ?*const anyopaque, u32, *u32) callconv(.winapi) HRESULT, // 4
        GetFilePathFromKey: *const fn (*LocalFontFileLoader, ?*const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT, // 5
    },
};

/// IDWriteFontFallback.
const FontFallback = extern struct {
    vtable: *const extern struct {
        unknown: IUnknownSlots(FontFallback),
        MapCharacters: *const fn (
            *FontFallback,
            *AnalysisSource,
            u32,
            u32,
            ?*FontCollection,
            ?[*:0]const u16,
            u32,
            u32,
            u32,
            *u32,
            *?*Font,
            *f32,
        ) callconv(.winapi) HRESULT, // 3
    },
};

/// Our IDWriteTextAnalysisSource for MapCharacters: one character of text
/// in one locale, left to right, no number substitution. It lives on the
/// stack for the call, so its references count nothing.
const AnalysisSource = extern struct {
    vtable: *const VTable,
    text: [*]const u16,
    len: u32,
    locale: [*:0]const u16,

    const VTable = extern struct {
        unknown: IUnknownSlots(AnalysisSource),
        GetTextAtPosition: *const fn (*AnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (*AnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (*AnalysisSource) callconv(.winapi) u32,
        GetLocaleName: *const fn (*AnalysisSource, u32, *u32, *?[*:0]const u16) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (*AnalysisSource, u32, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    const vtable_value: VTable = .{
        .unknown = .{ .QueryInterface = &queryInterface, .AddRef = &addRef, .Release = &addRef },
        .GetTextAtPosition = &textAt,
        .GetTextBeforePosition = &textBefore,
        .GetParagraphReadingDirection = &direction,
        .GetLocaleName = &localeName,
        .GetNumberSubstitution = &numberSubstitution,
    };

    fn queryInterface(self: *AnalysisSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, IID_IDWriteTextAnalysisSource) or std.meta.eql(iid.*, IID_IUnknown)) {
            out.* = self;
            return 0;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(_: *AnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn textAt(self: *AnalysisSource, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        if (pos >= self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text + pos;
            len.* = self.len - pos;
        }
        return 0;
    }

    fn textBefore(self: *AnalysisSource, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        if (pos == 0 or pos > self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text;
            len.* = pos;
        }
        return 0;
    }

    fn direction(_: *AnalysisSource) callconv(.winapi) u32 {
        return 0; // DWRITE_READING_DIRECTION_LEFT_TO_RIGHT
    }

    fn localeName(self: *AnalysisSource, pos: u32, len: *u32, name: *?[*:0]const u16) callconv(.winapi) HRESULT {
        len.* = self.len -| pos;
        name.* = self.locale;
        return 0;
    }

    fn numberSubstitution(self: *AnalysisSource, pos: u32, len: *u32, sub: *?*anyopaque) callconv(.winapi) HRESULT {
        len.* = self.len -| pos;
        sub.* = null;
        return 0;
    }
};

/// A font's file and its face's index in it. `path` is owned.
pub const File = struct {
    path: [:0]u8,
    index: u32,

    pub fn deinit(self: File, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

/// DirectWrite's shared factory and its system fallback. The system font
/// collection is asked for at each use (the factory keeps it, and hands
/// out a new one once fonts are installed or removed), so a font
/// installed while murrtty runs is found by the next discovery. The
/// factory, the collections and the fallback are free-threaded: renderer
/// threads discover fallbacks at once.
pub const Dwrite = struct {
    factory: *Factory,
    fallback: ?*FontFallback,

    /// Null where DirectWrite (or its Windows 8.1 factory) is missing.
    pub fn init() ?Dwrite {
        var raw: ?*anyopaque = null;
        if (DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory2, &raw) < 0) return null;
        const factory: *Factory = @ptrCast(@alignCast(raw orelse return null));
        // Once now with a check for fonts installed since the font cache
        // last looked; later uses see changes as the font cache reports
        // them.
        var collection: ?*FontCollection = null;
        if (factory.vtable.GetSystemFontCollection(factory, &collection, 1) < 0 or collection == null) {
            release(factory);
            return null;
        }
        release(collection.?);
        var fallback: ?*FontFallback = null;
        if (factory.vtable.GetSystemFontFallback(factory, &fallback) < 0) fallback = null;
        return .{ .factory = factory, .fallback = fallback };
    }

    pub fn deinit(self: *Dwrite) void {
        if (self.fallback) |f| release(f);
        release(self.factory);
    }

    /// The system font collection as it is now; the caller releases it.
    fn systemCollection(self: *const Dwrite) ?*FontCollection {
        var collection: ?*FontCollection = null;
        if (self.factory.vtable.GetSystemFontCollection(self.factory, &collection, 0) < 0) return null;
        return collection;
    }

    /// The files of the faces of family `name` (any of its localized names,
    /// as DirectWrite matches them), each once; empty if there is no such
    /// family. Faces DirectWrite only simulates (a bold made from the
    /// regular) are left out: FreeType has only the real files. The caller
    /// owns them (File.deinit, then the slice).
    pub fn familyFiles(self: *const Dwrite, alloc: Allocator, name: []const u8) Allocator.Error![]File {
        var out: std.ArrayList(File) = .empty;
        errdefer {
            for (out.items) |f| f.deinit(alloc);
            out.deinit(alloc);
        }
        const name_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return out.toOwnedSlice(alloc),
        };
        defer alloc.free(name_w);
        const collection = self.systemCollection() orelse return out.toOwnedSlice(alloc);
        defer release(collection);
        var index: u32 = 0;
        var exists: BOOL = 0;
        if (collection.vtable.FindFamilyName(collection, name_w.ptr, &index, &exists) < 0 or exists == 0)
            return out.toOwnedSlice(alloc);
        var family: ?*FontFamily = null;
        if (collection.vtable.GetFontFamily(collection, index, &family) < 0) return out.toOwnedSlice(alloc);
        const fam = family orelse return out.toOwnedSlice(alloc);
        defer release(fam);
        const count = fam.vtable.GetFontCount(fam);
        for (0..count) |i| {
            var font: ?*Font = null;
            if (fam.vtable.GetFont(fam, @intCast(i), &font) < 0) continue;
            const f = font orelse continue;
            defer release(f);
            if (f.vtable.GetSimulations(f) != 0) continue;
            const file = (try fileOf(alloc, f)) orelse continue;
            const dup = for (out.items) |o| {
                if (o.index == file.index and std.ascii.eqlIgnoreCase(o.path, file.path)) break true;
            } else false;
            if (dup) {
                file.deinit(alloc);
                continue;
            }
            try out.append(alloc, file);
        }
        return out.toOwnedSlice(alloc);
    }

    /// The font DirectWrite falls back to for `codepoint` in `locale`
    /// (BCP 47, "ja-JP"), as bold or italic as asked: where Japanese,
    /// Chinese and Korean text sharing ideographs get a font of their own.
    /// Null if none has it, or for a surrogate code point. The caller owns
    /// the result.
    pub fn fallbackFile(
        self: *const Dwrite,
        alloc: Allocator,
        codepoint: u21,
        locale: [*:0]const u16,
        bold: bool,
        italic: bool,
    ) Allocator.Error!?File {
        const fallback = self.fallback orelse return null;
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF or codepoint > 0x10FFFF) return null;
        const collection = self.systemCollection() orelse return null;
        defer release(collection);
        var text: [2]u16 = undefined;
        const len: u32 = if (codepoint < 0x10000) one: {
            text[0] = @intCast(codepoint);
            break :one 1;
        } else two: {
            const v = codepoint - 0x10000;
            text[0] = @intCast(0xD800 + (v >> 10));
            text[1] = @intCast(0xDC00 + (v & 0x3FF));
            break :two 2;
        };
        var source: AnalysisSource = .{ .vtable = &AnalysisSource.vtable_value, .text = &text, .len = len, .locale = locale };
        var mapped_len: u32 = 0;
        var font: ?*Font = null;
        var scale: f32 = 1;
        const hr = fallback.vtable.MapCharacters(
            fallback,
            &source,
            0,
            len,
            collection,
            null,
            if (bold) DWRITE_FONT_WEIGHT_BOLD else DWRITE_FONT_WEIGHT_NORMAL,
            if (italic) DWRITE_FONT_STYLE_ITALIC else DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            &mapped_len,
            &font,
            &scale,
        );
        const f = font orelse return null;
        defer release(f);
        if (hr < 0 or mapped_len == 0) return null;
        return try fileOf(alloc, f);
    }
};

/// The language the user reads (BCP 47), into `buf`: Windows' display
/// language, the first of the preferred ones, else the regional format's;
/// null if Windows has neither. As the other platforms pick a fallback by
/// the preferred languages (macOS) or the locale (fontconfig).
pub fn userLocale(buf: *[locale_max]u16) ?[*:0]const u16 {
    // A double-NUL-terminated list; the first entry is the one wanted.
    var list: [locale_max * 4 + 1]u16 = undefined;
    var count: u32 = 0;
    var len: u32 = list.len;
    if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, &list, &len) != 0 and count > 0) {
        const first = std.mem.sliceTo(list[0..@min(len, list.len)], 0);
        if (first.len > 0 and first.len < locale_max) {
            @memcpy(buf[0..first.len], first);
            buf[first.len] = 0;
            return @ptrCast(buf);
        }
    }
    if (GetUserDefaultLocaleName(buf, locale_max) == 0) return null;
    return @ptrCast(buf);
}

/// `font`'s file on disk and face index; null for a font that isn't a
/// local file (a downloadable or in-memory one).
fn fileOf(alloc: Allocator, font: *Font) Allocator.Error!?File {
    var face: ?*FontFace = null;
    if (font.vtable.CreateFontFace(font, &face) < 0) return null;
    const ff = face orelse return null;
    defer release(ff);
    var count: u32 = 0;
    if (ff.vtable.GetFiles(ff, &count, null) < 0 or count == 0) return null;
    // A face has one file, or a few (Type 1's metrics and outlines): the
    // first is the one to open. Released whatever GetFiles left in them.
    var files: [8]?*FontFile = @splat(null);
    defer for (files) |file| if (file) |fl| release(fl);
    if (count > files.len) return null;
    if (ff.vtable.GetFiles(ff, &count, &files) < 0) return null;
    const first = files[0] orelse return null;

    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (first.vtable.GetReferenceKey(first, &key, &key_size) < 0) return null;
    var loader: ?*FontFileLoader = null;
    if (first.vtable.GetLoader(first, &loader) < 0) return null;
    const ld = loader orelse return null;
    defer release(ld);
    var local_raw: ?*anyopaque = null;
    if (ld.vtable.unknown.QueryInterface(ld, &IID_IDWriteLocalFontFileLoader, &local_raw) < 0) return null;
    const local: *LocalFontFileLoader = @ptrCast(@alignCast(local_raw orelse return null));
    defer release(local);

    var path_len: u32 = 0;
    if (local.vtable.GetFilePathLengthFromKey(local, key, key_size, &path_len) < 0) return null;
    const path_w = try alloc.alloc(u16, path_len + 1);
    defer alloc.free(path_w);
    if (local.vtable.GetFilePathFromKey(local, key, key_size, path_w.ptr, path_len + 1) < 0) return null;
    const path = std.unicode.wtf16LeToWtf8AllocZ(alloc, path_w[0..path_len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .path = path, .index = ff.vtable.GetIndex(ff) };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.ascii.findIgnoreCase(haystack, n) != null) return true;
    return false;
}

test "familyFiles: Consolas, by its name" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var dw = Dwrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();

    const files = try dw.familyFiles(alloc, "Consolas");
    defer {
        for (files) |f| f.deinit(alloc);
        alloc.free(files);
    }
    // Consolas ships as four files, each a face of its own.
    try testing.expectEqual(@as(usize, 4), files.len);
    for (files) |f| try testing.expect(std.ascii.startsWithIgnoreCase(std.fs.path.basename(f.path), "consola"));

    const none = try dw.familyFiles(alloc, "No Such Family 6.1");
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "familyFiles: MS Gothic by its Japanese name" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var dw = Dwrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();

    const english = try dw.familyFiles(alloc, "MS Gothic");
    defer {
        for (english) |f| f.deinit(alloc);
        alloc.free(english);
    }
    if (english.len == 0) return error.SkipZigTest;
    // ＭＳ ゴシック: the localized name finds the same file.
    const files = try dw.familyFiles(alloc, "\u{FF2D}\u{FF33} \u{30B4}\u{30B7}\u{30C3}\u{30AF}");
    defer {
        for (files) |f| f.deinit(alloc);
        alloc.free(files);
    }
    try testing.expect(files.len > 0);
    try testing.expect(std.ascii.eqlIgnoreCase(files[0].path, english[0].path));
}

test "fallbackFile: an ideograph by the locale" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var dw = Dwrite.init() orelse return error.SkipZigTest;
    defer dw.deinit();
    if (dw.fallback == null) return error.SkipZigTest;

    // 漢: Japanese text falls back to a Japanese font, Chinese to a
    // Chinese one, Korean to a Korean one, where they are installed.
    const cases = [_]struct { locale: [:0]const u16, files: []const []const u8 }{
        .{ .locale = std.unicode.utf8ToUtf16LeStringLiteral("ja-JP"), .files = &.{ "yugoth", "msgothic", "meiryo", "msmincho", "yumin" } },
        .{ .locale = std.unicode.utf8ToUtf16LeStringLiteral("zh-CN"), .files = &.{ "msyh", "simsun", "simhei", "deng" } },
        .{ .locale = std.unicode.utf8ToUtf16LeStringLiteral("ko-KR"), .files = &.{ "malgun", "gulim", "batang" } },
    };
    var seen: [cases.len][]const u8 = undefined;
    var got: [cases.len]?File = @splat(null);
    defer for (got) |g| if (g) |f| f.deinit(alloc);
    for (cases, 0..) |case, i| {
        got[i] = try dw.fallbackFile(alloc, 0x6F22, case.locale.ptr, false, false);
        const file = got[i] orelse return error.TestUnexpectedResult;
        seen[i] = std.fs.path.basename(file.path);
        if (!containsAny(seen[i], case.files)) {
            std.debug.print("fallback for {any} went to {s}\n", .{ case.locale, file.path });
            return error.TestUnexpectedResult;
        }
    }
    // An emoji, beyond the BMP.
    const emoji = (try dw.fallbackFile(alloc, 0x1F600, std.unicode.utf8ToUtf16LeStringLiteral("en-US"), false, false)) orelse
        return error.TestUnexpectedResult;
    defer emoji.deinit(alloc);
    try testing.expect(containsAny(std.fs.path.basename(emoji.path), &.{"seguiemj"}));
}
