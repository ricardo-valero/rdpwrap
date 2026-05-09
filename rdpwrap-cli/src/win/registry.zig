// Minimal HKLM registry helpers.

const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    OpenFailed,
    SetFailed,
    QueryFailed,
    OutOfMemory,
    InvalidUtf8,
};

/// Set a REG_EXPAND_SZ value under HKLM\<sub_key>. Creates the key if missing.
/// `value_name` must be UTF-8; converted to UTF-16 internally.
pub fn setExpandStringHklm(
    arena: std.mem.Allocator,
    sub_key: []const u8,
    value_name: []const u8,
    value: []const u8,
) Error!void {
    const sub_key_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, sub_key);
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, value_name);
    const val_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, value);

    var hkey: c.HKEY = undefined;
    const create_rc = c.RegCreateKeyExW(
        c.HKEY_LOCAL_MACHINE,
        sub_key_w.ptr,
        0,
        null,
        c.REG_OPTION_NON_VOLATILE,
        c.KEY_SET_VALUE | c.KEY_QUERY_VALUE,
        null,
        &hkey,
        null,
    );
    if (create_rc != c.ERROR_SUCCESS) return Error.OpenFailed;
    defer _ = c.RegCloseKey(hkey);

    // value bytes include the null terminator: (val_w.len + 1) * 2 bytes.
    const cb: c.DWORD = @intCast((val_w.len + 1) * @sizeOf(u16));
    const set_rc = c.RegSetValueExW(
        hkey,
        name_w.ptr,
        0,
        c.REG_EXPAND_SZ,
        @ptrCast(val_w.ptr),
        cb,
    );
    if (set_rc != c.ERROR_SUCCESS) return Error.SetFailed;
}

/// Read a string value (REG_SZ or REG_EXPAND_SZ) from HKLM\<sub_key>.
/// Returns the UTF-8 representation, allocated in `arena`.
pub fn readStringHklm(
    arena: std.mem.Allocator,
    sub_key: []const u8,
    value_name: []const u8,
) Error!?[]u8 {
    const sub_key_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, sub_key);
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, value_name);

    var hkey: c.HKEY = undefined;
    const open_rc = c.RegOpenKeyExW(
        c.HKEY_LOCAL_MACHINE,
        sub_key_w.ptr,
        0,
        c.KEY_QUERY_VALUE,
        &hkey,
    );
    if (open_rc != c.ERROR_SUCCESS) return null;
    defer _ = c.RegCloseKey(hkey);

    var size: c.DWORD = 0;
    var data_type: c.DWORD = 0;
    // Probe for size.
    var rc = c.RegQueryValueExW(hkey, name_w.ptr, null, &data_type, null, &size);
    if (rc != c.ERROR_SUCCESS or size == 0) return null;

    const buf = try arena.alloc(u8, size);
    rc = c.RegQueryValueExW(hkey, name_w.ptr, null, &data_type, buf.ptr, &size);
    if (rc != c.ERROR_SUCCESS) return Error.QueryFailed;

    // Strip trailing null wide char if present.
    var byte_len: usize = size;
    if (byte_len >= 2 and buf[byte_len - 1] == 0 and buf[byte_len - 2] == 0) {
        byte_len -= 2;
    }
    const wide: []align(1) const u16 = @as([*]align(1) const u16, @ptrCast(buf.ptr))[0 .. byte_len / 2];

    // Copy to aligned buffer; utf16LeToUtf8Alloc requires natural u16 alignment.
    const aligned = arena.alloc(u16, wide.len) catch return Error.OutOfMemory;
    @memcpy(aligned, wide);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(arena, aligned) catch return Error.InvalidUtf8;
    return utf8;
}
