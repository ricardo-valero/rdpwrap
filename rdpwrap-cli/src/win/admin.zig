// Token elevation check.

const std = @import("std");
const c = @import("c.zig");

/// Returns true if the current process token is elevated (running as admin).
pub fn isElevated() bool {
    const proc = std.os.windows.GetCurrentProcess();
    var token: c.HANDLE = undefined;
    if (!c.OpenProcessToken(proc, c.TOKEN_QUERY, &token).toBool()) return false;
    defer std.os.windows.CloseHandle(token);

    var elevation: c.TOKEN_ELEVATION = undefined;
    var ret_len: c.DWORD = 0;
    const ok = c.GetTokenInformation(
        token,
        c.TOKEN_INFORMATION_CLASS_TokenElevation,
        &elevation,
        @sizeOf(c.TOKEN_ELEVATION),
        &ret_len,
    );
    if (!ok.toBool()) return false;
    return elevation.TokenIsElevated != 0;
}
