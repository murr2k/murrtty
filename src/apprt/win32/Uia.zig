//! UI Automation for a pane (roadmap 6.4): the terminal as a text control
//! that screen readers (Narrator, NVDA, JAWS) and magnifiers read through
//! the Text pattern (ITextProvider2 and ITextRangeProvider), over
//! uia_text's positions; Windows Terminal's UiaTextRange is the model. A
//! pane's provider is made when a client first asks (WM_GETOBJECT) and
//! lives while UI Automation holds it; the pane detaches it as it closes,
//! and its calls then fail with UIA_E_ELEMENTNOTAVAILABLE.
//!
//! Calls come on the UI thread (a server-side provider without COM
//! threading). They take the terminal's lock with a bounded wait: the
//! render thread holds it for moments every frame, and a call arriving
//! while the UI thread itself holds it (a sent message, inside a core
//! callback that waits on another program) fails rather than deadlocks.
//!
//! Events: a selection change (the core's selection_changed), and, polled
//! while clients listen (`tick`), the text changing (TextChanged) and the
//! cursor moving (TextSelectionChanged, which Narrator follows as the
//! caret).
const Uia = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const Surface = @import("Surface.zig");
const uia_text = @import("uia_text.zig");
const terminal = @import("../../terminal/main.zig");
const global = @import("../../global.zig");

const Pos = uia_text.Pos;
const View = uia_text.View;
const Unit = uia_text.Unit;

const log = std.log.scoped(.win32_uia);

const GUID = c.GUID;
const HRESULT = c.HRESULT;
const BOOL = c.BOOL;

fn hr(v: u32) HRESULT {
    return @bitCast(v);
}
const S_OK: HRESULT = 0;
const E_FAIL = hr(0x80004005);
const E_NOINTERFACE = hr(0x80004002);
const E_INVALIDARG = hr(0x80070057);
const E_OUTOFMEMORY = hr(0x8007000E);
const E_POINTER = hr(0x80004003);
const UIA_E_ELEMENTNOTAVAILABLE = hr(0x80040201);
const UIA_E_INVALIDOPERATION = hr(0x80131509);

const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");
const IID_IRawElementProviderSimple = GUID.parse("{d6dd68d1-86fd-4332-8666-9abedea2d24c}");
const IID_ITextProvider = GUID.parse("{3589c92c-63f3-4367-99bb-ada653b77cf2}");
const IID_ITextProvider2 = GUID.parse("{0dc5e6ed-3e16-4bf1-8f9a-a979878bc195}");
const IID_ITextRangeProvider = GUID.parse("{5347ad7b-c355-46f8-aff5-909033582f63}");
const IID_IRawElementProviderFragment = GUID.parse("{f7063da8-8359-439c-9297-bbc5299a7d87}");
const IID_IRawElementProviderFragmentRoot = GUID.parse("{620ce2a5-ab8f-40a9-86cb-de3c75599b58}");

pub const UiaRootObjectId: i32 = -25;
const OBJID_CLIENT: i32 = -4;
const OBJID_WINDOW: i32 = 0;
const ProviderOptions_ServerSideProvider = 0x1;
const UIA_TextPatternId = 10014;
const UIA_TextPattern2Id = 10024;
const UIA_Text_TextSelectionChangedEventId = 20014;
const UIA_Text_TextChangedEventId = 20015;
const UIA_ControlTypePropertyId = 30003;
const UIA_LocalizedControlTypePropertyId = 30004;
const UIA_NamePropertyId = 30005;
const UIA_HasKeyboardFocusPropertyId = 30008;
const UIA_IsKeyboardFocusablePropertyId = 30009;
const UIA_AutomationIdPropertyId = 30011;
const UIA_IsControlElementPropertyId = 30016;
const UIA_IsContentElementPropertyId = 30017;
const UIA_IsTextPatternAvailablePropertyId = 30040;
const UIA_ProviderDescriptionPropertyId = 30107;
const UIA_IsTextPattern2AvailablePropertyId = 30119;
const UIA_TextControlTypeId = 50020;
const UIA_IsReadOnlyAttributeId = 40015;
const SupportedTextSelection_Single = 1;

const VT_EMPTY = 0;
const VT_I4 = 3;
const VT_R8 = 5;
const VT_BSTR = 8;
const VT_BOOL = 11;
const VT_UNKNOWN = 13;
const VARIANT_TRUE: i16 = -1;
const VARIANT_FALSE: i16 = 0;

pub const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    val: extern union { i4: i32, b: i16, bstr: ?[*:0]u16, punk: ?*anyopaque, r8: f64, raw: [2]u64 } = .{ .raw = .{ 0, 0 } },
};

const UiaPoint = extern struct { x: f64, y: f64 };
const SAFEARRAY = opaque {};
const BSTR = [*:0]u16;

extern "uiautomationcore" fn UiaReturnRawElementProvider(c.HWND, c.WPARAM, c.LPARAM, ?*anyopaque) callconv(.winapi) c.LRESULT;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(c.HWND, *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaRaiseAutomationEvent(*anyopaque, c_int) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) BOOL;
extern "uiautomationcore" fn UiaDisconnectProvider(*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaGetReservedNotSupportedValue(*?*anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lbound: i32, count: u32) callconv(.winapi) ?*SAFEARRAY;
extern "oleaut32" fn SafeArrayPutElement(*SAFEARRAY, *const i32, *const anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayDestroy(*SAFEARRAY) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(?[*]const u16, u32) callconv(.winapi) ?BSTR;
extern "oleaut32" fn SysStringLen(?[*:0]const u16) callconv(.winapi) u32;

//---------------------------------------------------------------
// The pane's provider

/// A pane's element: IRawElementProviderSimple at the object's start,
/// then ITextProvider2, and IRawElementProviderFragment and
/// IRawElementProviderFragmentRoot (the element is a fragment root of one,
/// hosted by the pane's window, as UI Automation identifies an event's
/// source by its fragment), one reference count for all.
pub const Provider = struct {
    simple: *const SimpleVtbl = &simple_vtbl,
    text: *const TextVtbl = &text_vtbl,
    fragment: *const FragmentVtbl = &fragment_vtbl,
    root: *const RootVtbl = &root_vtbl,
    refs: std.atomic.Value(u32) = .init(1),
    alloc: Allocator,
    /// The pane, until it closes.
    surface: ?*Surface,
    hwnd: c.HWND,
    /// What the last poll saw (`tick`): a sign of the text in view and the
    /// cursor, and the frames presented by then, to tell UI Automation's
    /// listeners what changed; and a selection change to tell of.
    seen_text: u64 = 0,
    seen_cursor: Pos = .{},
    seen_presents: u32 = 0,
    seen: bool = false,
    selection_pending: bool = false,
    /// The poll's timer runs (once UI Automation's root was asked for).
    polling: bool = false,

    comptime {
        std.debug.assert(@offsetOf(Provider, "simple") == 0);
    }

    fn fromSimple(p: *anyopaque) *Provider {
        return @ptrCast(@alignCast(p));
    }

    fn fromText(p: *anyopaque) *Provider {
        const field: *const *const TextVtbl = @ptrCast(@alignCast(p));
        return @alignCast(@fieldParentPtr("text", @constCast(field)));
    }

    fn fromFragment(p: *anyopaque) *Provider {
        const field: *const *const FragmentVtbl = @ptrCast(@alignCast(p));
        return @alignCast(@fieldParentPtr("fragment", @constCast(field)));
    }

    fn fromRoot(p: *anyopaque) *Provider {
        const field: *const *const RootVtbl = @ptrCast(@alignCast(p));
        return @alignCast(@fieldParentPtr("root", @constCast(field)));
    }

    fn fragmentPtr(self: *Provider) *anyopaque {
        return @ptrCast(&self.fragment);
    }

    fn rootPtr(self: *Provider) *anyopaque {
        return @ptrCast(&self.root);
    }

    fn simplePtr(self: *Provider) *anyopaque {
        return @ptrCast(&self.simple);
    }

    fn textPtr(self: *Provider) *anyopaque {
        return @ptrCast(&self.text);
    }

    fn addRef(self: *Provider) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *Provider) u32 {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) self.alloc.destroy(self);
        return left;
    }

    fn queryInterface(self: *Provider, iid: *const GUID, out: *?*anyopaque) HRESULT {
        if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IRawElementProviderSimple)) {
            out.* = self.simplePtr();
        } else if (std.meta.eql(iid.*, IID_ITextProvider) or std.meta.eql(iid.*, IID_ITextProvider2)) {
            out.* = self.textPtr();
        } else if (std.meta.eql(iid.*, IID_IRawElementProviderFragment)) {
            out.* = self.fragmentPtr();
        } else if (std.meta.eql(iid.*, IID_IRawElementProviderFragmentRoot)) {
            out.* = self.rootPtr();
        } else {
            out.* = null;
            return E_NOINTERFACE;
        }
        _ = self.addRef();
        return S_OK;
    }
};

/// The terminal's screen, locked for one call (`unlock` after).
const Locked = struct {
    surface: *Surface,
    view: View,
    /// Taken with demand signaled (`lock`'s wait): released so.
    demanded: bool,

    fn unlock(self: Locked) void {
        const state = &self.surface.core_surface.renderer_state;
        if (self.demanded) state.unlockDemand(global.io()) else state.mutex.unlock(global.io());
    }
};

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
extern "kernel32" fn SwitchToThread() callconv(.winapi) BOOL;

/// The pane's terminal, its lock taken: at once, or within 50 ms, with the
/// IO thread's busy loop asked to let go meanwhile (the core's demand
/// signal). This thread may hold the lock itself (a sent message inside a
/// core callback): then it gives up rather than deadlocks. Gone for a
/// closed pane, or one parked for undo.
fn lock(provider: *Provider) error{ Gone, Busy }!Locked {
    const s = try live(provider);
    const state = &s.core_surface.renderer_state;
    var demanded = false;
    if (!state.mutex.tryLock()) {
        var freq: i64 = 1;
        var now: i64 = 0;
        _ = QueryPerformanceFrequency(&freq);
        _ = QueryPerformanceCounter(&now);
        const deadline = now + @divTrunc(freq, 20);
        _ = state.demand.fetchAdd(1, .monotonic);
        defer _ = state.demand.fetchSub(1, .monotonic);
        while (!state.mutex.tryLock()) {
            _ = QueryPerformanceCounter(&now);
            if (now > deadline) return error.Busy;
            _ = SwitchToThread();
        }
        demanded = true;
    }
    return .{ .surface = s, .view = View.init(state.terminal.screens.active), .demanded = demanded };
}

/// The lock if it is free now, for the poll.
fn lockNow(provider: *Provider) ?Locked {
    const s = live(provider) catch return null;
    const state = &s.core_surface.renderer_state;
    if (!state.mutex.tryLock()) return null;
    return .{ .surface = s, .view = View.init(state.terminal.screens.active), .demanded = false };
}

/// The pane, unless it closed or is parked for undo (its window lives on,
/// never shown, in the shelf).
fn live(provider: *Provider) error{Gone}!*Surface {
    const s = provider.surface orelse return error.Gone;
    if (!s.core_initialized or s.parked()) return error.Gone;
    return s;
}

fn lockErr(err: error{ Gone, Busy }) HRESULT {
    return switch (err) {
        error.Gone => UIA_E_ELEMENTNOTAVAILABLE,
        error.Busy => E_FAIL,
    };
}

/// The pane's answer to WM_GETOBJECT: UI Automation's root (lparam
/// UiaRootObjectId), the keys it sends to resolve each event raised (ids
/// above 0: answered 0, no event ever reached a client, though raising it
/// succeeded) and MSAA's client object (UI Automation's bridge then
/// answers for the pane, as Microsoft's samples do), all through
/// UiaReturnRawElementProvider, which tells them apart. Null for MSAA's
/// other objects, its window object (0) included.
pub fn getObject(surface: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const id: i32 = @truncate(lparam);
    if (id == OBJID_WINDOW or (id < 0 and id != UiaRootObjectId and id != OBJID_CLIENT)) return null;
    const provider = surface.uia orelse made: {
        // An event's key only follows a raise, which needs a provider.
        if (id > 0) return null;
        const p = surface.app.core_app.alloc.create(Provider) catch return null;
        p.* = .{ .alloc = surface.app.core_app.alloc, .surface = surface, .hwnd = surface.hwnd };
        surface.uia = p;
        break :made p;
    };
    // The poll for changes, once a UI Automation client (not just MSAA's
    // bridge) asked.
    if (id == UiaRootObjectId and !provider.polling) {
        provider.polling = c.SetTimer(surface.hwnd, timer_id, poll_ms, null) != 0;
    }
    return UiaReturnRawElementProvider(surface.hwnd, wparam, lparam, provider.simplePtr());
}

pub const timer_id = 0x5641;
const poll_ms = 150;

/// The pane closes: UI Automation drops its references, and calls on
/// whatever it still holds fail.
pub fn detach(surface: *Surface) void {
    const provider = surface.uia orelse return;
    _ = c.KillTimer(surface.hwnd, timer_id);
    provider.surface = null;
    _ = UiaDisconnectProvider(provider.simplePtr());
    _ = UiaReturnRawElementProvider(surface.hwnd, 0, 0, null);
    surface.uia = null;
    _ = provider.release();
}

/// The core's selection changed (with the terminal's lock held, and for
/// every cell a drag crosses): the poll tells listeners, once.
pub fn selectionChanged(surface: *Surface) void {
    const provider = surface.uia orelse return;
    provider.selection_pending = true;
}

/// The poll (the pane's timer): tell listening clients the text in view
/// changed, or the cursor moved, or the selection changed, for the pane
/// with the keyboard (screen readers follow it), and only after a frame
/// was presented since the last look (or for a selection).
pub fn tick(surface: *Surface) void {
    const provider = surface.uia orelse return;
    if (UiaClientsAreListening() == 0 or !surface.has_focus or surface.parked()) {
        provider.seen = false;
        provider.selection_pending = false;
        return;
    }
    const presents = if (surface.core_initialized) surface.core_surface.renderer.api.present_state.presented.load(.monotonic) else 0;
    if (provider.seen and presents == provider.seen_presents and !provider.selection_pending) return;
    var locked = lockNow(provider) orelse return;
    const sign = viewSign(&locked.view);
    const cursor = locked.view.cursor;
    locked.unlock();
    const first = !provider.seen;
    const text_changed = !first and sign != provider.seen_text;
    const cursor_moved = !first and !cursor.eql(provider.seen_cursor);
    const selection = provider.selection_pending;
    provider.seen = true;
    provider.seen_text = sign;
    provider.seen_cursor = cursor;
    provider.seen_presents = presents;
    provider.selection_pending = false;
    // Raised with no lock held: UI Automation asks the window for the
    // event's source (WM_GETOBJECT) during the call.
    if (text_changed) _ = UiaRaiseAutomationEvent(provider.simplePtr(), UIA_Text_TextChangedEventId);
    if (cursor_moved or selection) _ = UiaRaiseAutomationEvent(provider.simplePtr(), UIA_Text_TextSelectionChangedEventId);
}

/// A sign of the text in view and where it is in the scrollback.
fn viewSign(view: *View) u64 {
    var h = std.hash.Wyhash.init(view.viewport_top);
    var y = view.viewport_top;
    var p = view.pin(.{ .y = y }) orelse return h.final();
    while (y < view.viewport_top + view.rows and y < view.total) : (y += 1) {
        if (y > view.viewport_top) p = p.down(1) orelse break;
        for (p.cells(.all)) |cell| {
            const cp: u32 = if (cell.hasText()) cell.codepoint() else 0;
            h.update(std.mem.asBytes(&cp));
        }
    }
    return h.final();
}

//---------------------------------------------------------------
// IRawElementProviderSimple

const SimpleVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    get_ProviderOptions: *const fn (*anyopaque, *c_int) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (*anyopaque, c_int, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (*anyopaque, c_int, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const simple_vtbl: SimpleVtbl = .{
    .QueryInterface = &simpleQuery,
    .AddRef = &simpleAddRef,
    .Release = &simpleRelease,
    .get_ProviderOptions = &providerOptions,
    .GetPatternProvider = &patternProvider,
    .GetPropertyValue = &propertyValue,
    .get_HostRawElementProvider = &hostProvider,
};

fn simpleQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return Provider.fromSimple(this).queryInterface(iid, out);
}

fn simpleAddRef(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromSimple(this).addRef();
}

fn simpleRelease(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromSimple(this).release();
}

fn providerOptions(_: *anyopaque, out: *c_int) callconv(.winapi) HRESULT {
    out.* = ProviderOptions_ServerSideProvider;
    return S_OK;
}

fn patternProvider(this: *anyopaque, pattern: c_int, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromSimple(this);
    out.* = null;
    _ = live(self) catch return UIA_E_ELEMENTNOTAVAILABLE;
    if (pattern == UIA_TextPatternId or pattern == UIA_TextPattern2Id) {
        out.* = self.textPtr();
        _ = self.addRef();
    }
    return S_OK;
}

fn bstrVariant(out: *VARIANT, text: []const u8) HRESULT {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..@min(buf.len, std.unicode.calcUtf16LeLen(text) catch 0)], text[0..@min(text.len, buf.len)]) catch 0;
    const bstr = SysAllocStringLen(&buf, @intCast(n)) orelse return E_OUTOFMEMORY;
    out.* = .{ .vt = VT_BSTR, .val = .{ .bstr = bstr } };
    return S_OK;
}

fn boolVariant(out: *VARIANT, v: bool) void {
    out.* = .{ .vt = VT_BOOL, .val = .{ .b = if (v) VARIANT_TRUE else VARIANT_FALSE } };
}

fn propertyValue(this: *anyopaque, property: c_int, out: *VARIANT) callconv(.winapi) HRESULT {
    const self = Provider.fromSimple(this);
    out.* = .{};
    const s = self.surface orelse return UIA_E_ELEMENTNOTAVAILABLE;
    switch (property) {
        UIA_ControlTypePropertyId => out.* = .{ .vt = VT_I4, .val = .{ .i4 = UIA_TextControlTypeId } },
        UIA_LocalizedControlTypePropertyId => return bstrVariant(out, "terminal"),
        // The pane's title, as its tab shows it (the user's name first).
        UIA_NamePropertyId => return bstrVariant(out, s.title_override orelse s.getTitle() orelse "Terminal"),
        UIA_AutomationIdPropertyId => return bstrVariant(out, "Terminal"),
        UIA_ProviderDescriptionPropertyId => return bstrVariant(out, "murrtty"),
        UIA_HasKeyboardFocusPropertyId => boolVariant(out, c.GetFocus() == self.hwnd),
        UIA_IsKeyboardFocusablePropertyId,
        UIA_IsControlElementPropertyId,
        UIA_IsContentElementPropertyId,
        UIA_IsTextPatternAvailablePropertyId,
        UIA_IsTextPattern2AvailablePropertyId,
        => boolVariant(out, true),
        else => {},
    }
    return S_OK;
}

fn hostProvider(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromSimple(this);
    out.* = null;
    // Once detached, the window may be gone and its handle reused.
    if (self.surface == null) return UIA_E_ELEMENTNOTAVAILABLE;
    return UiaHostProviderFromHwnd(self.hwnd, out);
}

//---------------------------------------------------------------
// IRawElementProviderFragment and IRawElementProviderFragmentRoot: one
// element, the root, its window the host.

const UiaRect = extern struct { left: f64, top: f64, width: f64, height: f64 };

const FragmentVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Navigate: *const fn (*anyopaque, c_int, *?*anyopaque) callconv(.winapi) HRESULT,
    GetRuntimeId: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    get_BoundingRectangle: *const fn (*anyopaque, *UiaRect) callconv(.winapi) HRESULT,
    GetEmbeddedFragmentRoots: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    SetFocus: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    get_FragmentRoot: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const fragment_vtbl: FragmentVtbl = .{
    .QueryInterface = &fragmentQuery,
    .AddRef = &fragmentAddRef,
    .Release = &fragmentRelease,
    .Navigate = &fragmentNavigate,
    .GetRuntimeId = &fragmentRuntimeId,
    .get_BoundingRectangle = &fragmentBounds,
    .GetEmbeddedFragmentRoots = &fragmentEmbedded,
    .SetFocus = &fragmentFocus,
    .get_FragmentRoot = &fragmentRoot,
};

fn fragmentQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return Provider.fromFragment(this).queryInterface(iid, out);
}

fn fragmentAddRef(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromFragment(this).addRef();
}

fn fragmentRelease(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromFragment(this).release();
}

fn fragmentNavigate(_: *anyopaque, _: c_int, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // No parent, siblings or children within the fragment: the window's
    // host provider answers for its place in the tree.
    out.* = null;
    return S_OK;
}

fn fragmentRuntimeId(_: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    // A fragment root hosted by a window: the host gives the runtime id.
    out.* = null;
    return S_OK;
}

fn fragmentBounds(this: *anyopaque, out: *UiaRect) callconv(.winapi) HRESULT {
    const self = Provider.fromFragment(this);
    out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
    if (self.surface == null) return UIA_E_ELEMENTNOTAVAILABLE;
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.ClientToScreen(self.hwnd, &origin);
    out.* = .{
        .left = @floatFromInt(origin.x),
        .top = @floatFromInt(origin.y),
        .width = @floatFromInt(r.right - r.left),
        .height = @floatFromInt(r.bottom - r.top),
    };
    return S_OK;
}

fn fragmentEmbedded(_: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    out.* = null;
    return S_OK;
}

fn fragmentFocus(this: *anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromFragment(this);
    const s = live(self) catch return UIA_E_ELEMENTNOTAVAILABLE;
    // Never off a dialog that is open (one at a time, app-wide).
    if (s.app.modal_depth > 0) return UIA_E_INVALIDOPERATION;
    _ = c.SetFocus(self.hwnd);
    return S_OK;
}

fn fragmentRoot(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromFragment(this);
    out.* = self.rootPtr();
    _ = self.addRef();
    return S_OK;
}

const RootVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    ElementProviderFromPoint: *const fn (*anyopaque, f64, f64, *?*anyopaque) callconv(.winapi) HRESULT,
    GetFocus: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const root_vtbl: RootVtbl = .{
    .QueryInterface = &rootQuery,
    .AddRef = &rootAddRef,
    .Release = &rootRelease,
    .ElementProviderFromPoint = &rootFromPoint,
    .GetFocus = &rootFocus,
};

fn rootQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return Provider.fromRoot(this).queryInterface(iid, out);
}

fn rootAddRef(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromRoot(this).addRef();
}

fn rootRelease(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromRoot(this).release();
}

fn rootFromPoint(this: *anyopaque, _: f64, _: f64, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // The only element: itself, as its fragment.
    const self = Provider.fromRoot(this);
    out.* = self.fragmentPtr();
    _ = self.addRef();
    return S_OK;
}

fn rootFocus(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // No element within it has the keyboard apart from itself.
    _ = this;
    out.* = null;
    return S_OK;
}

//---------------------------------------------------------------
// ITextProvider2

const TextVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSelection: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    GetVisibleRanges: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    RangeFromChild: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    RangeFromPoint: *const fn (*anyopaque, UiaPoint, *?*anyopaque) callconv(.winapi) HRESULT,
    get_DocumentRange: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    get_SupportedTextSelection: *const fn (*anyopaque, *c_int) callconv(.winapi) HRESULT,
    RangeFromAnnotation: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetCaretRange: *const fn (*anyopaque, *BOOL, *?*anyopaque) callconv(.winapi) HRESULT,
};

const text_vtbl: TextVtbl = .{
    .QueryInterface = &textQuery,
    .AddRef = &textAddRef,
    .Release = &textRelease,
    .GetSelection = &getSelection,
    .GetVisibleRanges = &getVisibleRanges,
    .RangeFromChild = &rangeFromChild,
    .RangeFromPoint = &rangeFromPoint,
    .get_DocumentRange = &documentRange,
    .get_SupportedTextSelection = &supportedSelection,
    .RangeFromAnnotation = &rangeFromChild,
    .GetCaretRange = &caretRange,
};

fn textQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return Provider.fromText(this).queryInterface(iid, out);
}

fn textAddRef(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromText(this).addRef();
}

fn textRelease(this: *anyopaque) callconv(.winapi) u32 {
    return Provider.fromText(this).release();
}

/// A SAFEARRAY of one range (VT_UNKNOWN), which takes its reference.
fn oneRange(range: *Range) ?*SAFEARRAY {
    defer _ = range.release();
    const sa = SafeArrayCreateVector(VT_UNKNOWN, 0, 1) orelse return null;
    const index: i32 = 0;
    if (SafeArrayPutElement(sa, &index, @ptrCast(range)) < 0) {
        _ = SafeArrayDestroy(sa);
        return null;
    }
    return sa;
}

/// The selection, as one range: the terminal's, or an empty range at the
/// cursor (UI Automation's caret) when nothing is selected.
fn selectionRange(view: *View) struct { start: Pos, end: Pos } {
    const screen = view.screen;
    if (screen.selection) |sel| {
        const tl = view.posOf(sel.topLeft(screen));
        const br = view.posOf(sel.bottomRight(screen));
        if (tl != null and br != null) return .{ .start = view.clamp(tl.?), .end = view.nextChar(br.?) };
    }
    const cursor = view.clamp(view.cursor);
    return .{ .start = cursor, .end = cursor };
}

fn getSelection(this: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    const self = Provider.fromText(this);
    out.* = null;
    var locked = lock(self) catch |err| return lockErr(err);
    const sel = selectionRange(&locked.view);
    locked.unlock();
    const range = Range.create(self, sel.start, sel.end) orelse return E_OUTOFMEMORY;
    out.* = oneRange(range) orelse return E_OUTOFMEMORY;
    return S_OK;
}

fn getVisibleRanges(this: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    const self = Provider.fromText(this);
    out.* = null;
    var locked = lock(self) catch |err| return lockErr(err);
    var view = locked.view;
    const start = view.clamp(.{ .y = view.viewport_top });
    const end = view.clamp(.{ .y = view.viewport_top + view.rows });
    locked.unlock();
    const range = Range.create(self, start, end) orelse return E_OUTOFMEMORY;
    out.* = oneRange(range) orelse return E_OUTOFMEMORY;
    return S_OK;
}

fn rangeFromChild(_: *anyopaque, _: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // The terminal has no child elements (nor annotations).
    out.* = null;
    return E_INVALIDARG;
}

fn rangeFromPoint(this: *anyopaque, point: UiaPoint, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromText(this);
    out.* = null;
    var locked = lock(self) catch |err| return lockErr(err);
    var view = locked.view;
    const size = locked.surface.core_surface.size;
    locked.unlock();
    // A client's doubles, kept to what a point can be (NaN as 0).
    const fit = struct {
        fn fit(v: f64) c_long {
            if (std.math.isNan(v)) return 0;
            return @intFromFloat(std.math.clamp(v, -1e9, 1e9));
        }
    }.fit;
    var pt: c.POINT = .{ .x = fit(point.x), .y = fit(point.y) };
    _ = c.ScreenToClient(self.hwnd, &pt);
    const cw: i64 = @max(1, size.cell.width);
    const ch: i64 = @max(1, size.cell.height);
    const col = std.math.clamp(@divFloor(@as(i64, pt.x) - size.padding.left, cw), 0, @as(i64, view.cols) - 1);
    const row = std.math.clamp(@divFloor(@as(i64, pt.y) - size.padding.top, ch), 0, @as(i64, view.rows) - 1);
    const pos = view.clamp(.{ .y = view.viewport_top + @as(u32, @intCast(row)), .x = @intCast(col) });
    const range = Range.create(self, pos, pos) orelse return E_OUTOFMEMORY;
    out.* = @ptrCast(range);
    return S_OK;
}

fn documentRange(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromText(this);
    out.* = null;
    var locked = lock(self) catch |err| return lockErr(err);
    const end = locked.view.end;
    locked.unlock();
    const range = Range.create(self, .{}, end) orelse return E_OUTOFMEMORY;
    out.* = @ptrCast(range);
    return S_OK;
}

fn supportedSelection(_: *anyopaque, out: *c_int) callconv(.winapi) HRESULT {
    out.* = SupportedTextSelection_Single;
    return S_OK;
}

fn caretRange(this: *anyopaque, active: *BOOL, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Provider.fromText(this);
    out.* = null;
    active.* = @intFromBool(c.GetFocus() == self.hwnd);
    var locked = lock(self) catch |err| return lockErr(err);
    const cursor = locked.view.clamp(locked.view.cursor);
    locked.unlock();
    const range = Range.create(self, cursor, cursor) orelse return E_OUTOFMEMORY;
    out.* = @ptrCast(range);
    return S_OK;
}

//---------------------------------------------------------------
// ITextRangeProvider

const Range = struct {
    vtbl: *const RangeVtbl = &range_vtbl,
    refs: std.atomic.Value(u32) = .init(1),
    provider: *Provider,
    start: Pos,
    end: Pos,

    comptime {
        std.debug.assert(@offsetOf(Range, "vtbl") == 0);
    }

    fn create(provider: *Provider, start: Pos, end: Pos) ?*Range {
        const self = provider.alloc.create(Range) catch return null;
        _ = provider.addRef();
        self.* = .{ .provider = provider, .start = start.min(end), .end = start.max(end) };
        return self;
    }

    fn from(p: *anyopaque) *Range {
        return @ptrCast(@alignCast(p));
    }

    /// Another range of this provider, or null for something else.
    fn other(self: *Range, p: ?*anyopaque) ?*Range {
        const r: *Range = @ptrCast(@alignCast(p orelse return null));
        if (r.vtbl != &range_vtbl or r.provider != self.provider) return null;
        return r;
    }

    fn release(self: *Range) u32 {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) {
            const provider = self.provider;
            provider.alloc.destroy(self);
            _ = provider.release();
        }
        return left;
    }

    fn endpoint(self: *const Range, which: c_int) Pos {
        return if (which == 0) self.start else self.end;
    }

    /// Set an endpoint; the other follows where it would cross it.
    fn setEndpoint(self: *Range, which: c_int, pos: Pos) void {
        if (which == 0) {
            self.start = pos;
            if (self.end.lessThan(pos)) self.end = pos;
        } else {
            self.end = pos;
            if (pos.lessThan(self.start)) self.start = pos;
        }
    }
};

const RangeVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Clone: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    Compare: *const fn (*anyopaque, ?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
    CompareEndpoints: *const fn (*anyopaque, c_int, ?*anyopaque, c_int, *c_int) callconv(.winapi) HRESULT,
    ExpandToEnclosingUnit: *const fn (*anyopaque, c_int) callconv(.winapi) HRESULT,
    FindAttribute: *const fn (*anyopaque, c_int, VARIANT, BOOL, *?*anyopaque) callconv(.winapi) HRESULT,
    FindText: *const fn (*anyopaque, ?BSTR, BOOL, BOOL, *?*anyopaque) callconv(.winapi) HRESULT,
    GetAttributeValue: *const fn (*anyopaque, c_int, *VARIANT) callconv(.winapi) HRESULT,
    GetBoundingRectangles: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    GetEnclosingElement: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetText: *const fn (*anyopaque, c_int, *?BSTR) callconv(.winapi) HRESULT,
    Move: *const fn (*anyopaque, c_int, c_int, *c_int) callconv(.winapi) HRESULT,
    MoveEndpointByUnit: *const fn (*anyopaque, c_int, c_int, c_int, *c_int) callconv(.winapi) HRESULT,
    MoveEndpointByRange: *const fn (*anyopaque, c_int, ?*anyopaque, c_int) callconv(.winapi) HRESULT,
    Select: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    AddToSelection: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    RemoveFromSelection: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    ScrollIntoView: *const fn (*anyopaque, BOOL) callconv(.winapi) HRESULT,
    GetChildren: *const fn (*anyopaque, *?*SAFEARRAY) callconv(.winapi) HRESULT,
};

const range_vtbl: RangeVtbl = .{
    .QueryInterface = &rangeQuery,
    .AddRef = &rangeAddRef,
    .Release = &rangeRelease,
    .Clone = &rangeClone,
    .Compare = &rangeCompare,
    .CompareEndpoints = &rangeCompareEndpoints,
    .ExpandToEnclosingUnit = &rangeExpand,
    .FindAttribute = &rangeFindAttribute,
    .FindText = &rangeFindText,
    .GetAttributeValue = &rangeAttribute,
    .GetBoundingRectangles = &rangeRectangles,
    .GetEnclosingElement = &rangeEnclosing,
    .GetText = &rangeText,
    .Move = &rangeMove,
    .MoveEndpointByUnit = &rangeMoveEndpoint,
    .MoveEndpointByRange = &rangeMoveEndpointByRange,
    .Select = &rangeSelect,
    .AddToSelection = &rangeNotMultiple,
    .RemoveFromSelection = &rangeNotMultiple,
    .ScrollIntoView = &rangeScroll,
    .GetChildren = &rangeChildren,
};

fn rangeQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_ITextRangeProvider)) {
        out.* = this;
        _ = Range.from(this).refs.fetchAdd(1, .monotonic);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn rangeAddRef(this: *anyopaque) callconv(.winapi) u32 {
    return Range.from(this).refs.fetchAdd(1, .monotonic) + 1;
}

fn rangeRelease(this: *anyopaque) callconv(.winapi) u32 {
    return Range.from(this).release();
}

fn rangeClone(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    const copy = Range.create(self.provider, self.start, self.end) orelse return E_OUTOFMEMORY;
    out.* = @ptrCast(copy);
    return S_OK;
}

fn rangeCompare(this: *anyopaque, target: ?*anyopaque, out: *BOOL) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    const o = self.other(target) orelse return E_INVALIDARG;
    out.* = @intFromBool(self.start.eql(o.start) and self.end.eql(o.end));
    return S_OK;
}

fn rangeCompareEndpoints(this: *anyopaque, which: c_int, target: ?*anyopaque, target_which: c_int, out: *c_int) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    const o = self.other(target) orelse return E_INVALIDARG;
    out.* = switch (self.endpoint(which).order(o.endpoint(target_which))) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return S_OK;
}

fn rangeExpand(this: *anyopaque, unit_raw: c_int) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    var locked = lock(self.provider) catch |err| return lockErr(err);
    defer locked.unlock();
    var view = locked.view;
    const unit: Unit = @enumFromInt(unit_raw);
    if (unit.used() == .document) {
        self.start = .{};
        self.end = view.end;
        return S_OK;
    }
    var start = view.clamp(self.start);
    // An empty range at the document's end takes the last unit.
    if (start.eql(view.end)) start = view.prevChar(view.end);
    self.start = view.unitStart(unit, start);
    self.end = view.unitNext(unit, self.start);
    return S_OK;
}

fn rangeFindAttribute(_: *anyopaque, _: c_int, _: VARIANT, _: BOOL, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // No attribute is told apart along the text.
    out.* = null;
    return S_OK;
}

fn rangeFindText(this: *anyopaque, text: ?BSTR, backward: BOOL, ignore_case: BOOL, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    out.* = null;
    const t = text orelse return E_INVALIDARG;
    const alloc = self.provider.alloc;
    const needle = std.unicode.utf16LeToUtf8Alloc(alloc, t[0..SysStringLen(t)]) catch return E_INVALIDARG;
    defer alloc.free(needle);
    var locked = lock(self.provider) catch |err| return lockErr(err);
    const found = locked.view.find(alloc, self.start, self.end, needle, backward != 0, ignore_case != 0) catch {
        locked.unlock();
        return E_OUTOFMEMORY;
    };
    locked.unlock();
    const f = found orelse return S_OK;
    const range = Range.create(self.provider, f.start, f.end) orelse return E_OUTOFMEMORY;
    out.* = @ptrCast(range);
    return S_OK;
}

fn rangeAttribute(_: *anyopaque, attribute: c_int, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    if (attribute == UIA_IsReadOnlyAttributeId) {
        // The terminal takes typing.
        boolVariant(out, false);
        return S_OK;
    }
    var not_supported: ?*anyopaque = null;
    if (UiaGetReservedNotSupportedValue(&not_supported) < 0) return S_OK;
    out.* = .{ .vt = VT_UNKNOWN, .val = .{ .punk = not_supported } };
    return S_OK;
}

fn rangeRectangles(this: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    out.* = null;
    const alloc = self.provider.alloc;
    var locked = lock(self.provider) catch |err| return lockErr(err);
    const parts = locked.view.visibleParts(alloc, self.start, self.end) catch {
        locked.unlock();
        return E_OUTOFMEMORY;
    };
    const size = locked.surface.core_surface.size;
    locked.unlock();
    defer alloc.free(parts);
    // Left, top, width, height in screen pixels, per visible row.
    const sa = SafeArrayCreateVector(VT_R8, 0, @intCast(parts.len * 4)) orelse return E_OUTOFMEMORY;
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.ClientToScreen(self.provider.hwnd, &origin);
    for (parts, 0..) |part, i| {
        const values = [4]f64{
            @floatFromInt(origin.x + @as(i64, size.padding.left) + @as(i64, part.x0) * size.cell.width),
            @floatFromInt(origin.y + @as(i64, size.padding.top) + @as(i64, part.row) * size.cell.height),
            @floatFromInt(@as(i64, part.x1 - part.x0) * size.cell.width),
            @floatFromInt(size.cell.height),
        };
        for (values, 0..) |v, k| {
            const index: i32 = @intCast(i * 4 + k);
            _ = SafeArrayPutElement(sa, &index, &v);
        }
    }
    out.* = sa;
    return S_OK;
}

fn rangeEnclosing(this: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    out.* = self.provider.simplePtr();
    _ = self.provider.addRef();
    return S_OK;
}

fn rangeText(this: *anyopaque, max_length: c_int, out: *?BSTR) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    out.* = null;
    const alloc = self.provider.alloc;
    var locked = lock(self.provider) catch |err| return lockErr(err);
    // At most `max_length` characters made: as many UTF-16 units or more.
    const limit: ?usize = if (max_length >= 0) @intCast(max_length) else null;
    const text = locked.view.text(alloc, self.start, self.end, null, limit) catch {
        locked.unlock();
        return E_OUTOFMEMORY;
    };
    locked.unlock();
    defer alloc.free(text);
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch return E_OUTOFMEMORY;
    defer alloc.free(wide);
    var len: usize = if (limit) |l| @min(wide.len, l) else wide.len;
    // Not between a surrogate pair's halves.
    if (len > 0 and len < wide.len and std.unicode.utf16IsHighSurrogate(wide[len - 1])) len -= 1;
    out.* = SysAllocStringLen(wide.ptr, @intCast(len)) orelse return E_OUTOFMEMORY;
    return S_OK;
}

fn rangeMove(this: *anyopaque, unit_raw: c_int, count: c_int, moved: *c_int) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    moved.* = 0;
    var locked = lock(self.provider) catch |err| return lockErr(err);
    defer locked.unlock();
    var view = locked.view;
    const unit: Unit = @enumFromInt(unit_raw);
    if (self.start.eql(self.end)) {
        const r = view.move(unit, self.start, count, true);
        self.start = r.pos;
        self.end = r.pos;
        moved.* = r.moved;
        return S_OK;
    }
    // A range spanning text moves by its start, and then spans one unit
    // (never past the last).
    const r = view.move(unit, view.unitStart(unit, self.start), count, false);
    moved.* = r.moved;
    if (r.moved == 0) return S_OK;
    self.start = r.pos;
    self.end = view.unitNext(unit, r.pos);
    return S_OK;
}

fn rangeMoveEndpoint(this: *anyopaque, which: c_int, unit_raw: c_int, count: c_int, moved: *c_int) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    moved.* = 0;
    var locked = lock(self.provider) catch |err| return lockErr(err);
    defer locked.unlock();
    const r = locked.view.move(@enumFromInt(unit_raw), self.endpoint(which), count, true);
    self.setEndpoint(which, r.pos);
    moved.* = r.moved;
    return S_OK;
}

fn rangeMoveEndpointByRange(this: *anyopaque, which: c_int, target: ?*anyopaque, target_which: c_int) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    const o = self.other(target) orelse return E_INVALIDARG;
    self.setEndpoint(which, o.endpoint(target_which));
    return S_OK;
}

fn rangeSelect(this: *anyopaque) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    var locked = lock(self.provider) catch |err| return lockErr(err);
    var view = locked.view;
    const screen = locked.surface.core_surface.renderer_state.terminal.screens.active;
    const start = view.clamp(self.start);
    const end = view.clamp(self.end);
    // The terminal has no caret to move: an empty range clears the
    // selection. Set directly, as the core's setSelection does but for
    // copy-on-select, as a selection a program makes doesn't copy; the
    // event is raised here, as the core's selection_changed would.
    const result = if (start.eql(end)) screen.select(null) else select: {
        const first = view.pin(start) orelse break :select screen.select(null);
        const last = view.pin(view.prevChar(end)) orelse break :select screen.select(null);
        break :select screen.select(terminal.Selection.init(first, last, false));
    };
    locked.unlock();
    result catch return E_OUTOFMEMORY;
    locked.surface.core_surface.renderer_thread.wakeup.notify() catch {};
    if (UiaClientsAreListening() != 0) _ = UiaRaiseAutomationEvent(self.provider.simplePtr(), UIA_Text_TextSelectionChangedEventId);
    return S_OK;
}

fn rangeNotMultiple(_: *anyopaque) callconv(.winapi) HRESULT {
    // One selection only (SupportedTextSelection_Single).
    return UIA_E_INVALIDOPERATION;
}

fn rangeScroll(this: *anyopaque, align_to_top: BOOL) callconv(.winapi) HRESULT {
    const self = Range.from(this);
    var locked = lock(self.provider) catch |err| return lockErr(err);
    var view = locked.view;
    // The row to show: the range's first at the top, or its last at the
    // bottom.
    const row: usize = if (align_to_top != 0)
        view.clamp(self.start).y
    else
        (view.clamp(self.end).y -| @as(u32, if (self.end.x == 0 and self.end.y > self.start.y) 1 else 0)) -| (view.rows -| 1);
    const surface = locked.surface;
    locked.unlock();
    _ = surface.core_surface.performBindingAction(.{ .scroll_to_row = row }) catch return E_FAIL;
    return S_OK;
}

fn rangeChildren(_: *anyopaque, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    out.* = SafeArrayCreateVector(VT_UNKNOWN, 0, 0) orelse return E_OUTOFMEMORY;
    return S_OK;
}
