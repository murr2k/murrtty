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
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_COMMAND = 0x0111;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_USER = 0x0400;
pub const TDM_CLICK_BUTTON = WM_USER + 102;
pub const MK_LBUTTON = 0x0001;
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
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;
pub const DIB_RGB_COLORS = 0;

pub const IDOK = 1;
pub const IDCANCEL = 2;
pub const IDYES = 6;
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
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_INSERT = 0x2D;
pub const VK_F4 = 0x73;
pub const VK_OEM_COMMA = 0xBC;
pub const VK_LSHIFT = 0xA0;
pub const VK_LCONTROL = 0xA2;
pub const VK_LMENU = 0xA4;

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
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateMutexW(?*anyopaque, BOOL, LPCWSTR) callconv(.winapi) ?HANDLE;
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
pub extern "kernel32" fn TerminateProcess(HANDLE, UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
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

// shell32
pub extern "shell32" fn CommandLineToArgvW(LPCWSTR, *c_int) callconv(.winapi) ?[*]LPWSTR;
pub const SHCNE_ASSOCCHANGED = 0x08000000;
pub extern "shell32" fn SHChangeNotify(c_long, UINT, ?*const anyopaque, ?*const anyopaque) callconv(.winapi) void;

// user32
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
pub extern "user32" fn EnumWindows(WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn EnumChildWindows(?HWND, WNDENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.winapi) DWORD;
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
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn PrintWindow(HWND, HDC, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
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

// gdi32
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFOHEADER, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;

/// A UTF-16 string literal.
pub fn L(comptime s: []const u8) LPCWSTR {
    return @import("std").unicode.utf8ToUtf16LeStringLiteral(s);
}

pub inline fn makeLParam(x: c_int, y: c_int) LPARAM {
    const lo: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
    const hi: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
    return @bitCast(@as(usize, (hi << 16) | lo));
}
