// rdpwrap.dll entry point and svchost-facing exports.
//
// svchost loads us via the TermService\Parameters\ServiceDll registry value
// and then calls our ServiceMain. We forward to the real termsrv.dll's
// ServiceMain after one-time initialization.
//
// DllMain stays minimal — only stashing our own HMODULE so the runtime can
// resolve `rdpwrap.ini` next to us. Anything heavier risks loader-lock
// deadlocks; real work happens lazily in runtime.ensureInitialized, triggered
// by the first ServiceMain or SvchostPushServiceGlobals call.

const std = @import("std");
const windows = std.os.windows;

const c = @import("win/c.zig");
const runtime = @import("dll_runtime.zig");

const DLL_PROCESS_ATTACH: windows.DWORD = 1;

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: ?*anyopaque,
) callconv(.winapi) windows.BOOL {
    _ = lpReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        runtime.setSelfModule(@ptrCast(hinstDLL));
    }
    return .TRUE;
}

// ── svchost-facing exports ───────────────────────────────────────────────

pub export fn ServiceMain(
    dwArgc: c.DWORD,
    lpszArgv: ?*anyopaque,
) callconv(.winapi) void {
    runtime.callServiceMain(dwArgc, lpszArgv);
}

pub export fn SvchostPushServiceGlobals(
    lpGlobalData: ?*anyopaque,
) callconv(.winapi) void {
    runtime.callPushServiceGlobals(lpGlobalData);
}
