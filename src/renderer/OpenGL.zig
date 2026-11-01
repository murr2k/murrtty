//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const wgl = gl.wgl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
pub const Device = @import("opengl/Device.zig");

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

const log = std.log.scoped(.opengl);

/// On Windows we render with WGL directly into the surface's window
/// and present with SwapBuffers instead of exporting frames.
const is_windows = builtin.target.os.tag == .windows;

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *const Device,

egl_context: if (is_windows) void else *gl.egl.Context,

/// The WGL state for the surface's window (Windows only).
wgl_state: if (is_windows) Wgl else void,

const Wgl = struct {
    hwnd: wgl.HWND,
    hdc: wgl.HDC,
    context: wgl.HGLRC,

    /// A GPU driver reset (murrtty's roadmap 6.3). A robust context loses
    /// itself on one, which `reset_status` (glGetGraphicsResetStatusARB,
    /// loaded on the render thread) reports; the renderer then builds
    /// itself again in a new context (`contextLost`, `replaceContext`,
    /// `dropLostContext`). `lost` holds until a new one is made (`tries`
    /// so far, the last at `last_try`, in milliseconds since boot);
    /// `lost_context` is the old one until the renderer has released what
    /// it made there. There is always a context current: the lost one
    /// until another is made. `fake_reset`: the GUI tests' stand-in for a
    /// reset. `contexts`: contexts made, the first included.
    robust: bool = false,
    reset_status: ?*const fn () callconv(.winapi) u32 = null,
    lost: bool = false,
    tries: u32 = 0,
    last_try: u64 = 0,
    lost_context: ?wgl.HGLRC = null,
    fake_reset: std.atomic.Value(bool) = .init(false),
    contexts: std.atomic.Value(u32) = .init(1),

    /// The present pass's program and (empty) vertex array, made on the
    /// render thread at the first present.
    present: ?struct { program: gl.Program, vao: gl.VertexArray } = null,
    /// Whether the window's back buffer stores sRGB (GL_FRAMEBUFFER_SRGB
    /// then encodes on write), asked at the first present. A GPU driver's
    /// is; Mesa's llvmpipe (murrtty's software OpenGL, 6.3b) gives a
    /// linear one, which the present pass encodes for itself.
    backbuffer_srgb: ?bool = null,

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
    /// Frames presented, in every build: UI Automation's poll looks at the
    /// text again only after one (murrtty's roadmap 6.4).
    presented: std.atomic.Value(u32) = .init(0),
    /// And once asked (`frame_wanted`), the next present reads its whole
    /// back buffer into `frame` (BGRA rows, top first) and sets
    /// `frame_ready`; the UI thread takes the frame from there, freeing it
    /// before it asks again. Window captures read white where DWM isn't
    /// composing; this is what was drawn.
    frame_wanted: std.atomic.Value(bool) = .init(false),
    frame_ready: std.atomic.Value(bool) = .init(false),
    frame: []u8 = &.{},
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    /// Set by the apprt while its window is translucent (roadmap 4.1,
    /// `background-opacity` below 1): present the frame with its own alpha,
    /// for DWM to compose over what is behind the window, instead of over
    /// the opaque background.
    transparent: std.atomic.Value(bool) = .init(false),

    /// Rectangles drawn over the frame in the present pass, set by the UI
    /// thread (the dimming of an unfocused split pane) and read here.
    overlay_mutex: std.Io.Mutex = .init,
    overlay: Overlay = .{},
    overlay_program: ?struct { program: gl.Program, vao: gl.VertexArray } = null,

    pub const no_probe = std.math.maxInt(u32);
    pub const probe_read: u32 = 1 << 24;
};

/// Solid rectangles the Windows present pass draws over the frame, blending
/// in the stored (sRGB) values as GTK's CSS overlays do.
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

/// Replace the rectangles drawn over this surface's frames (Windows). They
/// show from the next frame, so a caller that needs them now forces one.
pub fn setOverlay(self: *OpenGL, rects: []const Overlay.Rect) void {
    if (comptime !is_windows) return;
    const state = &self.wgl_state;
    state.overlay_mutex.lockUncancelable(global.io());
    defer state.overlay_mutex.unlock(global.io());
    const n = @min(rects.len, Overlay.max);
    @memcpy(state.overlay.rects[0..n], rects[0..n]);
    state.overlay.len = n;
}

/// The terminal background, which the Windows present pass composites the
/// frame over.
pub const Background = struct {
    /// sRGB.
    rgb: [3]u8,
    /// `background-opacity`, which a translucent window shows where the
    /// frame doesn't reach yet.
    alpha: u8 = 255,
    /// Whether the frame holds linear colors (alpha-blending is linear).
    linear: bool,
};

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    if (comptime is_windows) return initWgl(alloc, device, opts);

    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Create our context. Contexts are surface-scoped because a
    // context can only be current on one thread at a time.
    const context = egl.Context.create(display, device.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .egl_context = context,
        .wgl_state = {},
    };
}

/// Create a WGL context for the apprt surface's window. The window's
/// pixel format is set here, on the main thread, before the render
/// thread ever makes the context current.
fn initWgl(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    if (comptime !@hasDecl(apprt.Surface, "nativeWindow")) {
        @compileError("the apprt must provide nativeWindow() for WGL rendering");
    }

    const hwnd: wgl.HWND = @ptrCast(opts.rt_surface.nativeWindow());
    const hdc = wgl.GetDC(hwnd) orelse return error.WglGetDCFailed;
    errdefer _ = wgl.ReleaseDC(hwnd, hdc);

    try device.wgl_ext.setPixelFormat(hdc);
    const created = try device.wgl_ext.createContext(
        hdc,
        MIN_VERSION_MAJOR,
        MIN_VERSION_MINOR,
        builtin.mode == .debug,
    );
    const context = created.handle;
    errdefer _ = wgl.wglDeleteContext(context);

    // Verify the context works, then release it so the render
    // thread can make it current.
    if (wgl.wglMakeCurrent(hdc, context) == 0) return error.WglMakeCurrentFailed;
    wgl.noteRenderer();
    _ = wgl.wglMakeCurrent(null, null);

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .egl_context = {},
        .wgl_state = .{
            .hwnd = hwnd,
            .hdc = hdc,
            .context = context,
            .robust = created.robust,
            // A pane opening in a translucent window presents so from its
            // first frame (the win32 runtime's; an embedding host has none).
            .transparent = .init(if (@hasDecl(apprt.Surface, "translucent")) opts.rt_surface.translucent() else false),
            .sampling = builtin.mode == .debug and
                wgl.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_WIN32_TEST_DUMP"), null, 0) != 0,
        },
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime is_windows) {
        _ = wgl.wglMakeCurrent(null, null);
        if (self.wgl_state.lost_context) |old| _ = wgl.wglDeleteContext(old);
        _ = wgl.wglDeleteContext(self.wgl_state.context);
        _ = wgl.ReleaseDC(self.wgl_state.hwnd, self.wgl_state.hdc);
        self.* = undefined;
        return;
    }

    self.device.display.releaseCurrent();
    self.egl_context.destroy(self.device.display) catch {};
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".attrs.@"callconv";

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;
    if (comptime is_windows) {
        const state = &self.wgl_state;
        if (wgl.wglMakeCurrent(state.hdc, state.context) == 0) {
            return error.WglMakeCurrentFailed;
        }
        try prepareContext(&wgl.getProcAddress);
        state.reset_status = resetStatusFn(state.robust);

        // DWM composites windowed GL output so there is no tearing
        // without vsync, and blocking in SwapBuffers would only add
        // input latency to the render thread.
        if (self.device.wgl_ext.swapInterval) |swapInterval| _ = swapInterval(0);
        return;
    }

    try self.device.display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// glGetGraphicsResetStatusARB for a robust context (glad's GL 4.3 has no
/// robustness), loaded with it current; null without.
fn resetStatusFn(robust: bool) ?*const fn () callconv(.winapi) u32 {
    if (!robust) return null;
    const p = wgl.getProcAddress("glGetGraphicsResetStatusARB") orelse
        wgl.getProcAddress("glGetGraphicsResetStatus") orelse return null;
    return @ptrCast(p);
}

/// murrtty: whether the context was lost to a GPU driver reset (a robust
/// one reports it), or a test faked one, and no new one was made yet. At
/// each frame's start, on the render thread, with the context current.
pub fn contextLost(self: *OpenGL) bool {
    if (comptime !is_windows) return false;
    const state = &self.wgl_state;
    if (state.lost) return true;
    const reset = if (state.fake_reset.swap(false, .acq_rel))
        true
    else if (state.reset_status) |status|
        status() != 0
    else
        false;
    if (!reset) return false;
    log.warn("the OpenGL context was lost (a graphics driver reset); making a new one", .{});
    state.lost = true;
    return true;
}

/// murrtty: make a new context on the same window (its pixel format
/// stays), current from now on, with GL loaded again from it. The lost one
/// is kept for `dropLostContext`: the renderer releases what it made there
/// first, here, where none of those names exist yet, so releasing deletes
/// nothing. False if no new one could be made, or the last try was under
/// a second ago: the lost one stays current (its calls do nothing), and
/// the renderer draws nothing until a later try.
pub fn replaceContext(self: *OpenGL) bool {
    if (comptime !is_windows) return true;
    const state = &self.wgl_state;
    const now = wgl.GetTickCount64();
    if (state.tries > 0 and now -% state.last_try < 1000) return false;
    state.last_try = now;
    state.tries +|= 1;
    const created = self.device.wgl_ext.createContext(
        state.hdc,
        MIN_VERSION_MAJOR,
        MIN_VERSION_MINOR,
        builtin.mode == .debug,
    ) catch |err| {
        if (state.tries == 1) log.err("no new OpenGL context after the reset err={}; trying again each second", .{err});
        return false;
    };
    if (wgl.wglMakeCurrent(state.hdc, created.handle) == 0) {
        _ = wgl.wglMakeCurrent(state.hdc, state.context);
        _ = wgl.wglDeleteContext(created.handle);
        return false;
    }
    prepareContext(&wgl.getProcAddress) catch |err| {
        log.err("could not load OpenGL in the new context err={}", .{err});
        _ = wgl.wglMakeCurrent(state.hdc, state.context);
        _ = wgl.wglDeleteContext(created.handle);
        prepareContext(&wgl.getProcAddress) catch {};
        return false;
    };
    // The present pass's programs go with the lost context.
    state.present = null;
    state.overlay_program = null;
    state.lost_context = state.context;
    state.context = created.handle;
    state.robust = created.robust;
    state.reset_status = resetStatusFn(created.robust);
    state.lost = false;
    state.tries = 0;
    if (self.device.wgl_ext.swapInterval) |swapInterval| _ = swapInterval(0);
    _ = state.contexts.fetchAdd(1, .monotonic);
    log.info("made a new OpenGL context after the reset", .{});
    return true;
}

/// murrtty: delete the context `replaceContext` replaced, and with it
/// everything made in it.
pub fn dropLostContext(self: *OpenGL) void {
    if (comptime !is_windows) return;
    const state = &self.wgl_state;
    if (state.lost_context) |old| _ = wgl.wglDeleteContext(old);
    state.lost_context = null;
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime is_windows) {
        if (self.wgl_state.present) |p| {
            p.program.destroy();
            p.vao.destroy();
            self.wgl_state.present = null;
        }
        if (self.wgl_state.overlay_program) |o| {
            o.program.destroy();
            o.vao.destroy();
            self.wgl_state.overlay_program = null;
        }
        _ = wgl.wglMakeCurrent(null, null);
        gl.glad.unload();
        return;
    }

    self.device.display.releaseCurrent();
    gl.glad.unload();
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(
    self: *OpenGL,
    target: Target,
    presentation_health: rendererpkg.Health,
    background: Background,
) !ExportedFrame {
    if (comptime is_windows) {
        try self.presentWgl(target, background);
        return .presented;
    }

    // We only export DMABUFs when the apprt can present them.
    // Otherwise, use CPU buffers.
    if (presentation_health == .healthy) {
        if (target.exportDmabuf(self.device.display, self.egl_context)) |dmabuf| {
            return .{ .dmabuf = dmabuf };
        } else |_| {
            log.warn("failed to export DMABUF, falling back to CPU presentation", .{});
        }
    }

    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
    } };
}

/// Draw the render target into the window's back buffer and swap.
///
/// The target holds premultiplied color with the background's alpha set
/// by `background-opacity`. An opaque window gets the frame composited over
/// the opaque terminal background (rather than copied onto black, which
/// darkened any opacity below 1), and whatever part of the window the
/// target doesn't cover yet during a resize gets the background too. A
/// translucent one (`transparent`) gets the frame's own alpha, and the
/// background at its opacity where the frame doesn't reach. The shader
/// works in the frame's own color space:
/// linear (the target is sRGB, so sampling decodes, and the window's back
/// buffer is sRGB with GL_FRAMEBUFFER_SRGB on, so storing encodes), or with
/// native alpha blending the sRGB values the shaders wrote.
fn presentWgl(self: *OpenGL, target: Target, background: Background) !void {
    const ctx = &gl.glad.context;
    const state = &self.wgl_state;
    const p = state.present orelse made: {
        const program = try gl.Program.createVF(present_vertex, present_fragment);
        errdefer program.destroy();
        const vao = try gl.VertexArray.create();
        state.present = .{ .program = program, .vao = vao };
        break :made state.present.?;
    };

    const frame_w: f32 = @floatFromInt(target.width);
    const frame_h: f32 = @floatFromInt(target.height);
    var client: wgl.RECT = .{};
    _ = wgl.GetClientRect(state.hwnd, &client);
    const win_w: gl.c.GLint = if (client.right > 0) client.right else @intCast(target.width);
    const win_h: gl.c.GLint = if (client.bottom > 0) client.bottom else @intCast(target.height);

    // The renderer reads the viewport back as the surface size.
    var viewport: [4]gl.c.GLint = undefined;
    ctx.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    defer ctx.Viewport.?(viewport[0], viewport[1], viewport[2], viewport[3]);

    ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
    ctx.Viewport.?(0, 0, win_w, win_h);
    ctx.Disable.?(gl.c.GL_BLEND);
    const srgb_target = state.backbuffer_srgb orelse srgb: {
        var encoding: gl.c.GLint = 0;
        ctx.GetFramebufferAttachmentParameteriv.?(gl.c.GL_FRAMEBUFFER, gl.c.GL_BACK_LEFT, gl.c.GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING, &encoding);
        // A driver refusing the question leaves an error for the next call
        // to find: take it here, and encode (exact either way when opaque).
        const refused = ctx.GetError.?() != gl.c.GL_NO_ERROR;
        const srgb = !refused and encoding == gl.c.GL_SRGB;
        if (!srgb) log.info("the window's back buffer is linear: the present pass encodes sRGB itself", .{});
        state.backbuffer_srgb = srgb;
        break :srgb srgb;
    };
    const pbind = try p.program.use();
    defer pbind.unbind();
    const vbind = try p.vao.bind();
    defer vbind.unbind();

    var bg: [4]f32 = .{ 0, 0, 0, 1 };
    for (background.rgb, bg[0..3]) |v, *out| {
        const f = @as(f32, @floatFromInt(v)) / 255.0;
        out.* = if (background.linear) srgbToLinear(f) else f;
    }
    try p.program.setUniform("background", @as(@Vector(4, f32), bg));
    // DWM takes premultiplied sRGB, which the shader works out itself.
    const transparent = state.transparent.load(.monotonic);
    try p.program.setUniform("transparent", transparent);
    try p.program.setUniform("background_alpha", @as(f32, @floatFromInt(background.alpha)) / 255.0);
    try p.program.setUniform("frame_linear", background.linear);
    // A linear frame into a linear back buffer: encode here what an sRGB
    // one would on write.
    const encode_out = background.linear and !srgb_target and !transparent;
    try p.program.setUniform("encode_out", encode_out);
    try p.program.setUniform("frame_size", @Vector(2, f32){ frame_w, frame_h });
    // The frame sits at the window's top-left corner.
    try p.program.setUniform("frame_offset_y", @as(f32, @floatFromInt(win_h)) - frame_h);

    try gl.Texture.active(0);
    ctx.BindSampler.?(0, 0);
    const tbind = try target.texture.bind(.@"2d");
    defer tbind.unbind();
    // With native blending the frame already holds sRGB values (the
    // shaders don't linearize), so they are stored as they are; encoding
    // them again showed every color too light.
    const srgb_off = !background.linear or transparent or encode_out;
    if (srgb_off) ctx.Disable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    defer if (srgb_off) ctx.Enable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    ctx.DrawArrays.?(gl.c.GL_TRIANGLES, 0, 3);

    var overlay: Overlay = undefined;
    {
        state.overlay_mutex.lockUncancelable(global.io());
        defer state.overlay_mutex.unlock(global.io());
        overlay = state.overlay;
    }
    if (overlay.len > 0) try drawOverlay(state, &overlay, win_w, win_h);

    if (comptime builtin.mode == .debug) if (state.sampling) {
        _ = state.frames.fetchAdd(1, .monotonic);
        state.sample.store(readPixel(@max(win_w - 6, 0), 6), .monotonic);
        const point = state.probe_point.load(.monotonic);
        if (point != Wgl.no_probe) {
            const x: gl.c.GLint = @intCast(point & 0xFFFF);
            const y: gl.c.GLint = @intCast(point >> 16);
            if (x < win_w and y < win_h) {
                state.probe.store(readPixel(x, win_h - 1 - y) | Wgl.probe_read, .monotonic);
            }
        }
        if (state.frame_wanted.swap(false, .acquire)) readFrame(state, win_w, win_h);
    };

    if (wgl.SwapBuffers(state.hdc) == 0) return error.WglSwapBuffersFailed;
    // Counted once on the window: murrtty's software OpenGL takes the
    // first as "it draws" (6.3b), UI Automation's poll as new text.
    _ = state.presented.fetchAdd(1, .monotonic);
}

/// Draw the overlay's rectangles onto the back buffer, blending in its
/// stored sRGB values (sRGB writes off), as GTK's CSS does.
fn drawOverlay(state: *Wgl, overlay: *const Overlay, win_w: gl.c.GLint, win_h: gl.c.GLint) !void {
    const ctx = &gl.glad.context;
    const o = state.overlay_program orelse made: {
        const program = try gl.Program.createVF(overlay_vertex, overlay_fragment);
        errdefer program.destroy();
        const vao = try gl.VertexArray.create();
        state.overlay_program = .{ .program = program, .vao = vao };
        break :made state.overlay_program.?;
    };
    const pbind = try o.program.use();
    defer pbind.unbind();
    const vbind = try o.vao.bind();
    defer vbind.unbind();

    ctx.Disable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    defer ctx.Enable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    // Premultiplied, as the render passes blend (they set this per pass).
    ctx.Enable.?(gl.c.GL_BLEND);
    defer ctx.Disable.?(gl.c.GL_BLEND);
    ctx.BlendFunc.?(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA);

    try o.program.setUniform("window_size", @Vector(2, f32){ @floatFromInt(win_w), @floatFromInt(win_h) });
    for (overlay.rects[0..overlay.len]) |r| {
        try o.program.setUniform("rect", @Vector(4, f32){
            @floatFromInt(r.x),
            @floatFromInt(r.y),
            @floatFromInt(r.width),
            @floatFromInt(r.height),
        });
        const a = r.color[3];
        try o.program.setUniform("color", @Vector(4, f32){ r.color[0] * a, r.color[1] * a, r.color[2] * a, a });
        ctx.DrawArrays.?(gl.c.GL_TRIANGLES, 0, 6);
    }
}

/// Two triangles covering `rect` (window pixels from the top left).
const overlay_vertex =
    \\#version 430 core
    \\uniform vec4 rect;
    \\uniform vec2 window_size;
    \\void main() {
    \\    int v = gl_VertexID;
    \\    vec2 corner = vec2((v == 1 || v == 2 || v == 4) ? 1.0 : 0.0,
    \\                       (v == 2 || v == 4 || v == 5) ? 1.0 : 0.0);
    \\    vec2 px = rect.xy + corner * rect.zw;
    \\    gl_Position = vec4(px.x / window_size.x * 2.0 - 1.0, 1.0 - px.y / window_size.y * 2.0, 0.0, 1.0);
    \\}
;

const overlay_fragment =
    \\#version 430 core
    \\uniform vec4 color;
    \\layout(location = 0) out vec4 out_color;
    \\void main() {
    \\    out_color = color;
    \\}
;

/// The whole back buffer into `state.frame` (BGRA, rows top first), for
/// the GUI tests; then `frame_ready`.
fn readFrame(state: *Wgl, win_w: gl.c.GLint, win_h: gl.c.GLint) void {
    if (win_w <= 0 or win_h <= 0) return;
    // A frame not yet taken is the UI thread's: a second request while
    // this one ran is answered by it, not by writing over it.
    if (state.frame_ready.load(.acquire)) return;
    const width: usize = @intCast(win_w);
    const height: usize = @intCast(win_h);
    const pixels = std.heap.page_allocator.alloc(u8, width * height * 4) catch return;
    gl.glad.context.ReadPixels.?(0, 0, win_w, win_h, gl.c.GL_BGRA, gl.c.GL_UNSIGNED_BYTE, pixels.ptr);
    // GL's rows run bottom up.
    const stride = width * 4;
    var top: usize = 0;
    var bottom: usize = height - 1;
    while (top < bottom) : ({
        top += 1;
        bottom -= 1;
    }) {
        const a = pixels[top * stride ..][0..stride];
        const b = pixels[bottom * stride ..][0..stride];
        for (a, b) |*x, *y| std.mem.swap(u8, x, y);
    }
    state.frame = pixels;
    state.frame_width = @intCast(width);
    state.frame_height = @intCast(height);
    state.frame_ready.store(true, .release);
}

/// The back buffer's pixel at GL coordinates (origin bottom left) as
/// 0x00RRGGBB, as stored.
fn readPixel(x: gl.c.GLint, y: gl.c.GLint) u32 {
    var px: [4]u8 = undefined;
    gl.glad.context.ReadPixels.?(x, y, 1, 1, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, &px);
    return @as(u32, px[0]) << 16 | @as(u32, px[1]) << 8 | px[2];
}

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// A triangle that covers the viewport.
const present_vertex =
    \\#version 430 core
    \\void main() {
    \\    vec2 pos = vec2(gl_VertexID == 2 ? 3.0 : -1.0, gl_VertexID == 1 ? 3.0 : -1.0);
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\}
;

/// The frame (premultiplied) over the opaque background, or with its own
/// alpha.
const present_fragment =
    \\#version 430 core
    \\layout(binding = 0) uniform sampler2D frame;
    \\uniform vec4 background;
    \\uniform bool transparent;
    \\uniform float background_alpha;
    \\uniform bool frame_linear;
    \\uniform bool encode_out;
    \\uniform vec2 frame_size;
    \\uniform float frame_offset_y;
    \\layout(location = 0) out vec4 out_color;
    \\vec3 encode(vec3 c) {
    \\    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
    \\}
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy) - ivec2(0, int(frame_offset_y));
    \\    ivec2 size = ivec2(frame_size);
    \\    // Beyond the frame (a resize), translucent, the background at its
    \\    // opacity.
    \\    vec4 color = transparent ? vec4(background.rgb, 1.0) * background_alpha : vec4(0.0);
    \\    if (p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y) {
    \\        color = texelFetch(frame, p, 0);
    \\    }
    \\    if (transparent) {
    \\        // Premultiplied sRGB, written as is (sRGB writes off).
    \\        vec3 straight = color.a > 0.0 ? color.rgb / color.a : vec3(0.0);
    \\        if (frame_linear) straight = encode(straight);
    \\        out_color = vec4(straight * color.a, color.a);
    \\    } else {
    \\        out_color = color + background * (1.0 - color.a);
    \\        // A linear back buffer (llvmpipe's): sRGB writes would do this.
    \\        if (encode_out) out_color.rgb = encode(clamp(out_color.rgb, 0.0, 1.0));
    \\    }
    \\}
;

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = union(enum) {
    dmabuf: if (is_windows) void else Dmabuf,
    memory: Memory,

    /// The frame was already presented directly to the apprt's
    /// window (WGL) and there is nothing left to composite.
    presented,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| if (comptime !is_windows) v.deinit(),
            .memory => |v| v.deinit(),
            .presented => {},
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
