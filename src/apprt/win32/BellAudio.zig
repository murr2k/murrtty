//! The bell's `audio` feature (roadmap 3.7b): `bell-audio-path` played at
//! `bell-audio-volume`, as GTK plays it (gtk/media.zig): one player for
//! the application, made at the first bell and given the file again when
//! the path changes, rewound and played on each bell, whether or not the
//! pane has the keyboard.
//!
//! Media Foundation's media engine plays it (audio only, the Alerts
//! category), so the volume and the formats Windows decodes (WAV, MP3,
//! AAC, WMA, FLAC; Ogg where its extension is installed) work. Media
//! Foundation is loaded at the first bell, by full path from System32: a
//! Windows Server without its feature has no mfplat.dll, and no sound. The
//! engine calls back on a thread of its own: its notify object only counts
//! events in atomics (the test dump reads them) and logs a failure of a
//! required file, as GTK logs one.

const BellAudio = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");

const log = std.log.scoped(.win32_bell_audio);

const GUID = c.GUID;
const HRESULT = c.HRESULT;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

const CLSID_MFMediaEngineClassFactory = GUID.parse("{b44392da-499b-446b-a4cb-005fead0e6d5}");
const IID_IMFMediaEngineClassFactory = GUID.parse("{4d645ace-26aa-4688-9be1-df3516990b93}");
const IID_IMFMediaEngineNotify = GUID.parse("{fee7c112-e776-42b5-9bbf-0048524e2bd5}");
const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");
const MF_MEDIA_ENGINE_CALLBACK = GUID.parse("{c60381b8-83a4-41f8-a3d0-de05076849a9}");
const MF_MEDIA_ENGINE_AUDIO_CATEGORY = GUID.parse("{c8d4c51d-350e-41f2-ba46-faebbb0857f6}");

/// MF_VERSION (MF_SDK_VERSION 2, MF_API_VERSION 0x70) and MFSTARTUP_LITE.
const MF_VERSION: u32 = 0x00020070;
const MFSTARTUP_LITE: u32 = 1;
const MF_MEDIA_ENGINE_AUDIOONLY: u32 = 0x1;
const AudioCategory_Alerts: u32 = 4;

/// The media engine's events (MF_MEDIA_ENGINE_EVENT) this counts.
pub const Event = enum(u32) {
    loadstart = 1,
    @"error" = 5,
    playing = 13,
    ended = 19,
    _,
};

const Unknown = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;

/// IMFAttributes, to SetUnknown (mfobjects.h's order).
const IMFAttributes = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        unused: [18]Unused, // GetItem .. DeleteAllItems
        SetUINT32: *const fn (*IMFAttributes, *const GUID, u32) callconv(.winapi) HRESULT,
        SetUINT64: Unused,
        SetDouble: Unused,
        SetGUID: Unused,
        SetString: Unused,
        SetBlob: Unused,
        SetUnknown: *const fn (*IMFAttributes, *const GUID, ?*anyopaque) callconv(.winapi) HRESULT,
    },

    fn release(self: *IMFAttributes) void {
        _ = self.vtbl.unknown.Release(self);
    }
};

const IMFMediaEngineClassFactory = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        CreateInstance: *const fn (*IMFMediaEngineClassFactory, u32, *IMFAttributes, *?*IMFMediaEngine) callconv(.winapi) HRESULT,
    },

    fn release(self: *IMFMediaEngineClassFactory) void {
        _ = self.vtbl.unknown.Release(self);
    }
};

const IMFMediaError = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        GetErrorCode: *const fn (*IMFMediaError) callconv(.winapi) u16,
        GetExtendedErrorCode: *const fn (*IMFMediaError) callconv(.winapi) HRESULT,
    },

    fn release(self: *IMFMediaError) void {
        _ = self.vtbl.unknown.Release(self);
    }
};

/// IMFMediaEngine (mfmediaengine.h's order), to the last slot used.
const IMFMediaEngine = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        GetError: *const fn (*IMFMediaEngine, *?*IMFMediaError) callconv(.winapi) HRESULT,
        SetErrorCode: Unused,
        SetSourceElements: Unused,
        SetSource: *const fn (*IMFMediaEngine, ?[*:0]u16) callconv(.winapi) HRESULT,
        GetCurrentSource: Unused,
        GetNetworkState: Unused,
        GetPreload: Unused,
        SetPreload: Unused,
        GetBuffered: Unused,
        Load: Unused,
        CanPlayType: Unused,
        GetReadyState: Unused,
        IsSeeking: Unused,
        GetCurrentTime: Unused,
        SetCurrentTime: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        GetStartTime: Unused,
        GetDuration: Unused,
        IsPaused: Unused,
        GetDefaultPlaybackRate: Unused,
        SetDefaultPlaybackRate: Unused,
        GetPlaybackRate: Unused,
        SetPlaybackRate: Unused,
        GetPlayed: Unused,
        GetSeekable: Unused,
        IsEnded: Unused,
        GetAutoPlay: Unused,
        SetAutoPlay: Unused,
        GetLoop: *const fn (*IMFMediaEngine) callconv(.winapi) c.BOOL,
        SetLoop: *const fn (*IMFMediaEngine, c.BOOL) callconv(.winapi) HRESULT,
        Play: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        Pause: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        GetMuted: Unused,
        SetMuted: Unused,
        GetVolume: *const fn (*IMFMediaEngine) callconv(.winapi) f64,
        SetVolume: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        HasVideo: Unused,
        HasAudio: Unused,
        GetNativeVideoSize: Unused,
        GetVideoAspectRatio: Unused,
        Shutdown: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
    },

    fn release(self: *IMFMediaEngine) void {
        _ = self.vtbl.unknown.Release(self);
    }

    /// The error code (MF_MEDIA_ENGINE_ERR) of the last failure, 0 none.
    fn errorCode(self: *IMFMediaEngine) u16 {
        var err: ?*IMFMediaError = null;
        if (self.vtbl.GetError(self, &err) < 0) return 0;
        const e = err orelse return 0;
        defer e.release();
        return e.vtbl.GetErrorCode(e);
    }
};

/// IMFMediaEngineNotify: counts the events, on the engine's thread.
const Notify = struct {
    /// The vtable first, as COM lays an object out.
    vtbl: *const VTable = &vtable,
    refs: std.atomic.Value(u32) = .init(1),
    loadstart: std.atomic.Value(u32) = .init(0),
    playing: std.atomic.Value(u32) = .init(0),
    ended: std.atomic.Value(u32) = .init(0),
    errors: std.atomic.Value(u32) = .init(0),
    /// The last error's MF_MEDIA_ENGINE_ERR code and HRESULT.
    error_code: std.atomic.Value(u32) = .init(0),
    error_hr: std.atomic.Value(u32) = .init(0),
    /// Whether the file playing is required (a failure is logged).
    required: std.atomic.Value(bool) = .init(false),

    comptime {
        std.debug.assert(@offsetOf(Notify, "vtbl") == 0);
    }

    const VTable = extern struct {
        QueryInterface: *const fn (*Notify, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Notify) callconv(.winapi) u32,
        Release: *const fn (*Notify) callconv(.winapi) u32,
        EventNotify: *const fn (*Notify, u32, usize, u32) callconv(.winapi) HRESULT,
    };

    const vtable: VTable = .{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &releaseNotify,
        .EventNotify = &eventNotify,
    };

    fn create() !*Notify {
        const self = try std.heap.page_allocator.create(Notify);
        self.* = .{};
        return self;
    }

    fn queryInterface(self: *Notify, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IMFMediaEngineNotify)) {
            _ = addRef(self);
            out.* = self;
            return c.S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *Notify) callconv(.winapi) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseNotify(self: *Notify) callconv(.winapi) u32 {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) std.heap.page_allocator.destroy(self);
        return left;
    }

    fn eventNotify(self: *Notify, event: u32, param1: usize, param2: u32) callconv(.winapi) HRESULT {
        switch (@as(Event, @enumFromInt(event))) {
            .loadstart => _ = self.loadstart.fetchAdd(1, .monotonic),
            .playing => _ = self.playing.fetchAdd(1, .monotonic),
            .ended => _ = self.ended.fetchAdd(1, .monotonic),
            .@"error" => {
                self.error_code.store(@truncate(param1), .monotonic);
                self.error_hr.store(param2, .monotonic);
                _ = self.errors.fetchAdd(1, .release);
                if (self.required.load(.monotonic)) {
                    log.warn("error playing bell-audio-path: code {d}, 0x{x:0>8}", .{ param1, param2 });
                }
            },
            _ => {},
        }
        return c.S_OK;
    }
};

/// The functions taken from System32's DLLs, loaded once.
const Api = struct {
    MFStartup: *const fn (u32, u32) callconv(.winapi) HRESULT,
    MFShutdown: *const fn () callconv(.winapi) HRESULT,
    MFCreateAttributes: *const fn (*?*IMFAttributes, u32) callconv(.winapi) HRESULT,
    SysAllocString: *const fn ([*:0]const u16) callconv(.winapi) ?[*:0]u16,
    SysFreeString: *const fn (?[*:0]u16) callconv(.winapi) void,

    fn load() ?Api {
        const mfplat = c.LoadLibraryExW(c.L("mfplat.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
        const oleaut = c.LoadLibraryExW(c.L("oleaut32.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
        // @alignCast too: GetProcAddress's pointer is byte-aligned, a
        // function's isn't on ARM64.
        return .{
            .MFStartup = @ptrCast(@alignCast(c.GetProcAddress(mfplat, "MFStartup") orelse return null)),
            .MFShutdown = @ptrCast(@alignCast(c.GetProcAddress(mfplat, "MFShutdown") orelse return null)),
            .MFCreateAttributes = @ptrCast(@alignCast(c.GetProcAddress(mfplat, "MFCreateAttributes") orelse return null)),
            .SysAllocString = @ptrCast(@alignCast(c.GetProcAddress(oleaut, "SysAllocString") orelse return null)),
            .SysFreeString = @ptrCast(@alignCast(c.GetProcAddress(oleaut, "SysFreeString") orelse return null)),
        };
    }
};

alloc: Allocator,
api: ?Api = null,
/// Media Foundation was tried and isn't there (or wouldn't start): no
/// sound, and no more tries.
unavailable: bool = false,
engine: ?*IMFMediaEngine = null,
notify: ?*Notify = null,
/// The file the engine has, owned.
path: ?[]u8 = null,
/// Bells that asked for the sound, and the volume last asked for.
rings: u32 = 0,
volume: f64 = 0,

pub fn init(alloc: Allocator) BellAudio {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *BellAudio) void {
    if (self.engine) |e| {
        _ = e.vtbl.Shutdown(e);
        e.release();
        self.engine = null;
    }
    if (self.notify) |n| {
        _ = n.vtbl.Release(n);
        self.notify = null;
    }
    if (self.api) |api| {
        _ = api.MFShutdown();
        self.api = null;
    }
    if (self.path) |p| self.alloc.free(p);
    self.path = null;
}

/// Play `path` (from the config: absolute, `~` expanded) at `volume`
/// (clamped to 0 to 1, GTK's media stream volume); a failure of a
/// `required` file is logged when the engine reports it.
pub fn ring(self: *BellAudio, path: []const u8, required: bool, volume: f64) void {
    self.rings +|= 1;
    self.volume = std.math.clamp(volume, 0.0, 1.0);
    const engine = self.ensureEngine() orelse return;
    const notify = self.notify.?;
    notify.required.store(required, .monotonic);
    if (self.path == null or !std.mem.eql(u8, self.path.?, path)) {
        if (!self.setSource(engine, path)) return;
    }
    _ = engine.vtbl.SetVolume(engine, self.volume);
    // A file that played to its end plays again only from the start, as
    // GTK's seek(0); before it has loaded this fails, harmlessly.
    _ = engine.vtbl.SetCurrentTime(engine, 0);
    const hr = engine.vtbl.Play(engine);
    if (hr < 0) log.warn("bell audio didn't play: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
}

fn setSource(self: *BellAudio, engine: *IMFMediaEngine, path: []const u8) bool {
    const api = self.api.?;
    const owned = self.alloc.dupe(u8, path) catch return false;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(self.alloc, path) catch {
        self.alloc.free(owned);
        return false;
    };
    defer self.alloc.free(wide);
    const bstr = api.SysAllocString(wide.ptr) orelse {
        self.alloc.free(owned);
        return false;
    };
    defer api.SysFreeString(bstr);
    const hr = engine.vtbl.SetSource(engine, bstr);
    if (hr < 0) {
        log.warn("bell audio can't open {s}: 0x{x:0>8}", .{ path, @as(u32, @bitCast(hr)) });
        self.alloc.free(owned);
        return false;
    }
    if (self.path) |p| self.alloc.free(p);
    self.path = owned;
    return true;
}

/// The engine, made at the first bell; null without Media Foundation.
fn ensureEngine(self: *BellAudio) ?*IMFMediaEngine {
    if (self.engine) |e| return e;
    if (self.unavailable) return null;
    self.unavailable = true;
    const api = Api.load() orelse {
        log.info("no Media Foundation (mfplat.dll): bell audio is off", .{});
        return null;
    };
    if (api.MFStartup(MF_VERSION, MFSTARTUP_LITE) < 0) {
        log.warn("Media Foundation didn't start: bell audio is off", .{});
        return null;
    }
    self.api = api;
    const made = createEngine(api) catch |err| {
        log.warn("no media engine for the bell's audio: {}", .{err});
        return null;
    };
    self.engine = made.engine;
    self.notify = made.notify;
    self.unavailable = false;
    return made.engine;
}

const Made = struct { engine: *IMFMediaEngine, notify: *Notify };

fn createEngine(api: Api) !Made {
    var factory_out: ?*anyopaque = null;
    if (c.CoCreateInstance(&CLSID_MFMediaEngineClassFactory, null, c.CLSCTX_INPROC_SERVER, &IID_IMFMediaEngineClassFactory, &factory_out) < 0)
        return error.NoFactory;
    const factory: *IMFMediaEngineClassFactory = @ptrCast(@alignCast(factory_out orelse return error.NoFactory));
    defer factory.release();

    var attrs_out: ?*IMFAttributes = null;
    if (api.MFCreateAttributes(&attrs_out, 2) < 0) return error.NoAttributes;
    const attrs = attrs_out orelse return error.NoAttributes;
    defer attrs.release();

    const notify = try Notify.create();
    errdefer _ = notify.vtbl.Release(notify);
    if (attrs.vtbl.SetUnknown(attrs, &MF_MEDIA_ENGINE_CALLBACK, notify) < 0) return error.NoCallback;
    _ = attrs.vtbl.SetUINT32(attrs, &MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_Alerts);

    var engine: ?*IMFMediaEngine = null;
    if (factory.vtbl.CreateInstance(factory, MF_MEDIA_ENGINE_AUDIOONLY, attrs, &engine) < 0) return error.NoEngine;
    return .{ .engine = engine orelse return error.NoEngine, .notify = notify };
}

/// What the test dump shows.
pub const State = struct {
    available: bool,
    rings: u32,
    path: ?[]const u8,
    volume: f64,
    loadstart: u32,
    playing: u32,
    ended: u32,
    errors: u32,
    error_code: u32,
    error_hr: u32,
};

pub fn state(self: *const BellAudio) State {
    const n = self.notify;
    return .{
        .available = self.engine != null,
        .rings = self.rings,
        .path = self.path,
        .volume = self.volume,
        .loadstart = if (n) |x| x.loadstart.load(.monotonic) else 0,
        .playing = if (n) |x| x.playing.load(.monotonic) else 0,
        .ended = if (n) |x| x.ended.load(.monotonic) else 0,
        .errors = if (n) |x| x.errors.load(.acquire) else 0,
        .error_code = if (n) |x| x.error_code.load(.monotonic) else 0,
        .error_hr = if (n) |x| x.error_hr.load(.monotonic) else 0,
    };
}

/// A WAV of `ms` milliseconds of silence (16-bit mono, 8 kHz): what the
/// tests play, so no test makes a sound.
pub fn silentWav(alloc: Allocator, ms: u32) ![]u8 {
    const rate = 8000;
    const samples = rate * ms / 1000;
    const data_len: u32 = samples * 2;
    const out = try alloc.alloc(u8, 44 + data_len);
    @memset(out, 0);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // mono
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    return out;
}

test "BellAudio: every slot used, and a silent file through the engine" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const init_hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (init_hr >= 0) c.CoUninitialize();

    var audio: BellAudio = .init(alloc);
    defer audio.deinit();
    const engine = audio.ensureEngine() orelse return error.SkipZigTest;

    // Round trips that a wrong slot would break.
    try testing.expect(engine.vtbl.SetVolume(engine, 0.25) >= 0);
    try testing.expectApproxEqAbs(@as(f64, 0.25), engine.vtbl.GetVolume(engine), 0.0001);
    try testing.expect(engine.vtbl.SetLoop(engine, 1) >= 0);
    try testing.expect(engine.vtbl.GetLoop(engine) != 0);
    try testing.expect(engine.vtbl.SetLoop(engine, 0) >= 0);
    try testing.expect(engine.vtbl.GetLoop(engine) == 0);
    try testing.expectEqual(@as(u16, 0), engine.errorCode());

    // A silent file, rung twice: the engine starts loading it and plays,
    // or, with no audio device, reports an error; either way the notify
    // object hears it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try silentWav(alloc, 200);
    defer alloc.free(wav);
    {
        var file = try tmp.dir.createFile(testing.io, "bell.wav", .{});
        defer file.close(testing.io);
        var buf: [4096]u8 = undefined;
        var file_writer = file.writer(testing.io, &buf);
        try file_writer.interface.writeAll(wav);
        try file_writer.interface.flush();
    }
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "bell.wav" });
    defer alloc.free(path);
    audio.ring(path, true, 2.0);
    try testing.expectEqual(@as(f64, 1.0), audio.volume);
    try testing.expectEqualStrings(path, audio.path.?);
    audio.ring(path, true, 0.5);
    try testing.expectEqual(@as(u32, 2), audio.rings);

    var waited: u32 = 0;
    while (waited < 5000) : (waited += 50) {
        const s = audio.state();
        if (s.loadstart > 0 and (s.playing > 0 or s.ended > 0 or s.errors > 0)) break;
        c.Sleep(50);
    }
    const s = audio.state();
    try testing.expect(s.loadstart > 0);
    try testing.expect(s.playing > 0 or s.ended > 0 or s.errors > 0);
    _ = engine.vtbl.Pause(engine);
}

test "silentWav is a valid PCM WAV" {
    const alloc = std.testing.allocator;
    const wav = try silentWav(alloc, 100);
    defer alloc.free(wav);
    try std.testing.expectEqual(@as(usize, 44 + 1600), wav.len);
    try std.testing.expectEqualStrings("RIFF", wav[0..4]);
    try std.testing.expectEqualStrings("data", wav[36..40]);
    try std.testing.expectEqual(@as(u32, 1600), std.mem.readInt(u32, wav[40..44], .little));
}
