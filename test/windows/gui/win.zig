//! The Win32 bindings the GUI test harness uses. Self-contained so the
//! harness builds on its own, outside Ghostty's build.

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HWND = *opaque {};
pub const HANDLE = *anyopaque;
pub const HDC = *opaque {};
pub const HGDIOBJ = *anyopaque;
pub const HDESK = *opaque {};
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const FALSE: BOOL = 0;
pub const TRUE: BOOL = 1;

pub const RECT = extern struct { left: c_int = 0, top: c_int = 0, right: c_int = 0, bottom: c_int = 0 };
pub const POINT = extern struct { x: c_int = 0, y: c_int = 0 };
pub const SIZE = extern struct { cx: c_int = 0, cy: c_int = 0 };
pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};
pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = 0, // AC_SRC_OVER
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 1, // AC_SRC_ALPHA
};

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
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: WORD = 1,
    biBitCount: WORD = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

pub const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

// Messages and flags
pub const WM_CLOSE = 0x0010;
pub const WM_QUERYENDSESSION = 0x0011;
pub const WM_ENDSESSION = 0x0016;
pub const ENDSESSION_LOGOFF: isize = 0x80000000;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_COMMAND = 0x0111;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_MOUSEWHEEL = 0x020A;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const BM_CLICK = 0x00F5;
pub const BM_GETCHECK = 0x00F0;
pub const BM_SETCHECK = 0x00F1;
pub const DM_GETDEFID = 0x0400;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_CONTEXTMENU = 0x007B;
pub const SC_KEYMENU = 0xF100;
pub const MK_RBUTTON = 0x0002;
pub const MN_GETHMENU = 0x01E1;
pub const MF_BYPOSITION = 0x0400;
pub const MF_GRAYED = 0x0001;
pub const MF_DISABLED = 0x0002;
pub const MF_POPUP = 0x0010;
pub const MF_SEPARATOR = 0x0800;
pub const HMENU = *opaque {};
pub extern "user32" fn GetMenuItemCount(?HMENU) callconv(.winapi) c_int;
pub extern "user32" fn GetMenuStringW(HMENU, UINT, ?[*]u16, c_int, UINT) callconv(.winapi) c_int;
pub extern "user32" fn GetMenuState(HMENU, UINT, UINT) callconv(.winapi) UINT;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_USER = 0x0400;
pub const WM_ACTIVATE = 0x0006;
pub const WA_INACTIVE = 0;
pub const WM_APP = 0x8000;
pub const TDM_CLICK_BUTTON = WM_USER + 102;
pub const MK_LBUTTON = 0x0001;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCACTIVATE = 0x0086;
pub const HTCLIENT = 1;
pub const HTCAPTION = 2;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTTOP = 12;
pub const HTCLOSE = 20;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub const HTTRANSPARENT: isize = -1;
pub const VK_ESCAPE = 0x1B;
pub const MK_SHIFT = 0x0004;
pub const MK_CONTROL = 0x0008;
pub const MK_MBUTTON = 0x0010;
pub const SMTO_ABORTIFHUNG = 0x0002;
pub const PW_RENDERFULLCONTENT = 0x00000002;
pub const GW_OWNER = 4;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const MAPVK_VK_TO_VSC = 0;
pub const MAPVK_VSC_TO_VK = 1;
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const WS_POPUP = 0x80000000;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_NOACTIVATE = 0x08000000;
pub const SW_SHOWNOACTIVATE = 4;
pub const PM_REMOVE = 0x0001;
pub const ULW_ALPHA = 0x00000002;
pub const SRCCOPY = 0x00CC0020;
pub const CAPTUREBLT = 0x40000000;
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;
pub const DIB_RGB_COLORS = 0;

pub const IDOK = 1;
pub const IDCANCEL = 2;
pub const IDYES = 6;
pub const IDCLOSE = 8;
pub const IDNO = 7;

pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0 = 0;
pub const WAIT_ABANDONED = 0x80;
pub const WAIT_TIMEOUT = 0x102;
pub const STILL_ACTIVE = 259;
pub const GENERIC_READ = 0x80000000;
pub const GENERIC_WRITE = 0x40000000;
pub const GENERIC_ALL = 0x10000000;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const CREATE_ALWAYS = 2;
pub const OPEN_EXISTING = 3;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(~@as(usize, 0));

// Virtual keys
pub const VK_TAB = 0x09;
pub const VK_RETURN = 0x0D;
pub const VK_UP = 0x26;
pub const VK_DOWN = 0x28;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_INSERT = 0x2D;
pub const VK_LEFT = 0x25;
pub const VK_SPACE = 0x20;
pub const VK_F2 = 0x71;
pub const VK_F3 = 0x72;
pub const VK_F4 = 0x73;
pub const VK_F5 = 0x74;
pub const VK_F6 = 0x75;
pub const VK_F7 = 0x76;
pub const VK_F8 = 0x77;
pub const VK_F9 = 0x78;
pub const VK_F11 = 0x7A;
pub const VK_F12 = 0x7B;
pub const WM_SETTEXT = 0x000C;
pub const LB_SETCURSEL = 0x0186;
pub const LB_GETCURSEL = 0x0188;
pub const LB_GETCOUNT = 0x018B;
pub const WM_GETTEXT = 0x000D;
pub const EM_GETSEL = 0x00B0;
pub const VK_OEM_COMMA = 0xBC;
pub const VK_LSHIFT = 0xA0;
pub const VK_LCONTROL = 0xA2;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_NUMLOCK = 0x90;

// kernel32
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
pub extern "kernel32" fn ExitProcess(UINT) callconv(.winapi) noreturn;
pub extern "kernel32" fn CreateProcessW(
    ?LPCWSTR,
    ?LPWSTR,
    ?*anyopaque,
    ?*anyopaque,
    BOOL,
    DWORD,
    ?*anyopaque,
    ?LPCWSTR,
    // A STARTUPINFOEXW's StartupInfo with EXTENDED_STARTUPINFO_PRESENT.
    *STARTUPINFOW,
    *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque = null,
};
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, DWORD, DWORD, *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, DWORD, usize, *const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateMutexW(?*anyopaque, BOOL, LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, LPCWSTR) callconv(.winapi) ?HANDLE;
pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: DWORD = @sizeOf(PROCESS_MEMORY_COUNTERS),
    PageFaultCount: DWORD = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    /// Private committed bytes.
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};
pub extern "kernel32" fn K32GetProcessMemoryInfo(HANDLE, *PROCESS_MEMORY_COUNTERS, DWORD) callconv(.winapi) BOOL;
pub const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: usize = 0,
    AllocationBase: usize = 0,
    AllocationProtect: DWORD = 0,
    RegionSize: usize = 0,
    State: DWORD = 0,
    Protect: DWORD = 0,
    Type: DWORD = 0,
};
pub const MEM_COMMIT = 0x1000;
pub const MEM_FREE = 0x10000;
pub const MEM_PRIVATE = 0x20000;
pub extern "kernel32" fn VirtualQueryEx(HANDLE, usize, *MEMORY_BASIC_INFORMATION, usize) callconv(.winapi) usize;
pub extern "kernel32" fn ReleaseMutex(HANDLE) callconv(.winapi) BOOL;
pub const THREAD_START_ROUTINE = *const fn (?*anyopaque) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateThread(?*anyopaque, usize, THREAD_START_ROUTINE, ?*anyopaque, DWORD, ?*DWORD) callconv(.winapi) ?HANDLE;
pub const STARTF_USEPOSITION = 0x00000004;
pub const STARTF_USESTDHANDLES = 0x00000100;
pub const STARTF_TITLEISLINKNAME = 0x00000800;
pub extern "kernel32" fn GetEnvironmentVariableW(LPCWSTR, ?[*]u16, DWORD) callconv(.winapi) DWORD;
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = FALSE,
};
pub extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePipe(*HANDLE, *HANDLE, ?*SECURITY_ATTRIBUTES, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn PeekNamedPipe(HANDLE, ?[*]u8, DWORD, ?*DWORD, ?*DWORD, ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(HANDLE, DWORD, DWORD) callconv(.winapi) BOOL;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub extern "kernel32" fn TerminateProcess(HANDLE, UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
// The single instance's pipe (roadmap 5.1).
pub const PROCESS_TERMINATE = 0x0001;
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const SYNCHRONIZE = 0x00100000;
pub extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
pub const PIPE_READMODE_MESSAGE = 0x00000002;
pub extern "kernel32" fn SetNamedPipeHandleState(HANDLE, ?*DWORD, ?*DWORD, ?*DWORD) callconv(.winapi) BOOL;
pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const PIPE_TYPE_MESSAGE = 0x00000004;
pub extern "kernel32" fn CreateNamedPipeW(LPCWSTR, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, ?*const SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(LPCWSTR, DWORD, *?*anyopaque, ?*u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryFullProcessImageNameW(HANDLE, DWORD, [*]u16, *DWORD) callconv(.winapi) BOOL;
// Global key bindings (roadmap 5.5).
pub const WM_HOTKEY = 0x0312;
pub const WM_INPUTLANGCHANGE = 0x0051;
pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub extern "user32" fn RegisterHotKey(?HWND, c_int, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(?HWND, c_int) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW([*]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTempPathW(DWORD, [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateDirectoryW(LPCWSTR, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn RemoveDirectoryW(LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(LPCWSTR) callconv(.winapi) BOOL;

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_WRITE = 0x20006;
pub const REG_SZ = 1;
pub const REG_OPTION_VOLATILE = 1;
pub extern "advapi32" fn RegDeleteKeyValueW(HKEY, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) c_long;
pub extern "advapi32" fn RegCreateKeyExW(HKEY, LPCWSTR, DWORD, ?LPWSTR, DWORD, DWORD, ?*anyopaque, *HKEY, ?*DWORD) callconv(.winapi) c_long;
pub extern "advapi32" fn RegSetValueExW(HKEY, ?LPCWSTR, DWORD, DWORD, [*]const u8, DWORD) callconv(.winapi) c_long;
pub extern "advapi32" fn RegCloseKey(HKEY) callconv(.winapi) c_long;
pub extern "advapi32" fn RegDeleteTreeW(HKEY, ?LPCWSTR) callconv(.winapi) c_long;
pub extern "kernel32" fn CreateFileW(LPCWSTR, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSize(HANDLE, ?*DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
pub extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalSize(HANDLE) callconv(.winapi) usize;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileAttributesW(LPCWSTR) callconv(.winapi) DWORD;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };
pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
pub extern "kernel32" fn FindFirstFileW(LPCWSTR, *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(HANDLE, *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(HANDLE) callconv(.winapi) BOOL;
/// SYMBOL_INFOW with room for a 256-character name; SizeOfStruct is the C
/// struct's size (88), not this one's.
pub const SYMBOL_INFOW = extern struct {
    SizeOfStruct: u32 = 88,
    TypeIndex: u32 = 0,
    Reserved: [2]u64 = .{ 0, 0 },
    Index: u32 = 0,
    Size: u32 = 0,
    ModBase: u64 = 0,
    Flags: u32 = 0,
    Value: u64 = 0,
    Address: u64 = 0,
    Register: u32 = 0,
    Scope: u32 = 0,
    Tag: u32 = 0,
    NameLen: u32 = 0,
    MaxNameLen: u32 = 256,
    Name: [256]u16 = @splat(0),
};
pub const SYMOPT_UNDNAME = 0x00000002;
pub const SYMOPT_DEFERRED_LOADS = 0x00000004;
pub extern "dbghelp" fn SymSetOptions(DWORD) callconv(.winapi) DWORD;
pub extern "dbghelp" fn SymInitializeW(HANDLE, ?LPCWSTR, BOOL) callconv(.winapi) BOOL;
pub extern "dbghelp" fn SymLoadModuleExW(HANDLE, ?HANDLE, LPCWSTR, ?LPCWSTR, u64, DWORD, ?*anyopaque, DWORD) callconv(.winapi) u64;
pub extern "dbghelp" fn SymFromAddrW(HANDLE, u64, ?*u64, *SYMBOL_INFOW) callconv(.winapi) BOOL;
pub extern "dbghelp" fn SymCleanup(HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn SystemParametersInfoW(UINT, UINT, ?*anyopaque, UINT) callconv(.winapi) BOOL;
pub const SPI_GETWHEELSCROLLLINES = 0x0068;
pub const WHEEL_PAGESCROLL = 0xFFFFFFFF;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
pub extern "user32" fn SetDoubleClickTime(UINT) callconv(.winapi) BOOL;
pub extern "version" fn GetFileVersionInfoSizeW(LPCWSTR, ?*DWORD) callconv(.winapi) DWORD;
pub extern "version" fn GetFileVersionInfoW(LPCWSTR, DWORD, DWORD, *anyopaque) callconv(.winapi) BOOL;
pub extern "version" fn VerQueryValueW(*const anyopaque, LPCWSTR, *?*anyopaque, *UINT) callconv(.winapi) BOOL;
pub const VS_FIXEDFILEINFO = extern struct {
    dwSignature: DWORD,
    dwStrucVersion: DWORD,
    dwFileVersionMS: DWORD,
    dwFileVersionLS: DWORD,
    dwProductVersionMS: DWORD,
    dwProductVersionLS: DWORD,
    dwFileFlagsMask: DWORD,
    dwFileFlags: DWORD,
    dwFileOS: DWORD,
    dwFileType: DWORD,
    dwFileSubtype: DWORD,
    dwFileDateMS: DWORD,
    dwFileDateLS: DWORD,
};

// shell32
pub extern "shell32" fn CommandLineToArgvW(LPCWSTR, *c_int) callconv(.winapi) ?[*]LPWSTR;
pub const SHCNE_ASSOCCHANGED = 0x08000000;
pub extern "shell32" fn SHChangeNotify(c_long, UINT, ?*const anyopaque, ?*const anyopaque) callconv(.winapi) void;

// user32
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
pub extern "user32" fn EnumWindows(WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn EnumChildWindows(?HWND, WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.winapi) DWORD;
pub const GUITHREADINFO = extern struct {
    cbSize: DWORD = @sizeOf(GUITHREADINFO),
    flags: DWORD = 0,
    hwndActive: ?HWND = null,
    hwndFocus: ?HWND = null,
    hwndCapture: ?HWND = null,
    hwndMenuOwner: ?HWND = null,
    hwndMoveSize: ?HWND = null,
    hwndCaret: ?HWND = null,
    rcCaret: RECT = .{},
};
pub extern "user32" fn GetGUIThreadInfo(DWORD, *GUITHREADINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetClassNameW(HWND, [*]u16, c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextW(HWND, [*]u16, c_int) callconv(.winapi) c_int;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowEnabled(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageTimeoutW(HWND, UINT, WPARAM, LPARAM, UINT, UINT, ?*usize) callconv(.winapi) LRESULT;
pub extern "user32" fn FindWindowExW(?HWND, ?HWND, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) ?HWND;
pub extern "user32" fn RegisterWindowMessageW(LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn AttachThreadInput(DWORD, DWORD, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn SetKeyboardState(*const [256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};
pub const MONITOR_DEFAULTTONEAREST = 2;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(*anyopaque, *MONITORINFO) callconv(.winapi) BOOL;
pub const MONITOR_DEFAULTTOPRIMARY = 1;
pub extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn LoadLibraryW(LPCWSTR) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "user32" fn GetParent(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetDlgItem(?HWND, c_int) callconv(.winapi) ?HWND;
pub extern "user32" fn GetClassLongPtrW(HWND, c_int) callconv(.winapi) usize;
pub const GCL_STYLE = -26;
pub const CS_DBLCLKS = 0x0008;
pub extern "user32" fn ChildWindowFromPointEx(HWND, POINT, UINT) callconv(.winapi) ?HWND;
pub const CWP_SKIPINVISIBLE = 0x0001;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn PrintWindow(HWND, HDC, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn GetSystemMetricsForDpi(c_int, UINT) callconv(.winapi) c_int;
pub const SM_CXICON = 11;
pub const SM_CXSMICON = 49;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MapWindowPoints(?HWND, ?HWND, [*]POINT, UINT) callconv(.winapi) c_int;
pub extern "user32" fn CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, c_int, c_int, c_int, c_int, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub const SW_MINIMIZE = 6;
pub const SW_MAXIMIZE = 3;
pub const SW_RESTORE = 9;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn UpdateLayeredWindow(HWND, ?HDC, ?*const POINT, ?*const SIZE, ?HDC, ?*const POINT, DWORD, ?*const BLENDFUNCTION, DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindow(HWND, UINT) callconv(.winapi) ?HWND;
pub extern "user32" fn CreateDesktopW(LPCWSTR, ?LPCWSTR, ?*anyopaque, DWORD, DWORD, ?*anyopaque) callconv(.winapi) ?HDESK;
pub extern "user32" fn SetThreadDesktop(HDESK) callconv(.winapi) BOOL;
pub extern "user32" fn GetThreadDesktop(DWORD) callconv(.winapi) ?HDESK;
pub extern "user32" fn CloseDesktop(HDESK) callconv(.winapi) BOOL;
pub const DESKTOP_READOBJECTS = 0x0001;
pub const UOI_NAME = 2;
pub extern "user32" fn OpenInputDesktop(DWORD, BOOL, DWORD) callconv(.winapi) ?HDESK;
pub extern "user32" fn GetUserObjectInformationW(HANDLE, c_int, ?*anyopaque, DWORD, ?*DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn EnumClipboardFormats(UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) DWORD;
pub extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn GetClipboardFormatNameW(UINT, [*]u16, c_int) callconv(.winapi) c_int;

// dwmapi
pub extern "dwmapi" fn DwmGetCompositionTimingInfo(?HWND, *anyopaque) callconv(.winapi) c_long;
pub extern "dwmapi" fn DwmGetWindowAttribute(HWND, DWORD, *anyopaque, DWORD) callconv(.winapi) c_long;
pub const DWMWA_CLOAKED = 14;
pub const DWMWA_EXTENDED_FRAME_BOUNDS = 9;
pub extern "user32" fn WindowFromPoint(POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(HWND, UINT) callconv(.winapi) ?HWND;
pub const GA_ROOT = 2;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn BringWindowToTop(HWND) callconv(.winapi) BOOL;
pub const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: DWORD = @sizeOf(OSVERSIONINFOW),
    dwMajorVersion: DWORD = 0,
    dwMinorVersion: DWORD = 0,
    dwBuildNumber: DWORD = 0,
    dwPlatformId: DWORD = 0,
    szCSDVersion: [128]u16 = @splat(0),
};
pub extern "ntdll" fn RtlGetVersion(*OSVERSIONINFOW) callconv(.winapi) c_long;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
pub const GWL_EXSTYLE = -20;

// gdi32
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFOHEADER, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, ?HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;

/// A UTF-16 string literal.
pub fn L(comptime s: []const u8) LPCWSTR {
    return @import("std").unicode.utf8ToUtf16LeStringLiteral(s);
}

pub inline fn makeLParam(x: c_int, y: c_int) LPARAM {
    const lo: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
    const hi: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
    return @bitCast(@as(usize, (hi << 16) | lo));
}
