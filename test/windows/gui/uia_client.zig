//! A UI Automation client for the uia scenario (roadmap 6.4), run by the
//! harness on its hidden desktop (all its threads on it, as UI Automation's
//! own are), as a screen reader would read a pane:
//!
//!   ghostty-gui-uia.exe <pane hwnd> <command>...
//!
//! Commands, run in order, each printing one line "<command>: <result>"
//! (texts with "\r\n" as "\n", and any failure as "error <hresult>"):
//! name, doc, visible, caret, selection, rects, word:<n>, line:<n>,
//! char:<n>, find:<text>, and events (listen for the Text pattern's
//! events, type a character into the pane and count what comes).
const std = @import("std");
const w = @import("win.zig");

const HRESULT = i32;
const BOOL = i32;
const GUID = std.os.windows.GUID;
const BSTR = [*:0]u16;
const Slot = ?*const anyopaque;

extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?w.HANDLE;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysFreeString(?BSTR) callconv(.winapi) void;
extern "oleaut32" fn SysStringLen(?BSTR) callconv(.winapi) u32;
extern "oleaut32" fn SysAllocStringLen(?[*]const u16, u32) callconv(.winapi) ?BSTR;
extern "oleaut32" fn SafeArrayGetUBound(*anyopaque, u32, *i32) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayGetElement(*anyopaque, *const i32, *anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayDestroy(*anyopaque) callconv(.winapi) HRESULT;

const CLSID_CUIAutomation = GUID.parse("{ff48dba4-60ef-4201-aa87-54103eef594e}");
const IID_IUIAutomation = GUID.parse("{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}");
const IID_IUIAutomationTextPattern2 = GUID.parse("{506a921a-fcc9-409f-b23b-37eb74106872}");
const UIA_TextPattern2Id = 10024;
const CLSCTX_INPROC_SERVER = 0x1;
const COINIT_MULTITHREADED = 0x0;

fn Unknown(comptime T: type) type {
    return extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*T) callconv(.winapi) u32,
    };
}

const Automation = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(Automation),
        _3_4: [2]Slot,
        GetRootElement: *const fn (*Automation, *?*Element) callconv(.winapi) HRESULT, // 5
        ElementFromHandle: *const fn (*Automation, ?*anyopaque, *?*Element) callconv(.winapi) HRESULT, // 6
        _7_31: [25]Slot,
        AddAutomationEventHandler: *const fn (*Automation, c_int, *Element, c_int, ?*anyopaque, *Handler) callconv(.winapi) HRESULT, // 32
    },
};

/// IUIAutomationEventHandler: counts the events it hears (on UI
/// Automation's threads).
const Handler = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Handler) callconv(.winapi) u32,
        Release: *const fn (*Handler) callconv(.winapi) u32,
        HandleAutomationEvent: *const fn (*Handler, ?*anyopaque, c_int) callconv(.winapi) HRESULT,
    } = &handler_vtbl,
    text_changed: std.atomic.Value(u32) = .init(0),
    selection_changed: std.atomic.Value(u32) = .init(0),
    /// The pane's process: events from others aren't counted.
    pid: c_int = 0,
};

const IID_IUIAutomationEventHandler = GUID.parse("{146c3c17-f12e-4e22-8c27-f894b9b79c69}");
const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");

const handler_vtbl = @typeInfo(@FieldType(Handler, "vtbl")).pointer.child{
    .QueryInterface = &handlerQuery,
    .AddRef = &handlerRef,
    .Release = &handlerRef,
    .HandleAutomationEvent = &handlerEvent,
};

fn handlerQuery(self: *Handler, iid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IUIAutomationEventHandler)) {
        ppv.* = self;
        return 0;
    }
    ppv.* = null;
    return @bitCast(@as(u32, 0x80004002));
}

fn handlerRef(_: *Handler) callconv(.winapi) u32 {
    return 1;
}

fn handlerEvent(self: *Handler, sender: ?*anyopaque, event: c_int) callconv(.winapi) HRESULT {
    const e: *Element = @ptrCast(@alignCast(sender orelse return 0));
    var pid: c_int = 0;
    if (e.vtbl.get_CurrentProcessId(e, &pid) < 0 or pid != self.pid) return 0;
    switch (event) {
        20015 => _ = self.text_changed.fetchAdd(1, .monotonic),
        20014 => _ = self.selection_changed.fetchAdd(1, .monotonic),
        else => {},
    }
    return 0;
}

var handler: Handler = .{};
extern "user32" fn GetWindowThreadProcessId(?*anyopaque, *u32) callconv(.winapi) u32;

const Element = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(Element),
        _3_13: [11]Slot,
        GetCurrentPatternAs: *const fn (*Element, c_int, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // 14
        _15_19: [5]Slot,
        get_CurrentProcessId: *const fn (*Element, *c_int) callconv(.winapi) HRESULT, // 20
        get_CurrentControlType: *const fn (*Element, *c_int) callconv(.winapi) HRESULT, // 21
        _22: Slot,
        get_CurrentName: *const fn (*Element, *?BSTR) callconv(.winapi) HRESULT, // 23
    },
};

const TextPattern2 = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(TextPattern2),
        _3_4: [2]Slot,
        GetSelection: *const fn (*TextPattern2, *?*RangeArray) callconv(.winapi) HRESULT, // 5
        GetVisibleRanges: *const fn (*TextPattern2, *?*RangeArray) callconv(.winapi) HRESULT, // 6
        get_DocumentRange: *const fn (*TextPattern2, *?*Range) callconv(.winapi) HRESULT, // 7
        _8_9: [2]Slot,
        GetCaretRange: *const fn (*TextPattern2, *BOOL, *?*Range) callconv(.winapi) HRESULT, // 10
    },
};

const RangeArray = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(RangeArray),
        get_Length: *const fn (*RangeArray, *c_int) callconv(.winapi) HRESULT, // 3
        GetElement: *const fn (*RangeArray, c_int, *?*Range) callconv(.winapi) HRESULT, // 4
    },
};

const Range = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(Range),
        Clone: *const fn (*Range, *?*Range) callconv(.winapi) HRESULT, // 3
        _4_5: [2]Slot,
        ExpandToEnclosingUnit: *const fn (*Range, c_int) callconv(.winapi) HRESULT, // 6
        _7: Slot,
        FindText: *const fn (*Range, ?BSTR, BOOL, BOOL, *?*Range) callconv(.winapi) HRESULT, // 8
        _9: Slot,
        GetBoundingRectangles: *const fn (*Range, *?*anyopaque) callconv(.winapi) HRESULT, // 10
        _11: Slot,
        GetText: *const fn (*Range, c_int, *?BSTR) callconv(.winapi) HRESULT, // 12
        Move: *const fn (*Range, c_int, c_int, *c_int) callconv(.winapi) HRESULT, // 13
        _14: Slot,
        MoveEndpointByRange: *const fn (*Range, c_int, *Range, c_int) callconv(.winapi) HRESULT, // 15
        Select: *const fn (*Range) callconv(.winapi) HRESULT, // 16
    },
};

var out: std.ArrayList(u8) = .empty;
var alloc: std.mem.Allocator = undefined;

fn print(comptime fmt: []const u8, args: anytype) void {
    out.print(alloc, fmt, args) catch {};
}

/// A BSTR's text as UTF-8, "\r\n" as "\n", freed.
fn textOf(b: ?BSTR) []const u8 {
    const s = b orelse return "";
    defer SysFreeString(s);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, s[0..SysStringLen(s)]) catch return "";
    const plain = std.mem.replaceOwned(u8, alloc, utf8, "\r\n", "\n") catch return utf8;
    return std.mem.replaceOwned(u8, alloc, plain, "\n", "\\n") catch plain;
}

fn rangeText(r: *Range) []const u8 {
    var b: ?BSTR = null;
    if (r.vtbl.GetText(r, -1, &b) < 0) return "error";
    return textOf(b);
}

pub fn main() u8 {
    alloc = std.heap.page_allocator;
    var argc: c_int = 0;
    const argv = w.CommandLineToArgvW(w.GetCommandLineW(), &argc) orelse return 2;
    defer _ = w.LocalFree(@ptrCast(argv));
    if (argc < 3) return 2;
    const hwnd_text = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv[1])) catch return 2;
    const hwnd: ?*anyopaque = @ptrFromInt(std.fmt.parseInt(usize, hwnd_text, 10) catch return 2);

    _ = CoInitializeEx(null, COINIT_MULTITHREADED);
    var raw: ?*anyopaque = null;
    var hrc = CoCreateInstance(&CLSID_CUIAutomation, null, CLSCTX_INPROC_SERVER, &IID_IUIAutomation, &raw);
    if (hrc < 0) return fail("CoCreateInstance", hrc);
    const automation: *Automation = @ptrCast(@alignCast(raw.?));
    var element_opt: ?*Element = null;
    hrc = automation.vtbl.ElementFromHandle(automation, hwnd, &element_opt);
    if (hrc < 0) return fail("ElementFromHandle", hrc);
    const element = element_opt.?;
    var pattern_raw: ?*anyopaque = null;
    hrc = element.vtbl.GetCurrentPatternAs(element, UIA_TextPattern2Id, &IID_IUIAutomationTextPattern2, &pattern_raw);
    if (hrc < 0 or pattern_raw == null) return fail("GetCurrentPatternAs", hrc);
    const pattern: *TextPattern2 = @ptrCast(@alignCast(pattern_raw.?));

    var i: usize = 2;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const cmd = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv[i])) catch continue;
        if (std.mem.eql(u8, cmd, "events")) {
            events(automation, pattern, hwnd);
            continue;
        }
        run(element, pattern, cmd);
    }
    emit();
    return 0;
}

fn emit() void {
    const stdout = GetStdHandle(STD_OUTPUT_HANDLE) orelse return;
    _ = w.WriteFile(stdout, out.items.ptr, @intCast(out.items.len), null, null);
}

fn fail(what: []const u8, hrc: HRESULT) u8 {
    print("error: {s} failed {x}\n", .{ what, @as(u32, @bitCast(hrc)) });
    emit();
    return 1;
}

/// Listen for text and selection changes as a screen reader does (on the
/// desktop's root, its whole tree: Narrator and NVDA listen so, and an
/// element-scoped listener alone hears nothing from a window-hosted
/// provider), type a character into the pane (as a keyboard's WM_CHAR),
/// select text through the Text pattern, and count the events from the
/// pane's process: murrtty's poll tells listeners the text changed and the
/// cursor (the caret) moved, and a selection says so at once.
fn events(automation: *Automation, pattern: *TextPattern2, hwnd: ?*anyopaque) void {
    const TreeScope_Subtree = 7;
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(hwnd, &pid);
    handler.pid = @intCast(pid);
    var root: ?*Element = null;
    if (automation.vtbl.GetRootElement(automation, &root) < 0 or root == null) return print("events: error root\n", .{});
    for ([_]c_int{ 20015, 20014 }) |event| {
        const hrc = automation.vtbl.AddAutomationEventHandler(automation, event, root.?, TreeScope_Subtree, null, &handler);
        if (hrc < 0) return print("events: error {x}\n", .{@as(u32, @bitCast(hrc))});
    }
    // UI Automation tells murrtty of the listeners asynchronously.
    pump(500);
    _ = PostMessageW(hwnd, 0x0102, 'x', 1);
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 50) {
        if (handler.text_changed.load(.monotonic) > 0 and handler.selection_changed.load(.monotonic) > 0) break;
        pump(50);
    }
    const typed_text = handler.text_changed.load(.monotonic);
    const typed_selection = handler.selection_changed.load(.monotonic);
    // A selection made through UI Automation raises its event at once.
    if (document(pattern)) |r| {
        const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, "murrtty") catch return;
        var found: ?*Range = null;
        if (r.vtbl.FindText(r, SysAllocStringLen(wide.ptr, @intCast(wide.len)), 0, 1, &found) >= 0) if (found) |f| {
            _ = f.vtbl.Select(f);
        };
    }
    pump(1000);
    print("events: typed text {d} caret {d} then selected {d}\n", .{ typed_text, typed_selection, handler.selection_changed.load(.monotonic) - typed_selection });
}

extern "user32" fn PostMessageW(?*anyopaque, u32, usize, isize) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(*[48]u8, ?*anyopaque, u32, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const [48]u8) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const [48]u8) callconv(.winapi) isize;

/// Wait `ms`, handling this thread's messages meanwhile.
fn pump(ms: u32) void {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 10) {
        var msg: [48]u8 = undefined;
        while (PeekMessageW(&msg, null, 0, 0, 1) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        w.Sleep(10);
    }
}

fn document(pattern: *TextPattern2) ?*Range {
    var r: ?*Range = null;
    if (pattern.vtbl.get_DocumentRange(pattern, &r) < 0) return null;
    return r;
}

/// An empty range at the document's start.
fn atStart(pattern: *TextPattern2) ?*Range {
    const r = document(pattern) orelse return null;
    // The end to the start (endpoint 1 to endpoint 0).
    if (r.vtbl.MoveEndpointByRange(r, 1, r, 0) < 0) return null;
    return r;
}

fn run(element: *Element, pattern: *TextPattern2, cmd: []const u8) void {
    var it = std.mem.splitScalar(u8, cmd, ':');
    const name = it.next() orelse return;
    const arg = it.rest();
    if (std.mem.eql(u8, name, "name")) {
        var b: ?BSTR = null;
        var t: c_int = 0;
        _ = element.vtbl.get_CurrentName(element, &b);
        _ = element.vtbl.get_CurrentControlType(element, &t);
        print("name: {s} type {d}\n", .{ textOf(b), t });
    } else if (std.mem.eql(u8, name, "doc")) {
        const r = document(pattern) orelse return print("doc: error\n", .{});
        print("doc: {s}\n", .{rangeText(r)});
    } else if (std.mem.eql(u8, name, "visible") or std.mem.eql(u8, name, "selection")) {
        var arr: ?*RangeArray = null;
        const hrc = if (name[0] == 'v') pattern.vtbl.GetVisibleRanges(pattern, &arr) else pattern.vtbl.GetSelection(pattern, &arr);
        if (hrc < 0) return print("{s}: error {x}\n", .{ name, @as(u32, @bitCast(hrc)) });
        var len: c_int = 0;
        _ = arr.?.vtbl.get_Length(arr.?, &len);
        var r: ?*Range = null;
        if (len < 1 or arr.?.vtbl.GetElement(arr.?, 0, &r) < 0) return print("{s}: none\n", .{name});
        print("{s}: {d} {s}\n", .{ name, len, rangeText(r.?) });
    } else if (std.mem.eql(u8, name, "caret")) {
        // The text before the caret.
        var active: BOOL = 0;
        var caret: ?*Range = null;
        if (pattern.vtbl.GetCaretRange(pattern, &active, &caret) < 0) return print("caret: error\n", .{});
        const r = document(pattern) orelse return;
        _ = r.vtbl.MoveEndpointByRange(r, 1, caret.?, 0);
        print("caret: {s}\n", .{rangeText(r)});
    } else if (std.mem.eql(u8, name, "rects")) {
        var active: BOOL = 0;
        var caret: ?*Range = null;
        if (pattern.vtbl.GetCaretRange(pattern, &active, &caret) < 0) return print("rects: error\n", .{});
        const line = caret.?;
        _ = line.vtbl.ExpandToEnclosingUnit(line, 3);
        var sa: ?*anyopaque = null;
        if (line.vtbl.GetBoundingRectangles(line, &sa) < 0 or sa == null) return print("rects: error\n", .{});
        defer _ = SafeArrayDestroy(sa.?);
        var ub: i32 = -1;
        _ = SafeArrayGetUBound(sa.?, 1, &ub);
        var v: [4]f64 = .{ 0, 0, 0, 0 };
        for (&v, 0..) |*d, i| {
            const index: i32 = @intCast(i);
            if (index <= ub) _ = SafeArrayGetElement(sa.?, &index, d);
        }
        print("rects: {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{ @divTrunc(ub + 1, 4), v[0], v[1], v[2], v[3] });
    } else if (std.mem.eql(u8, name, "word") or std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "char")) {
        const unit: c_int = if (name[0] == 'w') 2 else if (name[0] == 'l') 3 else 0;
        const n = std.fmt.parseInt(c_int, arg, 10) catch 0;
        const r = atStart(pattern) orelse return print("{s}: error\n", .{name});
        _ = r.vtbl.ExpandToEnclosingUnit(r, unit);
        var moved: c_int = 0;
        if (n != 0) _ = r.vtbl.Move(r, unit, n, &moved);
        print("{s}:{s}: {d} {s}\n", .{ name, arg, moved, rangeText(r) });
    } else if (std.mem.eql(u8, name, "find")) {
        const r = document(pattern) orelse return print("find: error\n", .{});
        const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, arg) catch return;
        const b = SysAllocStringLen(wide.ptr, @intCast(wide.len));
        var found: ?*Range = null;
        if (r.vtbl.FindText(r, b, 0, 1, &found) < 0) return print("find: error\n", .{});
        const f = found orelse return print("find: none\n", .{});
        _ = f.vtbl.Select(f);
        print("find: {s}\n", .{rangeText(f)});
    } else print("{s}: unknown\n", .{cmd});
}
