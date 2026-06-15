// Win32 extern declarations and constants we need.
//
// We declare what we use rather than pulling a full bindings crate. Each
// item is annotated with the docs URL for traceability when MS changes
// signatures (rare but happens).

const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const HKEY = *opaque {};
pub const SC_HANDLE = *opaque {};
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const WCHAR = windows.WCHAR;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const LPVOID = ?*anyopaque;
pub const LPDWORD = *DWORD;
pub const PHANDLE = *HANDLE;
pub const PHKEY = *HKEY;
pub const LPBYTE = [*]const u8;

// ── Token elevation ──────────────────────────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken

pub const TOKEN_QUERY: DWORD = 0x0008;

pub const TOKEN_INFORMATION_CLASS_TokenElevation: c_int = 20;

pub const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: DWORD,
};

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: PHANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: LPVOID,
    TokenInformationLength: DWORD,
    ReturnLength: LPDWORD,
) callconv(.winapi) BOOL;

// ── Service control manager ──────────────────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/services/

pub const SC_MANAGER_CONNECT: DWORD = 0x0001;
pub const SC_MANAGER_ALL_ACCESS: DWORD = 0xF003F;

pub const SERVICE_QUERY_STATUS: DWORD = 0x0004;
pub const SERVICE_START: DWORD = 0x0010;
pub const SERVICE_STOP: DWORD = 0x0020;
pub const SERVICE_ENUMERATE_DEPENDENTS: DWORD = 0x0008;
pub const SERVICE_ALL_ACCESS: DWORD = 0xF01FF;

pub const SERVICE_CONTROL_STOP: DWORD = 0x00000001;

pub const SERVICE_STOPPED: DWORD = 0x00000001;
pub const SERVICE_START_PENDING: DWORD = 0x00000002;
pub const SERVICE_STOP_PENDING: DWORD = 0x00000003;
pub const SERVICE_RUNNING: DWORD = 0x00000004;

pub const SERVICE_ACTIVE: DWORD = 0x00000001;
pub const SERVICE_INACTIVE: DWORD = 0x00000002;
pub const SERVICE_STATE_ALL: DWORD = SERVICE_ACTIVE | SERVICE_INACTIVE;

pub const SERVICE_STATUS = extern struct {
    dwServiceType: DWORD,
    dwCurrentState: DWORD,
    dwControlsAccepted: DWORD,
    dwWin32ExitCode: DWORD,
    dwServiceSpecificExitCode: DWORD,
    dwCheckPoint: DWORD,
    dwWaitHint: DWORD,
};

pub const ENUM_SERVICE_STATUSW = extern struct {
    lpServiceName: LPWSTR,
    lpDisplayName: LPWSTR,
    ServiceStatus: SERVICE_STATUS,
};

pub extern "advapi32" fn OpenSCManagerW(
    lpMachineName: ?LPCWSTR,
    lpDatabaseName: ?LPCWSTR,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?SC_HANDLE;

pub extern "advapi32" fn OpenServiceW(
    hSCManager: SC_HANDLE,
    lpServiceName: LPCWSTR,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?SC_HANDLE;

pub extern "advapi32" fn CloseServiceHandle(
    hSCObject: SC_HANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn ControlService(
    hService: SC_HANDLE,
    dwControl: DWORD,
    lpServiceStatus: *SERVICE_STATUS,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn StartServiceW(
    hService: SC_HANDLE,
    dwNumServiceArgs: DWORD,
    lpServiceArgVectors: ?[*]LPCWSTR,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn QueryServiceStatus(
    hService: SC_HANDLE,
    lpServiceStatus: *SERVICE_STATUS,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn EnumDependentServicesW(
    hService: SC_HANDLE,
    dwServiceState: DWORD,
    lpServices: ?*anyopaque,
    cbBufSize: DWORD,
    pcbBytesNeeded: LPDWORD,
    lpServicesReturned: LPDWORD,
) callconv(.winapi) BOOL;

// ── Registry ─────────────────────────────────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/winreg/

pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);

pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_SET_VALUE: DWORD = 0x0002;
pub const KEY_ALL_ACCESS: DWORD = 0xF003F;
pub const KEY_WOW64_64KEY: DWORD = 0x0100;

pub const REG_SZ: DWORD = 1;
pub const REG_EXPAND_SZ: DWORD = 2;
pub const REG_DWORD: DWORD = 4;

pub const REG_OPTION_NON_VOLATILE: DWORD = 0x00000000;

pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    Reserved: DWORD,
    lpClass: ?LPWSTR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: PHKEY,
    lpdwDisposition: ?LPDWORD,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: ?LPCWSTR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: PHKEY,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: ?LPBYTE,
    cbData: DWORD,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    lpReserved: ?LPDWORD,
    lpType: ?LPDWORD,
    lpData: ?[*]u8,
    lpcbData: ?LPDWORD,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

pub const ERROR_SUCCESS: i32 = 0;

// ── Misc kernel32 ────────────────────────────────────────────────────────

pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

// ── Module loading and dynamic resolution ────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/

pub const HMODULE = ?*opaque {};
pub const FARPROC = *const opaque {};

pub extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.winapi) HMODULE;
pub extern "kernel32" fn GetProcAddress(
    hModule: HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?FARPROC;
pub extern "kernel32" fn GetModuleFileNameW(
    hModule: HMODULE,
    lpFilename: LPWSTR,
    nSize: DWORD,
) callconv(.winapi) DWORD;

// ── Memory protection ────────────────────────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect

pub const PAGE_EXECUTE: DWORD = 0x10;
pub const PAGE_EXECUTE_READ: DWORD = 0x20;
pub const PAGE_EXECUTE_READWRITE: DWORD = 0x40;
pub const PAGE_READWRITE: DWORD = 0x04;

pub extern "kernel32" fn VirtualProtect(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    flNewProtect: DWORD,
    lpflOldProtect: LPDWORD,
) callconv(.winapi) BOOL;

// ── File I/O for the rdpwrap.txt log ─────────────────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_END: DWORD = 2;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const INVALID_FILE_SIZE: DWORD = 0xFFFFFFFF;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: LPDWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: LPDWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileSize(
    hFile: HANDLE,
    lpFileSizeHigh: ?LPDWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn SetFilePointer(
    hFile: HANDLE,
    lDistanceToMove: i32,
    lpDistanceToMoveHigh: ?*i32,
    dwMoveMethod: DWORD,
) callconv(.winapi) DWORD;

// ── version.dll: read termsrv.dll ProductVersion ─────────────────────────
// https://learn.microsoft.com/en-us/windows/win32/api/winver/

pub extern "version" fn GetFileVersionInfoSizeW(
    lptstrFilename: LPCWSTR,
    lpdwHandle: ?LPDWORD,
) callconv(.winapi) DWORD;

pub extern "version" fn GetFileVersionInfoW(
    lptstrFilename: LPCWSTR,
    dwHandle: DWORD,
    dwLen: DWORD,
    lpData: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "version" fn VerQueryValueW(
    pBlock: ?*const anyopaque,
    lpSubBlock: LPCWSTR,
    lplpBuffer: *?*anyopaque,
    puLen: *u32,
) callconv(.winapi) BOOL;

pub const VS_FIXEDFILEINFO = extern struct {
    dwSignature: u32,
    dwStrucVersion: u32,
    dwFileVersionMS: u32,
    dwFileVersionLS: u32,
    dwProductVersionMS: u32,
    dwProductVersionLS: u32,
    dwFileFlagsMask: u32,
    dwFileFlags: u32,
    dwFileOS: u32,
    dwFileType: u32,
    dwFileSubtype: u32,
    dwFileDateMS: u32,
    dwFileDateLS: u32,
};
