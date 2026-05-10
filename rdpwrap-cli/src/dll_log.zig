// Append-only log to C:\rdpwrap.txt (or whatever the INI's [Main].LogFile
// resolves to). Best-effort — the DLL must not bring down svchost if logging
// fails, so every error path is silenced.
//
// We can't use any allocator here (DllMain context, before/around svchost
// service start). Everything is fixed-size buffers on the stack.

const std = @import("std");
const c = @import("win/c.zig");

/// Path the log gets written to. Set once at first ServiceMain via `setPath`.
/// Defaults to `\rdpwrap.txt` (root of the system drive) — same default the
/// upstream Fusix DLL uses if [Main].LogFile is missing.
var path_buf: [260]u16 = init_path: {
    var buf: [260]u16 = undefined;
    const default = "\\rdpwrap.txt";
    var i: usize = 0;
    while (i < default.len) : (i += 1) buf[i] = default[i];
    buf[default.len] = 0;
    break :init_path buf;
};

/// Override the log path. `utf8_path` is e.g. the value of [Main].LogFile from
/// the INI. No-op if the path doesn't fit (260 wide chars including the null).
pub fn setPath(utf8_path: []const u8) void {
    if (utf8_path.len >= path_buf.len - 1) return;
    var i: usize = 0;
    while (i < utf8_path.len) : (i += 1) path_buf[i] = utf8_path[i];
    path_buf[utf8_path.len] = 0;
}

/// Append a line of text to the log file. Adds CRLF (matching the upstream
/// log format). Silently ignores all errors.
pub fn line(text: []const u8) void {
    appendBytes(text);
    appendBytes("\r\n");
}

fn appendBytes(bytes: []const u8) void {
    if (bytes.len == 0) return;

    const handle = c.CreateFileW(
        @ptrCast(&path_buf),
        c.GENERIC_WRITE,
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE,
        null,
        c.OPEN_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return;
    defer std.os.windows.CloseHandle(handle);

    // Seek to end so OPEN_ALWAYS doesn't truncate prior content.
    _ = c.SetFilePointer(handle, 0, null, c.FILE_END);

    var written: c.DWORD = 0;
    _ = c.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
}
