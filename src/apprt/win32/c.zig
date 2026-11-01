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
pub const LPWSTR = [*:0]u16;

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

pub const IMECHARPOSITION = extern struct {
    dwSize: DWORD = @sizeOf(IMECHARPOSITION),
    dwCharPos: DWORD,
    pt: POINT = .{ .x = 0, .y = 0 },
    cLineHeight: UINT = 0,
    rcDocument: RECT = .{},
};

// Window messages
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_ENDSESSION = 0x0016;
pub const WM_QUERYENDSESSION = 0x0011;
pub extern "kernel32" fn RegisterApplicationRestart(?[*:0]const u16, DWORD) callconv(.winapi) HRESULT;
pub const RESTART_NO_CRASH = 1;
pub const RESTART_NO_HANG = 2;
pub extern "kernel32" fn UnregisterApplicationRestart() callconv(.winapi) HRESULT;
pub extern "kernel32" fn GetCurrentDirectoryW(DWORD, ?[*]u16) callconv(.winapi) DWORD;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
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
pub const WM_MOUSEACTIVATE = 0x0021;
pub const MA_NOACTIVATE = 3;
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
pub const WM_IME_SETCONTEXT = 0x0281;
pub const WM_IME_REQUEST = 0x0288;
pub const WM_SYSCOMMAND = 0x0112;
pub const SC_KEYMENU = 0xF100;
pub const WM_TIMER = 0x0113;
pub const WM_GETOBJECT = 0x003D;
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
pub const WM_CANCELMODE = 0x001F;
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
pub const SW_SHOWMINIMIZED = 2;
pub const WPF_RESTORETOMAXIMIZED = 0x0002;
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
pub const WHEEL_PAGESCROLL = 0xFFFFFFFF;
pub const SPI_GETWHEELSCROLLLINES = 0x0068;

pub const TME_LEAVE = 0x00000002;

pub const MONITOR_DEFAULTTONEAREST = 0x00000002;
pub const MONITOR_DEFAULTTOPRIMARY = 0x00000001;

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
pub const CFS_EXCLUDE = 0x0080;
pub const ISC_SHOWUICOMPOSITIONWINDOW: LPARAM = 0x80000000;
pub const IMR_COMPOSITIONWINDOW = 0x0001;
pub const IMR_CANDIDATEWINDOW = 0x0002;
pub const IMR_QUERYCHARPOSITION = 0x0006;

// DPI
pub const USER_DEFAULT_SCREEN_DPI = 96;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// DWM
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
pub const SWP_SHOWWINDOW = 0x0040;
/// Windows 11 (build 22000) and later only.
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
pub const DWMWCP_ROUND: c_int = 2;
pub const DWMWA_BORDER_COLOR = 34;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;
pub const DWMWA_COLOR_DEFAULT: COLORREF = 0xFFFFFFFF;
/// Windows 11 22H2 (build 22621) and later only.
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
pub const DWMSBT_AUTO: DWORD = 0;
pub const DWMSBT_TRANSIENTWINDOW: DWORD = 3;
pub extern "dwmapi" fn DwmGetWindowAttribute(HWND, DWORD, *anyopaque, DWORD) callconv(.winapi) HRESULT;

// user32's undocumented accent policy, resolved at run time (App.accentFn).
pub const WCA_ACCENT_POLICY = 19;
pub const ACCENT_DISABLED: DWORD = 0;
pub const ACCENT_ENABLE_BLURBEHIND: DWORD = 3;
pub const ACCENT_POLICY = extern struct {
    AccentState: DWORD,
    AccentFlags: DWORD = 0,
    /// AABBGGRR.
    GradientColor: DWORD = 0,
    AnimationId: DWORD = 0,
};
pub const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    Attrib: DWORD,
    pvData: *anyopaque,
    cbData: usize,
};
pub const SetWindowCompositionAttributeFn = *const fn (HWND, *WINDOWCOMPOSITIONATTRIBDATA) callconv(.winapi) BOOL;

// ntdll's RtlGetVersion: GetVersionExW reports Windows 8 to an exe whose
// manifest doesn't list the newer versions.
pub const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: DWORD = @sizeOf(OSVERSIONINFOW),
    dwMajorVersion: DWORD = 0,
    dwMinorVersion: DWORD = 0,
    dwBuildNumber: DWORD = 0,
    dwPlatformId: DWORD = 0,
    szCSDVersion: [128]u16 = @splat(0),
};
pub extern "ntdll" fn RtlGetVersion(*OSVERSIONINFOW) callconv(.winapi) c_long;

// Registry
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD = 0x00000010;
pub const RRF_RT_REG_SZ = 0x00000002;
pub const REG_SZ = 1;
pub extern "advapi32" fn RegSetKeyValueW(HKEY, ?LPCWSTR, ?LPCWSTR, DWORD, ?*const anyopaque, DWORD) callconv(.winapi) c_long;
pub extern "advapi32" fn RegDeleteTreeW(HKEY, ?LPCWSTR) callconv(.winapi) c_long;

pub const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;
pub extern "kernel32" fn LoadLibraryExW(LPCWSTR, ?*anyopaque, DWORD) callconv(.winapi) ?HINSTANCE;

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
// Window options (roadmap 4.6).
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const GWL_EXSTYLE = -20;
pub const WM_SIZING = 0x0214;
pub const WMSZ_LEFT = 1;
pub const WMSZ_RIGHT = 2;
pub const WMSZ_TOP = 3;
pub const WMSZ_TOPLEFT = 4;
pub const WMSZ_TOPRIGHT = 5;
pub const WMSZ_BOTTOM = 6;
pub const WMSZ_BOTTOMLEFT = 7;
pub const WMSZ_BOTTOMRIGHT = 8;
pub const DWMWA_EXTENDED_FRAME_BOUNDS = 9;
pub const MONITOR_DEFAULTTONULL = 0;

// Dragging tabs between windows (roadmap 4.5).
pub extern "user32" fn WindowFromPoint(POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(HWND, UINT) callconv(.winapi) ?HWND;
pub const GA_ROOT = 2;
pub const GA_ROOTOWNER = 3;
/// The parent for message-only windows.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub extern "user32" fn FindWindowExW(?HWND, ?HWND, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn SetParent(HWND, ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetSystemMetrics(c_int) callconv(.winapi) c_int;

// The inspector's window (roadmap 5.12): GL 1.1's clears, from opengl32
// itself, and the save dialog for its Terminal IO events.
pub const GL_COLOR_BUFFER_BIT = 0x4000;

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: [*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};
pub extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
pub const OFN_OVERWRITEPROMPT = 0x00000002;
pub const OFN_NOCHANGEDIR = 0x00000008;
pub const OFN_PATHMUSTEXIST = 0x00000800;
pub const OFN_EXPLORER = 0x00080000;
pub const SM_CXDRAG = 68;
pub const SM_CYDRAG = 69;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub const CS_DBLCLKS = 0x0008;
pub const HTTRANSPARENT: LRESULT = -1;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDBLCLK = 0x0209;
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
pub extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn MonitorFromRect(*const RECT, DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetParent(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetTopWindow(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindow(HWND, UINT) callconv(.winapi) ?HWND;
pub const GW_HWNDNEXT = 2;
pub extern "user32" fn ValidateRect(HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowEnabled(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(?HWND) callconv(.winapi) BOOL;
pub const WM_DISPLAYCHANGE = 0x007E;
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
pub const BM_SETCHECK = 0x00F1;
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
/// Rows that are only indices (the owner draws them): LB_SETCOUNT.
pub const LBS_NODATA = 0x2000;
pub const LB_SETCOUNT = 0x01A7;
pub const LB_SETTOPINDEX = 0x0197;
pub const LBN_SELCHANGE = 1;
pub const LBN_DBLCLK = 2;
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
pub const ODS_FOCUS = 0x0010;
pub const ODS_NOFOCUSRECT = 0x0200;
pub const DM_SETDEFID = 0x0401;
pub const WM_GETDLGCODE = 0x0087;
pub extern "user32" fn GetDlgCtrlID(HWND) callconv(.winapi) c_int;
pub const DLGC_WANTALLKEYS = 0x0004;
pub const SS_CENTER = 0x0001;
pub const EN_SETFOCUS = 0x0100;
pub const EN_KILLFOCUS = 0x0200;
pub const SM_CXMENUCHECK = 71;
pub const ODS_GRAYED = 0x0002;
pub const ODS_CHECKED = 0x0008;
pub const ODS_NOACCEL = 0x0100;
pub const MF_BYCOMMAND = 0x0000;
pub const MF_CHECKED = 0x0008;
pub extern "user32" fn CheckMenuItem(HMENU, UINT, UINT) callconv(.winapi) DWORD;
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
pub extern "user32" fn SystemParametersInfoW(UINT, UINT, ?*anyopaque, UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetErrorMode(UINT) callconv(.winapi) UINT;
pub const SEM_FAILCRITICALERRORS = 0x0001;
pub const SEM_NOGPFAULTERRORBOX = 0x0002;
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
pub extern "kernel32" fn FreeLibrary(HINSTANCE) callconv(.winapi) BOOL;
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

// The single instance (roadmap 5.1, ipc.zig): its named pipe, the users
// and integrity levels on either end, and starting an instance.
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = FALSE,
};
pub const GENERIC_READ = 0x80000000;
pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const PIPE_TYPE_MESSAGE = 0x00000004;
pub const PIPE_READMODE_MESSAGE = 0x00000002;
pub const PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;
pub const PIPE_UNLIMITED_INSTANCES = 255;
pub const SECURITY_SQOS_PRESENT = 0x00100000;
pub const SECURITY_IDENTIFICATION = 0x00010000;
pub const ERROR_FILE_NOT_FOUND = 2;
pub const ERROR_ACCESS_DENIED = 5;
pub const ERROR_PIPE_BUSY = 231;
pub const ERROR_MORE_DATA = 234;
pub const ERROR_PIPE_CONNECTED = 535;
pub extern "kernel32" fn CreateNamedPipeW(LPCWSTR, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, ?*const SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ConnectNamedPipe(HANDLE, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn DisconnectNamedPipe(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitNamedPipeW(LPCWSTR, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetNamedPipeHandleState(HANDLE, ?*DWORD, ?*DWORD, ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerProcessId(HANDLE, *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerSessionId(HANDLE, *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeClientSessionId(HANDLE, *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn ProcessIdToSessionId(DWORD, *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetModuleFileNameW(?HINSTANCE, [*]u16, DWORD) callconv(.winapi) DWORD;
pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: DWORD = 0,
    dwThreadId: DWORD = 0,
};
pub extern "kernel32" fn CreateProcessW(?LPCWSTR, ?LPWSTR, ?*anyopaque, ?*anyopaque, BOOL, DWORD, ?*anyopaque, ?LPCWSTR, *STARTUPINFOW, *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub const TOKEN_DUPLICATE = 0x0002;
pub const TOKEN_IMPERSONATE = 0x0004;
pub const TOKEN_QUERY = 0x0008;
pub const TokenUser = 1;
pub const TokenIntegrityLevel = 25;
pub extern "advapi32" fn OpenProcessToken(HANDLE, DWORD, *HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(HANDLE, c_int, ?*anyopaque, DWORD, *DWORD) callconv(.winapi) BOOL;
pub const SE_KERNEL_OBJECT = 6;
pub const OWNER_SECURITY_INFORMATION = 0x00000001;
pub const LABEL_SECURITY_INFORMATION = 0x00000010;
pub extern "advapi32" fn GetSecurityInfo(HANDLE, c_int, DWORD, ?*?*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*?*anyopaque) callconv(.winapi) DWORD;
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub extern "userenv" fn CreateEnvironmentBlock(*?*anyopaque, ?HANDLE, BOOL) callconv(.winapi) BOOL;
pub extern "userenv" fn DestroyEnvironmentBlock(*anyopaque) callconv(.winapi) BOOL;
pub const SDDL_REVISION_1 = 1;
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(LPCWSTR, DWORD, *?*anyopaque, ?*u32) callconv(.winapi) BOOL;
pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
pub const ERROR_BROKEN_PIPE = 109;
pub const ERROR_IO_PENDING = 997;
pub const ERROR_OPERATION_ABORTED = 995;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ResetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForMultipleObjects(DWORD, [*]const HANDLE, BOOL, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetOverlappedResult(HANDLE, *OVERLAPPED, *DWORD, BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(HANDLE, ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetEnvironmentVariableW(LPCWSTR, ?LPCWSTR) callconv(.winapi) BOOL;
pub const CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
pub extern "user32" fn AllowSetForegroundWindow(DWORD) callconv(.winapi) BOOL;

// Starting murrtty again on its software OpenGL (software_gl.zig).
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOEXW) },
    lpAttributeList: ?*anyopaque = null,
};
pub const STARTF_USESTDHANDLES = 0x00000100;
pub const STARTF_USEHOTKEY = 0x00000200;
pub const STARTF_USEMONITOR = 0x00000400;
pub const STARTF_TITLEISAPPID = 0x00001000;
/// Undocumented: set beside STARTF_TITLEISAPPID by
/// SetCurrentProcessExplicitAppUserModelID, the title then being shell32's
/// own allocation, which it frees when the ID changes.
pub const STARTF_TITLE_ALLOCATED = 0x00004000;
pub const CREATE_SUSPENDED = 0x00000004;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const DUPLICATE_SAME_ACCESS = 0x00000002;
pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
pub const STILL_ACTIVE = 259;
pub const SYNCHRONIZE = 0x00100000;
pub const ERROR_ALREADY_EXISTS = 183;
pub const QS_ALLINPUT = 0x04FF;
pub extern "kernel32" fn GetStartupInfoW(*STARTUPINFOW) callconv(.winapi) void;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;
pub extern "kernel32" fn GetStdHandle(DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn DuplicateHandle(HANDLE, HANDLE, HANDLE, *HANDLE, DWORD, BOOL, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, DWORD, DWORD, *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, DWORD, usize, *const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn TerminateProcess(HANDLE, c_uint) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn MsgWaitForMultipleObjects(DWORD, [*]const HANDLE, BOOL, DWORD, DWORD) callconv(.winapi) DWORD;

// COM, for the taskbar's Jump List (jump_list.zig).
pub const GUID = std.os.windows.GUID;
pub const COINIT_APARTMENTTHREADED = 0x2;
pub const CLSCTX_INPROC_SERVER = 0x1;
pub extern "ole32" fn CoInitializeEx(?*anyopaque, DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, DWORD, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
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
pub extern "kernel32" fn FindNextFileW(HANDLE, *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
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

// Desktop notifications as a notification-area icon's balloons (roadmap
// 5.2, Notifications.zig).
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    /// uTimeout before NOTIFYICON_VERSION_4.
    uVersion: UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?HICON = null,
};
pub const NIM_ADD = 0;
pub const NIM_MODIFY = 1;
pub const NIM_DELETE = 2;
pub const NIM_SETVERSION = 4;
pub const NIF_MESSAGE = 0x01;
pub const NIF_ICON = 0x02;
pub const NIF_TIP = 0x04;
pub const NIF_INFO = 0x10;
pub const NIF_SHOWTIP = 0x80;
pub const NIIF_USER = 0x04;
pub const NIIF_LARGE_ICON = 0x20;
pub const NIIF_RESPECT_QUIET_TIME = 0x80;
pub const NOTIFYICON_VERSION_4 = 4;
pub const NIN_SELECT = WM_USER + 0;
pub const NIN_KEYSELECT = WM_USER + 1;
pub const NIN_BALLOONTIMEOUT = WM_USER + 4;
pub const NIN_BALLOONUSERCLICK = WM_USER + 5;
pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub const MSGFLT_ALLOW = 1;
pub extern "user32" fn ChangeWindowMessageFilterEx(HWND, UINT, DWORD, ?*anyopaque) callconv(.winapi) BOOL;

// Global key bindings as hot keys (roadmap 5.5, GlobalKeys.zig).
pub const WM_HOTKEY = 0x0312;
pub const WM_INPUTLANGCHANGE = 0x0051;
pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub const MOD_WIN = 0x0008;
pub const MOD_NOREPEAT = 0x4000;
pub const MAPVK_VSC_TO_VK_EX = 3;
pub const ERROR_HOTKEY_ALREADY_REGISTERED = 1409;
pub extern "user32" fn RegisterHotKey(?HWND, c_int, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(?HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn VkKeyScanW(u16) callconv(.winapi) i16;
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

// uxtheme's buffered painting: a 32-bit buffer whose alpha can be set
// before it reaches the window.
pub const HPAINTBUFFER = *opaque {};
pub const BPBF_TOPDOWNDIB = 2;
pub const BPPF_ERASE = 0x0001;
pub const BP_PAINTPARAMS = extern struct {
    cbSize: DWORD = @sizeOf(BP_PAINTPARAMS),
    dwFlags: DWORD = 0,
    prcExclude: ?*const RECT = null,
    pBlendFunction: ?*const anyopaque = null,
};
pub extern "uxtheme" fn BufferedPaintInit() callconv(.winapi) HRESULT;
pub extern "uxtheme" fn BufferedPaintUnInit() callconv(.winapi) HRESULT;
pub extern "uxtheme" fn BeginBufferedPaint(HDC, *const RECT, c_int, ?*const BP_PAINTPARAMS, *?HDC) callconv(.winapi) ?HPAINTBUFFER;
pub extern "uxtheme" fn EndBufferedPaint(HPAINTBUFFER, BOOL) callconv(.winapi) HRESULT;
pub extern "uxtheme" fn BufferedPaintSetAlpha(HPAINTBUFFER, ?*const RECT, u8) callconv(.winapi) HRESULT;

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

// Drag and drop onto a pane (roadmap 5.8).
pub const POINTL = extern struct { x: c_long = 0, y: c_long = 0 };
pub const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: c_long,
    tymed: DWORD,
};
pub const STGMEDIUM = extern struct {
    tymed: DWORD = 0,
    /// The union's HGLOBAL member (TYMED_HGLOBAL), the one read here.
    hGlobal: ?HGLOBAL = null,
    pUnkForRelease: ?*anyopaque = null,
};
pub extern "ole32" fn RegisterDragDrop(HWND, *anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn RevokeDragDrop(HWND) callconv(.winapi) HRESULT;
pub extern "ole32" fn ReleaseStgMedium(*STGMEDIUM) callconv(.winapi) void;
pub extern "ole32" fn OleGetClipboard(*?*anyopaque) callconv(.winapi) HRESULT;
pub extern "shell32" fn DragQueryFileW(*anyopaque, UINT, ?[*]u16, UINT) callconv(.winapi) UINT;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;

// The config editor's pickers (roadmap F1e): a key's subkeys (WSL's
// distributions), and Windows' folder dialog (file_dialog.zig).
pub const KEY_READ: DWORD = 0x20019;
pub extern "advapi32" fn RegOpenKeyExW(HKEY, LPCWSTR, DWORD, DWORD, *?HKEY) callconv(.winapi) c_long;
pub extern "advapi32" fn RegEnumKeyExW(HKEY, DWORD, [*]u16, *DWORD, ?*DWORD, ?[*]u16, ?*DWORD, ?*anyopaque) callconv(.winapi) c_long;
pub extern "advapi32" fn RegCloseKey(HKEY) callconv(.winapi) c_long;
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
pub extern "shell32" fn SHCreateItemFromParsingName(LPCWSTR, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "kernel32" fn GetSystemDirectoryW([*]u16, UINT) callconv(.winapi) UINT;

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

// The configuration editor (roadmap F1, ConfigEditor.zig): its list's
// scroll bar, the search field's placeholder, a file saved whole, and the
// color and file pickers.
pub const WM_VSCROLL = 0x0115;
pub const SB_VERT = 1;
pub const SB_LINEUP = 0;
pub const SB_LINEDOWN = 1;
pub const SB_PAGEUP = 2;
pub const SB_PAGEDOWN = 3;
pub const SB_THUMBTRACK = 5;
pub const SB_TOP = 6;
pub const SB_BOTTOM = 7;
pub const SIF_RANGE = 0x1;
pub const SIF_PAGE = 0x2;
pub const SIF_POS = 0x4;
pub const SIF_TRACKPOS = 0x10;
pub const SIF_ALL = 0x17;
pub const SCROLLINFO = extern struct {
    cbSize: UINT = @sizeOf(SCROLLINFO),
    fMask: UINT = 0,
    nMin: c_int = 0,
    nMax: c_int = 0,
    nPage: UINT = 0,
    nPos: c_int = 0,
    nTrackPos: c_int = 0,
};
pub extern "user32" fn SetScrollInfo(HWND, c_int, *const SCROLLINFO, BOOL) callconv(.winapi) c_int;
pub extern "user32" fn GetScrollInfo(HWND, c_int, *SCROLLINFO) callconv(.winapi) BOOL;
pub const EM_SETCUEBANNER = 0x1501;
pub const EM_LIMITTEXT = 0x00C5;
pub const DT_EXPANDTABS = 0x00000040;
pub const ES_WANTRETURN = 0x1000;
pub const MOVEFILE_REPLACE_EXISTING = 0x1;
pub const MOVEFILE_WRITE_THROUGH = 0x8;
pub extern "kernel32" fn MoveFileExW(LPCWSTR, LPCWSTR, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(HANDLE) callconv(.winapi) BOOL;
pub const TRUNCATE_EXISTING = 5;
pub const ERROR_PATH_NOT_FOUND = 3;
pub const ERROR_SHARING_VIOLATION = 32;
pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};
pub extern "kernel32" fn GetFileInformationByHandle(HANDLE, *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateHardLinkW(LPCWSTR, LPCWSTR, ?*anyopaque) callconv(.winapi) BOOL;
pub const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;
/// Returns a BOOLEAN.
pub extern "kernel32" fn CreateSymbolicLinkW(LPCWSTR, LPCWSTR, DWORD) callconv(.winapi) u8;
/// dwFlags 0: the normalized name with its drive letter (`\\?\C:\...`).
pub extern "kernel32" fn GetFinalPathNameByHandleW(HANDLE, [*]u16, DWORD, DWORD) callconv(.winapi) DWORD;
pub const CC_RGBINIT = 0x1;
pub const CC_FULLOPEN = 0x2;
pub const CHOOSECOLORW = extern struct {
    lStructSize: DWORD = @sizeOf(CHOOSECOLORW),
    hwndOwner: ?HWND = null,
    hInstance: ?HWND = null,
    rgbResult: COLORREF = 0,
    lpCustColors: [*]COLORREF,
    Flags: DWORD = 0,
    lCustData: LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
};
pub extern "comdlg32" fn ChooseColorW(*CHOOSECOLORW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
pub const OFN_FILEMUSTEXIST = 0x00001000;

/// Wide string literal.
pub const L = @import("std").unicode.utf8ToUtf16LeStringLiteral;
