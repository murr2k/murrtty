//! What murrtty's Windows runtime shares with the renderer's present step,
//! whichever graphics API draws (OpenGL; Direct3D 11 with roadmap 7.8):
//! the shapes drawn over the frame, the translucency flag, the frame
//! counts and the GUI tests' read-back. Each Windows backend keeps one as
//! `present_state`, so the runtime and its test hooks name no API.
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");

/// Solid rectangles the present pass draws over the frame, blending in the
/// stored (sRGB) values as GTK's CSS overlays do.
pub const Overlay = struct {
    /// Room for the scrollbar, the progress bar, the dimming and the top
    /// bars' shade (a rect per row, 6 per 96 DPI).
    pub const max = 48;

    rects: [max]Rect = undefined,
    len: usize = 0,

    pub const Rect = struct {
        /// In the window's pixels from its top left corner.
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        /// sRGB, straight (not premultiplied) alpha.
        color: [4]f32,
    };
};

/// The terminal background, which the present pass composites the frame
/// over.
pub const Background = struct {
    /// sRGB.
    rgb: [3]u8,
    /// `background-opacity`, which a translucent window shows where the
    /// frame doesn't reach yet.
    alpha: u8 = 255,
    /// Whether the frame holds linear colors (alpha-blending is linear).
    linear: bool,
};

pub const State = struct {
    /// Set by the runtime while its window is translucent (roadmap 4.1,
    /// `background-opacity` below 1): present the frame with its own alpha,
    /// for DWM to compose over what is behind the window, instead of over
    /// the opaque background.
    transparent: std.atomic.Value(bool) = .init(false),

    /// Frames presented, in every build: UI Automation's poll looks at the
    /// text again only after one (6.4), murrtty's software start takes the
    /// first as "it draws" (6.3b).
    presented: std.atomic.Value(u32) = .init(0),

    /// Rectangles drawn over the frame, set by the UI thread (the dimming
    /// of an unfocused split pane, the scrollbar, the progress bar, the
    /// bars' shade) and read by the present.
    overlay_mutex: std.Io.Mutex = .init,
    overlay: Overlay = .{},

    /// A lost device or context (a GPU driver reset, roadmap 6.3):
    /// `fake_reset` is the GUI tests' stand-in for one; `contexts` counts
    /// the devices or contexts made, the first included; `robust` says
    /// whether the backend learns of a real one.
    fake_reset: std.atomic.Value(bool) = .init(false),
    contexts: std.atomic.Value(u32) = .init(1),
    robust: std.atomic.Value(bool) = .init(false),

    /// For the GUI tests (GHOSTTY_WIN32_TEST_DUMP set in a Debug build):
    /// each present reads back one pixel near the window's bottom-right
    /// corner into `sample` (0x00RRGGBB, as stored), and, once the tests
    /// ask for one, the pixel at `probe_point` (x | y << 16, from the top
    /// left) into `probe` (with bit 24 set once read). The state dump
    /// reports both. Captures can't see windows on the tests' hidden
    /// desktop.
    sampling: bool = false,
    sample: std.atomic.Value(u32) = .init(0),
    probe_point: std.atomic.Value(u32) = .init(no_probe),
    probe: std.atomic.Value(u32) = .init(0),
    /// Frames presented, so the tests can tell whether something drew.
    frames: std.atomic.Value(u32) = .init(0),
    /// And once asked (`frame_wanted`), the next present reads its whole
    /// back buffer into `frame` (BGRA rows, top first) and sets
    /// `frame_ready`; the UI thread takes the frame from there, freeing it
    /// (page_allocator) before it asks again. Window captures read white
    /// where DWM isn't composing; this is what was drawn.
    frame_wanted: std.atomic.Value(bool) = .init(false),
    frame_ready: std.atomic.Value(bool) = .init(false),
    frame: []u8 = &.{},
    frame_width: u32 = 0,
    frame_height: u32 = 0,

    pub const no_probe = std.math.maxInt(u32);
    pub const probe_read: u32 = 1 << 24;

    /// A pane's state, translucent from its first frame if its window is.
    pub fn init(transparent: bool, robust: bool) State {
        return .{
            .transparent = .init(transparent),
            .robust = .init(robust),
            .sampling = builtin.mode == .debug and
                GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_WIN32_TEST_DUMP"), null, 0) != 0,
        };
    }

    /// Replace the rectangles drawn over this surface's frames. They show
    /// from the next frame, so a caller that needs them now forces one.
    pub fn setOverlay(self: *State, rects: []const Overlay.Rect) void {
        self.overlay_mutex.lockUncancelable(global.io());
        defer self.overlay_mutex.unlock(global.io());
        const n = @min(rects.len, Overlay.max);
        @memcpy(self.overlay.rects[0..n], rects[0..n]);
        self.overlay.len = n;
    }

    /// The rectangles as they are now, for a present.
    pub fn overlayNow(self: *State) Overlay {
        self.overlay_mutex.lockUncancelable(global.io());
        defer self.overlay_mutex.unlock(global.io());
        return self.overlay;
    }

    /// The probe asked for, taken at a present's start (Debug, sampling):
    /// the present begun after the ask then sees everything set before it
    /// (a toggled opacity's `transparent`, say); one already under way,
    /// which a slow renderer makes likely, read what was set before.
    pub fn takeProbe(self: *State) u32 {
        if (comptime builtin.mode != .debug) return no_probe;
        if (!self.sampling) return no_probe;
        return self.probe_point.swap(no_probe, .acquire);
    }

    /// After the frame is drawn (shapes included) and before it presents:
    /// the frame count, the corner sample, the probe asked for (`point`,
    /// from takeProbe) and a whole frame if one was asked for. `pixel`
    /// reads one pixel as 0x00RRGGBB from the top left; `whole` the frame
    /// as BGRA rows, top first (page_allocator), null if it can't.
    pub fn readBack(
        self: *State,
        point: u32,
        width: u32,
        height: u32,
        ctx: anytype,
        comptime pixel: fn (@TypeOf(ctx), u32, u32) u32,
        comptime whole: fn (@TypeOf(ctx), u32, u32) ?[]u8,
    ) void {
        if (comptime builtin.mode != .debug) return;
        if (!self.sampling) return;
        _ = self.frames.fetchAdd(1, .monotonic);
        if (width > 6 and height > 6) self.sample.store(pixel(ctx, width - 6, height - 1 - 6), .monotonic);
        if (point != no_probe) {
            const x = point & 0xFFFF;
            const y = point >> 16;
            if (x < width and y < height) {
                self.probe.store(pixel(ctx, x, y) | probe_read, .monotonic);
            } else {
                // Off this frame (a resize under way): the next one answers,
                // unless the tests asked again meanwhile.
                _ = self.probe_point.cmpxchgStrong(no_probe, point, .monotonic, .monotonic);
            }
        }
        // A frame not yet taken is the UI thread's: a second request while
        // this one ran is answered by it, not by writing over it.
        if (self.frame_wanted.swap(false, .acquire) and !self.frame_ready.load(.acquire)) {
            if (whole(ctx, width, height)) |pixels| {
                self.frame = pixels;
                self.frame_width = width;
                self.frame_height = height;
                self.frame_ready.store(true, .release);
            }
        }
    }
};

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
