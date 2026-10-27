//! Minimal Win32 bindings for the win32 apprt.
//!
//! Only the types, constants and functions the apprt uses are declared.
//! Everything uses the wide (W) variants; strings are UTF-16LE.

const std = @import("std");

pub const BOOL = c_int;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HRESULT = c_long;
pub const LPCWSTR = [*:0]const u16;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HDC = *opaque {};
pub const HGLOBAL = *anyopaque;
pub const HANDLE = *anyopaque;
pub const HMONITOR = *opaque {};
pub const HIMC = *opaque {};
pub const HKEY = *opaque {};
pub const HKL = *opaque {};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: c_long = 0, y: c_long = 0 };
pub const RECT = extern struct {
    left: c_long = 0,
    top: c_long = 0,
    right: c_long = 0,
    bottom: c_long = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: c_long,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: DWORD,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};

pub const FLASHWINFO = extern struct {
    cbSize: UINT = @sizeOf(FLASHWINFO),
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD = 0,
};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT = .{},
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT = .{},
};

// Window messages
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUIT = 0x0012;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_KEYFIRST = 0x0100;
pub const WM_KEYLAST = 0x0109;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_UNICHAR = 0x0109;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_PRINTCLIENT = 0x0318;
pub const WM_APP = 0x8000;

pub const UNICODE_NOCHAR = 0xFFFF;

// Window styles
pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
    WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_EX_APPWINDOW = 0x00040000;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x00200000;
pub const WS_EX_LAYERED = 0x00080000;
pub const LWA_ALPHA = 0x00000002;

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_OWNDC = 0x0020;

pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));

pub const GWL_STYLE = -16;
pub const GWLP_USERDATA = -21;

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOWMAXIMIZED = 3;
pub const SW_SHOW = 5;
pub const SW_RESTORE = 9;
pub const SW_MAXIMIZE = 3;

pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_NOCOPYBITS = 0x0100;
pub const SWP_NOOWNERZORDER = 0x0200;
pub const HDWP = *opaque {};
pub extern "user32" fn BeginDeferWindowPos(c_int) callconv(.winapi) ?HDWP;
pub extern "user32" fn DeferWindowPos(HDWP, HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) ?HDWP;
pub extern "user32" fn EndDeferWindowPos(HDWP) callconv(.winapi) BOOL;

pub const SIZE_MINIMIZED = 1;

pub const WA_INACTIVE = 0;

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;

pub const HTCLIENT = 1;
/// HTERROR (-2) as the low word of WM_SETCURSOR's lParam.
pub const HTERROR: u16 = 0xFFFE;

pub const MK_LBUTTON = 0x0001;
pub const MK_RBUTTON = 0x0002;
pub const MK_MBUTTON = 0x0010;
pub const MK_XBUTTON1 = 0x0020;
pub const MK_XBUTTON2 = 0x0040;
pub const XBUTTON1 = 0x0001;
pub const WHEEL_DELTA = 120;

pub const TME_LEAVE = 0x00000002;

pub const MONITOR_DEFAULTTONEAREST = 0x00000002;

pub const FLASHW_TRAY = 0x00000002;
pub const FLASHW_TIMERNOFG = 0x0000000C;

// Cursors (MAKEINTRESOURCE values)
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

// Virtual keys
pub const VK_BACK = 0x08;
pub const VK_TAB = 0x09;
pub const VK_RETURN = 0x0D;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_ESCAPE = 0x1B;
pub const VK_SPACE = 0x20;
pub const VK_F4 = 0x73;
pub const VK_F10 = 0x79;
pub const VK_NUMLOCK = 0x90;
pub const VK_SCROLL = 0x91;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;

pub const MAPVK_VK_TO_VSC_EX = 4;

pub const KF_EXTENDED = 0x0100;
pub const KF_REPEAT = 0x4000;
pub const KF_UP = 0x8000;

// Clipboard
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

// MessageBox
pub const MB_OK = 0x00000000;
pub const MB_OKCANCEL = 0x00000001;
pub const MB_YESNO = 0x00000004;
pub const MB_ICONWARNING = 0x00000030;
pub const MB_ICONINFORMATION = 0x00000040;
pub const MB_ICONERROR = 0x00000010;
pub const MB_DEFBUTTON2 = 0x00000100;
pub const IDOK = 1;
pub const IDCANCEL = 2;
pub const IDYES = 6;
pub const IDNO = 7;

// TaskDialog (comctl32 v6, which the manifest selects)
pub const TDF_ENABLE_HYPERLINKS = 0x0001;
pub const TDF_ALLOW_DIALOG_CANCELLATION = 0x0008;
pub const TDF_POSITION_RELATIVE_TO_WINDOW = 0x1000;
pub const TDCBF_OK_BUTTON = 0x0001;
pub const TDCBF_YES_BUTTON = 0x0002;
pub const TDCBF_NO_BUTTON = 0x0004;
pub const TDCBF_CANCEL_BUTTON = 0x0008;
pub const TDCBF_CLOSE_BUTTON = 0x0020;
/// The stock icons, MAKEINTRESOURCEW(-1), (-2) and (-3). An odd address,
/// so they are typed as anyopaque rather than as a UTF-16 pointer.
pub const TD_WARNING_ICON: *const anyopaque = @ptrFromInt(0xFFFF);
pub const TD_ERROR_ICON: *const anyopaque = @ptrFromInt(0xFFFE);
pub const TD_INFORMATION_ICON: *const anyopaque = @ptrFromInt(0xFFFD);

/// commctrl.h declares the task dialog structs under pshpack1, so every
/// field is byte-aligned.
pub const TASKDIALOG_BUTTON = extern struct {
    nButtonID: c_int align(1),
    pszButtonText: LPCWSTR align(1),
};

pub const PFTASKDIALOGCALLBACK = *const fn (HWND, UINT, WPARAM, LPARAM, isize) callconv(.winapi) HRESULT;
pub const TDN_BUTTON_CLICKED = 2;
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const TASKDIALOGCONFIG = extern struct {
    cbSize: UINT align(1) = @sizeOf(TASKDIALOGCONFIG),
    hwndParent: ?HWND align(1) = null,
    hInstance: ?HINSTANCE align(1) = null,
    dwFlags: c_int align(1) = 0,
    dwCommonButtons: c_int align(1) = 0,
    pszWindowTitle: ?LPCWSTR align(1) = null,
    /// HICON or PCWSTR.
    pszMainIcon: ?*const anyopaque align(1) = null,
    pszMainInstruction: ?LPCWSTR align(1) = null,
    pszContent: ?LPCWSTR align(1) = null,
    cButtons: UINT align(1) = 0,
    pButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultButton: c_int align(1) = 0,
    cRadioButtons: UINT align(1) = 0,
    pRadioButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultRadioButton: c_int align(1) = 0,
    pszVerificationText: ?LPCWSTR align(1) = null,
    pszExpandedInformation: ?LPCWSTR align(1) = null,
    pszExpandedControlText: ?LPCWSTR align(1) = null,
    pszCollapsedControlText: ?LPCWSTR align(1) = null,
    /// HICON or PCWSTR.
    pszFooterIcon: ?*const anyopaque align(1) = null,
    pszFooter: ?LPCWSTR align(1) = null,
    pfCallback: ?*const anyopaque align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: UINT align(1) = 0,
};

comptime {
    // The sizes the SDK headers give on 64-bit Windows.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(TASKDIALOG_BUTTON) == 12);
        std.debug.assert(@sizeOf(TASKDIALOGCONFIG) == 160);
    }
}

// IME
pub const GCS_COMPSTR = 0x0008;
pub const GCS_RESULTSTR = 0x0800;
pub const CFS_POINT = 0x0002;
pub const CFS_CANDIDATEPOS = 0x0040;

// DPI
pub const USER_DEFAULT_SCREEN_DPI = 96;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// DWM
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
/// Windows 11 (build 22000) and later only.
pub const DWMWA_BORDER_COLOR = 34;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;
pub const DWMWA_COLOR_DEFAULT: COLORREF = 0xFFFFFFFF;

// Registry
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD = 0x00000010;

pub const ATTACH_PARENT_PROCESS: DWORD = @bitCast(@as(i32, -1));

// user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class: LPCWSTR,
    name: LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MapWindowPoints(?HWND, ?HWND, [*]POINT, UINT) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(HWND, c_int, c_int, c_int, c_int, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(.winapi) ?HICON;
/// LoadImageW with a resource id (MAKEINTRESOURCE) for the name.
pub extern "user32" fn LoadImageW(?HINSTANCE, usize, UINT, c_int, c_int, UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn DestroyIcon(HICON) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(c_int, UINT) callconv(.winapi) c_int;
pub const IMAGE_ICON = 1;
pub const WM_SETICON = 0x0080;
pub const ICON_SMALL = 0;
pub const ICON_BIG = 1;
pub const SM_CXICON = 11;
pub const SM_CYICON = 12;
pub const SM_CXSMICON = 49;
pub const SM_CYSMICON = 50;

// Common controls (version 6, which the manifest asks for): the tooltip.
pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: DWORD,
};
pub const ICC_WIN95_CLASSES = 0x000000FF;
pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
pub const TOOLTIPS_CLASSW = L("tooltips_class32");
pub const TTS_ALWAYSTIP = 0x01;
pub const TTS_NOPREFIX = 0x02;
pub const TTF_SUBCLASS = 0x0010;
pub const WM_USER = 0x0400;
pub const TTM_SETMAXTIPWIDTH = WM_USER + 24;
pub const TTM_POP = WM_USER + 28;
pub const TTM_ADDTOOLW = WM_USER + 50;
pub const TTM_NEWTOOLRECTW = WM_USER + 52;
pub const WM_NOTIFY = 0x004E;
/// TTN_FIRST (-520) - 10, as NMHDR.code holds it.
pub const TTN_GETDISPINFOW: UINT = @bitCast(@as(i32, -530));
pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: usize,
    code: UINT,
};
pub const NMTTDISPINFOW = extern struct {
    hdr: NMHDR,
    lpszText: ?[*:0]const u16,
    szText: [80]u16,
    hinst: ?HINSTANCE,
    uFlags: UINT,
    lParam: LPARAM,
};
pub const TTTOOLINFOW = extern struct {
    cbSize: UINT = @sizeOf(TTTOOLINFOW),
    uFlags: UINT = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: RECT = .{},
    hinst: ?HINSTANCE = null,
    /// align(1): it can be LPSTR_TEXTCALLBACKW.
    lpszText: ?[*:0]align(1) const u16 = null,
    lParam: LPARAM = 0,
    lpReserved: ?*anyopaque = null,
};
/// The tool's text comes from TTN_GETDISPINFOW: (LPWSTR)-1, an odd address.
pub const LPSTR_TEXTCALLBACKW: [*:0]align(1) const u16 = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub const CS_DBLCLKS = 0x0008;
pub const HTTRANSPARENT: LRESULT = -1;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) c_short;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn ToUnicode(UINT, UINT, *const [256]u8, [*]u16, c_int, UINT) callconv(.winapi) c_int;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn MessageBoxW(?HWND, LPCWSTR, LPCWSTR, UINT) callconv(.winapi) c_int;
pub extern "user32" fn MessageBeep(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetParent(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ValidateRect(HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowEnabled(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterWindowMessageW(LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn GetLastActivePopup(HWND) callconv(.winapi) HWND;

// gdi32
pub extern "gdi32" fn GetStockObject(c_int) callconv(.winapi) ?*anyopaque;
pub const BLACK_BRUSH = 4;

pub const HGDIOBJ = *anyopaque;
pub const HFONT = *opaque {};
pub const HBITMAP = *opaque {};
pub const COLORREF = DWORD;

pub inline fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const LOGFONTW = extern struct {
    lfHeight: c_long,
    lfWidth: c_long,
    lfEscapement: c_long,
    lfOrientation: c_long,
    lfWeight: c_long,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]u16,
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: c_int = 0,
    iScrollWidth: c_int = 0,
    iScrollHeight: c_int = 0,
    iCaptionWidth: c_int = 0,
    iCaptionHeight: c_int = 0,
    lfCaptionFont: LOGFONTW = undefined,
    iSmCaptionWidth: c_int = 0,
    iSmCaptionHeight: c_int = 0,
    lfSmCaptionFont: LOGFONTW = undefined,
    iMenuWidth: c_int = 0,
    iMenuHeight: c_int = 0,
    lfMenuFont: LOGFONTW = undefined,
    lfStatusFont: LOGFONTW = undefined,
    lfMessageFont: LOGFONTW = undefined,
    iPaddedBorderWidth: c_int = 0,
};

pub const WM_NCHITTEST = 0x0084;
pub const SPI_GETNONCLIENTMETRICS = 0x0029;
pub const SRCCOPY = 0x00CC0020;
pub const TRANSPARENT = 1;
pub const DT_CENTER = 0x00000001;
pub const DT_VCENTER = 0x00000004;
pub const DT_SINGLELINE = 0x00000020;
pub const DT_NOPREFIX = 0x00000800;
pub const DT_END_ELLIPSIS = 0x00008000;
pub const DT_CALCRECT = 0x00000400;
pub const DT_RIGHT = 0x00000002;
pub const DT_HIDEPREFIX = 0x00100000;
pub const PS_SOLID = 0;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const SW_SHOWNA = 8;
pub const SIZE = extern struct { cx: c_int = 0, cy: c_int = 0 };

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

// Controls (the search box)
pub const WS_TABSTOP = 0x00010000;
pub const ES_AUTOHSCROLL = 0x0080;
pub const BS_OWNERDRAW = 0x000B;
pub const WM_SETFONT = 0x0030;
pub const WM_DRAWITEM = 0x002B;
pub const WM_COMMAND = 0x0111;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORLISTBOX = 0x0134;
pub const WM_CONTEXTMENU = 0x007B;
pub const EN_CHANGE = 0x0300;
pub const BN_CLICKED = 0;
pub const BN_DOUBLECLICKED = 5;
pub const EM_GETSEL = 0x00B0;
pub const EM_SETSEL = 0x00B1;
pub const EM_REPLACESEL = 0x00C2;
pub const EM_SETLIMITTEXT = 0x00C5;
pub const ODS_SELECTED = 0x0001;
pub const GWLP_WNDPROC = -4;
pub const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};
pub extern "user32" fn GetWindowTextW(HWND, [*]u16, c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(HWND) callconv(.winapi) c_int;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn CallWindowProcW(isize, HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "gdi32" fn SetBkColor(HDC, COLORREF) callconv(.winapi) COLORREF;

// The title prompt (a dialog from a template in memory)
pub const WM_INITDIALOG = 0x0110;
pub const DS_SETFONT = 0x40;
pub const DS_MODALFRAME = 0x80;
pub const WS_BORDER = 0x00800000;
pub const BS_DEFPUSHBUTTON = 0x0001;
pub const DLGPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize;
pub extern "user32" fn DialogBoxIndirectParamW(?HINSTANCE, *const anyopaque, ?HWND, DLGPROC, LPARAM) callconv(.winapi) isize;
pub extern "user32" fn EndDialog(HWND, isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetDlgItem(?HWND, c_int) callconv(.winapi) ?HWND;

// The clipboard confirmation (likewise)
pub const WS_HSCROLL = 0x00100000;
pub const ES_MULTILINE = 0x0004;
pub const ES_AUTOVSCROLL = 0x0040;
pub const ES_READONLY = 0x0800;
pub const BS_AUTOCHECKBOX = 0x0003;
pub const BM_GETCHECK = 0x00F0;
pub const BST_CHECKED = 1;
pub const SS_NOPREFIX = 0x0080;
pub const WM_CTLCOLORSTATIC = 0x0138;
pub const COLOR_WINDOW = 5;
pub const COLOR_WINDOWTEXT = 8;
pub extern "user32" fn GetSysColor(c_int) callconv(.winapi) DWORD;
pub extern "user32" fn GetSysColorBrush(c_int) callconv(.winapi) ?HBRUSH;

// Client-side decorations (the header bar as the title bar)
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const TME_NONCLIENT = 0x00000010;
pub const HTCAPTION = 2;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTTOP = 12;
pub const HTTOPLEFT = 13;
pub const HTTOPRIGHT = 14;
pub const HTCLOSE = 20;
pub const SC_SIZE = 0xF000;
pub const SC_MOVE = 0xF010;
pub const SC_MINIMIZE = 0xF020;
pub const SC_MAXIMIZE = 0xF030;
pub const SC_CLOSE = 0xF060;
pub const SC_RESTORE = 0xF120;
pub const SM_CYSIZEFRAME = 33;
pub const SM_CXPADDEDBORDER = 92;
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*anyopaque,
};

// The system menu
pub const WM_INITMENUPOPUP = 0x0117;
pub const WM_ENTERMENULOOP = 0x0211;
pub const WM_EXITMENULOOP = 0x0212;
pub const MF_BYPOSITION = 0x0400;
pub extern "user32" fn GetSystemMenu(HWND, BOOL) callconv(.winapi) ?HMENU;
pub extern "user32" fn GetMenuItemCount(?HMENU) callconv(.winapi) c_int;
pub extern "user32" fn DeleteMenu(HMENU, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenuStringW(HMENU, UINT, ?[*]u16, c_int, UINT) callconv(.winapi) c_int;
pub extern "user32" fn EnableMenuItem(HMENU, UINT, UINT) callconv(.winapi) BOOL;

// The command palette's list
pub const HWND_TOP: ?HWND = null;
pub const WS_VSCROLL = 0x00200000;
pub const LBS_NOTIFY = 0x0001;
pub const LBS_OWNERDRAWFIXED = 0x0010;
pub const LBS_NOINTEGRALHEIGHT = 0x0100;
pub const LB_ADDSTRING = 0x0180;
pub const LB_RESETCONTENT = 0x0184;
pub const LB_SETCURSEL = 0x0186;
pub const LB_GETCURSEL = 0x0188;
pub const LB_GETCOUNT = 0x018B;
pub const LB_SETITEMHEIGHT = 0x01A0;
pub const LB_GETITEMHEIGHT = 0x01A1;
pub const DT_TOP = 0x00000000;
pub const DT_BOTTOM = 0x00000008;
pub const DT_WORDBREAK = 0x00000010;
pub const VK_CLEAR = 0x0C;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_HOME = 0x24;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_INSERT = 0x2D;
pub const VK_DELETE = 0x2E;
pub extern "user32" fn IsChild(HWND, HWND) callconv(.winapi) BOOL;
pub extern "uxtheme" fn SetWindowTheme(HWND, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT;

// Popup menus
pub const MF_STRING = 0x0000;
pub const MF_GRAYED = 0x0001;
pub const MF_POPUP = 0x0010;
pub const MF_SEPARATOR = 0x0800;
pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_RIGHTALIGN = 0x0008;
pub const TPM_NONOTIFY = 0x0080;
pub const TPM_RETURNCMD = 0x0100;
pub const WM_NULL = 0x0000;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn AppendMenuW(HMENU, UINT, usize, ?LPCWSTR) callconv(.winapi) BOOL;
pub const MENUITEMINFOW = extern struct {
    cbSize: UINT = @sizeOf(MENUITEMINFOW),
    fMask: UINT = 0,
    fType: UINT = 0,
    fState: UINT = 0,
    wID: UINT = 0,
    hSubMenu: ?HMENU = null,
    hbmpChecked: ?HBITMAP = null,
    hbmpUnchecked: ?HBITMAP = null,
    dwItemData: usize = 0,
    dwTypeData: ?[*:0]const u16 = null,
    cch: UINT = 0,
    hbmpItem: ?HBITMAP = null,
};
pub const MIIM_STATE = 0x0001;
pub const MIIM_ID = 0x0002;
pub const MIIM_SUBMENU = 0x0004;
pub const MIIM_DATA = 0x0020;
pub const MIIM_STRING = 0x0040;
pub const MIIM_FTYPE = 0x0100;
pub const MFT_OWNERDRAW = 0x0100;
pub const MFT_SEPARATOR = 0x0800;
pub const MFS_GRAYED = 0x0003;
pub extern "user32" fn InsertMenuItemW(HMENU, UINT, BOOL, *const MENUITEMINFOW) callconv(.winapi) BOOL;
pub const MENUINFO = extern struct {
    cbSize: DWORD = @sizeOf(MENUINFO),
    fMask: DWORD = 0,
    dwStyle: DWORD = 0,
    cyMax: UINT = 0,
    hbrBack: ?HBRUSH = null,
    dwContextHelpID: DWORD = 0,
    dwMenuData: usize = 0,
};
pub const MIM_BACKGROUND = 0x00000002;
pub extern "user32" fn SetMenuInfo(HMENU, *const MENUINFO) callconv(.winapi) BOOL;
pub const WM_MEASUREITEM = 0x002C;
pub const WM_MENUCHAR = 0x0120;
pub const MEASUREITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemWidth: UINT,
    itemHeight: UINT,
    itemData: usize,
};
pub const ODT_MENU = 1;
pub const SM_CXMENUCHECK = 71;
pub const ODS_GRAYED = 0x0002;
pub const ODS_NOACCEL = 0x0100;
pub const MNC_EXECUTE = 2;
pub extern "gdi32" fn ExcludeClipRect(HDC, c_int, c_int, c_int, c_int) callconv(.winapi) c_int;
/// With TPM_RETURNCMD it returns the chosen item's id, 0 for none.
pub extern "user32" fn TrackPopupMenuEx(HMENU, UINT, c_int, c_int, HWND, ?*anyopaque) callconv(.winapi) c_int;
pub extern "user32" fn DestroyMenu(HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowRgn(HWND, ?HRGN, BOOL) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateRoundRectRgn(c_int, c_int, c_int, c_int, c_int, c_int) callconv(.winapi) ?HRGN;
pub extern "gdi32" fn FrameRgn(HDC, HRGN, HBRUSH, c_int, c_int) callconv(.winapi) BOOL;

pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(HDC, [*]const u16, c_int, *RECT, UINT) callconv(.winapi) c_int;
pub extern "user32" fn SystemParametersInfoForDpi(UINT, UINT, ?*anyopaque, UINT, UINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn AddFontMemResourceEx(*anyopaque, DWORD, ?*anyopaque, *DWORD) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn RemoveFontMemResourceEx(HANDLE) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetTextFaceW(HDC, c_int, [*]u16) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.winapi) ?HBITMAP;
pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    /// Negative: rows top first.
    biHeight: i32,
    biPlanes: WORD = 1,
    biBitCount: WORD = 32,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};
pub const DIB_RGB_COLORS = 0;
pub extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFOHEADER, UINT, *?[*]u8, ?HANDLE, DWORD) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, ?HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetObjectW(HGDIOBJ, c_int, ?*anyopaque) callconv(.winapi) c_int;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, ?HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn CreatePen(c_int, c_int, COLORREF) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn RoundRect(HDC, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn Polygon(HDC, [*]const POINT, c_int) callconv(.winapi) BOOL;
pub const NULL_BRUSH = 5;
pub const NULL_PEN = 8;
pub extern "gdi32" fn MoveToEx(HDC, c_int, c_int, ?*POINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn LineTo(HDC, c_int, c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn IntersectClipRect(HDC, c_int, c_int, c_int, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SelectClipRgn(HDC, ?HRGN) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn CreateFontIndirectW(*const LOGFONTW) callconv(.winapi) ?HFONT;

// kernel32
pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn LoadLibraryW(LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetEnvironmentVariableW(LPCWSTR, ?[*]u16, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateFileW(
    LPCWSTR,
    DWORD,
    DWORD,
    ?*anyopaque,
    DWORD,
    DWORD,
    ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenEventW(dwDesiredAccess: DWORD, bInheritHandle: BOOL, lpName: LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub const EVENT_MODIFY_STATE: DWORD = 0x0002;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const GENERIC_WRITE = 0x40000000;
pub const CREATE_ALWAYS = 2;
pub const FILE_ATTRIBUTE_DIRECTORY = 0x10;
pub const FILE_ATTRIBUTE_DEVICE = 0x40;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const IO_REPARSE_TAG_NAME_SURROGATE: DWORD = 0x20000000;
pub const IO_REPARSE_TAG_MOUNT_POINT: DWORD = 0xA0000003;
pub const IO_REPARSE_TAG_SYMLINK: DWORD = 0xA000000C;
pub const IO_REPARSE_TAG_LX_SYMLINK: DWORD = 0xA000001D;
pub const FILE_READ_ATTRIBUTES = 0x80;
pub const FILE_SHARE_READ = 0x1;
pub const FILE_SHARE_WRITE = 0x2;
pub const FILE_SHARE_DELETE = 0x4;
pub const OPEN_EXISTING = 3;
pub const FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
pub const FSCTL_GET_REPARSE_POINT = 0x000900A8;
pub extern "kernel32" fn DeviceIoControl(HANDLE, DWORD, ?*anyopaque, DWORD, ?*anyopaque, DWORD, ?*DWORD, ?*anyopaque) callconv(.winapi) BOOL;
pub const CSTR_EQUAL = 2;
pub extern "kernel32" fn CompareStringOrdinal([*]const u16, c_int, [*]const u16, c_int, BOOL) callconv(.winapi) c_int;
pub extern "kernel32" fn GetFileAttributesW(LPCWSTR) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFullPathNameW(LPCWSTR, DWORD, [*]u16, ?*?[*:0]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetShortPathNameW(LPCWSTR, [*]u16, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTempPathW(DWORD, [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn DeleteFileW(LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
pub const DRIVE_FIXED = 3;
pub extern "kernel32" fn GetDriveTypeW(LPCWSTR) callconv(.winapi) UINT;
pub const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };
pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    /// The reparse tag, when dwFileAttributes has FILE_ATTRIBUTE_REPARSE_POINT.
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
comptime {
    std.debug.assert(@sizeOf(WIN32_FIND_DATAW) == 592);
}
pub const FindExInfoStandard = 0;
pub const FindExInfoBasic = 1;
pub extern "kernel32" fn CreateDirectoryW(LPCWSTR, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn RemoveDirectoryW(LPCWSTR) callconv(.winapi) BOOL;
pub const FindExSearchNameMatch = 0;
pub extern "kernel32" fn FindFirstFileExW(LPCWSTR, c_int, *WIN32_FIND_DATAW, c_int, ?*anyopaque, DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindClose(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(HINSTANCE, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn AttachConsole(DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(
    ?*const fn (DWORD) callconv(.winapi) BOOL,
    BOOL,
) callconv(.winapi) BOOL;

// shell32
pub extern "shell32" fn ShellExecuteW(
    ?HWND,
    ?LPCWSTR,
    LPCWSTR,
    ?LPCWSTR,
    ?LPCWSTR,
    c_int,
) callconv(.winapi) ?HINSTANCE;

/// Natural alignment on x64 (shellapi.h packs it to 1 only on 32-bit).
pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: DWORD = @sizeOf(SHELLEXECUTEINFOW),
    fMask: c_ulong = 0,
    hwnd: ?HWND = null,
    lpVerb: ?LPCWSTR = null,
    lpFile: ?LPCWSTR = null,
    lpParameters: ?LPCWSTR = null,
    lpDirectory: ?LPCWSTR = null,
    nShow: c_int = 0,
    hInstApp: ?HINSTANCE = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?LPCWSTR = null,
    hkeyClass: ?HKEY = null,
    dwHotKey: DWORD = 0,
    hIconOrMonitor: ?HANDLE = null,
    hProcess: ?HANDLE = null,
};
comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(SHELLEXECUTEINFOW) == 112);
}
pub const SEE_MASK_INVOKEIDLIST = 0x0000000C;
pub const SEE_MASK_NOASYNC = 0x00000100;
pub const SEE_MASK_FLAG_NO_UI = 0x00000400;
pub extern "shell32" fn ShellExecuteExW(*SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(LPCWSTR) callconv(.winapi) HRESULT;
pub extern "shell32" fn ILCreateFromPathW(LPCWSTR) callconv(.winapi) ?*anyopaque;
pub extern "shell32" fn ILFree(?*anyopaque) callconv(.winapi) void;
pub extern "shell32" fn SHGetPathFromIDListEx(*const anyopaque, [*]u16, DWORD, c_int) callconv(.winapi) BOOL;
pub extern "shell32" fn SHOpenFolderAndSelectItems(*const anyopaque, UINT, ?[*]const *const anyopaque, DWORD) callconv(.winapi) HRESULT;

pub const APPBARDATA = extern struct {
    cbSize: DWORD = @sizeOf(APPBARDATA),
    hWnd: ?HWND = null,
    uCallbackMessage: UINT = 0,
    uEdge: UINT = 0,
    rc: RECT = .{},
    lParam: LPARAM = 0,
};
pub const ABM_GETAUTOHIDEBAREX = 0x0000000b;
pub const ABE_LEFT = 0;
pub const ABE_TOP = 1;
pub const ABE_RIGHT = 2;
pub const ABE_BOTTOM = 3;
pub extern "shell32" fn SHAppBarMessage(DWORD, *APPBARDATA) callconv(.winapi) usize;

// shlwapi
pub const ASSOCF_INIT_IGNOREUNKNOWN = 0x00000400;
pub const ASSOCSTR_EXECUTABLE = 2;
pub const ASSOCSTR_FRIENDLYAPPNAME = 4;
pub extern "shlwapi" fn AssocIsDangerous(LPCWSTR) callconv(.winapi) BOOL;
pub extern "shlwapi" fn AssocQueryStringW(
    c_uint,
    c_int,
    LPCWSTR,
    ?LPCWSTR,
    ?[*]u16,
    *DWORD,
) callconv(.winapi) HRESULT;

// imm32
pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(.winapi) c_long;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(.winapi) BOOL;

// dwmapi
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.winapi) HRESULT;
pub const HRGN = *opaque {};
pub const DWM_BB_ENABLE = 0x00000001;
pub const DWM_BB_BLURREGION = 0x00000002;
pub const DWM_BLURBEHIND = extern struct {
    dwFlags: DWORD,
    fEnable: BOOL,
    hRgnBlur: ?HRGN = null,
    fTransitionOnMaximized: BOOL = FALSE,
};
pub extern "dwmapi" fn DwmEnableBlurBehindWindow(HWND, *const DWM_BLURBEHIND) callconv(.winapi) HRESULT;
pub extern "gdi32" fn CreateRectRgn(c_int, c_int, c_int, c_int) callconv(.winapi) ?HRGN;

// comctl32. TaskDialogIndirect exists only in comctl32 v6, which the exe's
// manifest selects; it is resolved at run time (App.taskDialog) so a
// binary without that manifest still loads and falls back to a MessageBox.
pub const TaskDialogIndirectFn = *const fn (
    *const TASKDIALOGCONFIG,
    ?*c_int,
    ?*c_int,
    ?*BOOL,
) callconv(.winapi) HRESULT;

// ole32
pub extern "ole32" fn OleInitialize(?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;

// advapi32
pub extern "advapi32" fn RegGetValueW(
    HKEY,
    ?LPCWSTR,
    ?LPCWSTR,
    DWORD,
    ?*DWORD,
    ?*anyopaque,
    ?*DWORD,
) callconv(.winapi) c_long;

pub inline fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub inline fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

/// GET_X_LPARAM: the signed low word of an LPARAM.
pub inline fn xParam(lparam: LPARAM) i16 {
    return @bitCast(loword(lparam));
}

/// GET_Y_LPARAM: the signed high word of an LPARAM.
pub inline fn yParam(lparam: LPARAM) i16 {
    return @bitCast(hiword(lparam));
}

/// Wide string literal.
pub const L = @import("std").unicode.utf8ToUtf16LeStringLiteral;
