// Read termsrv.dll's VS_FIXEDFILEINFO ProductVersion (e.g. "10.0.26100.8328")
// for INI section lookup.
//
// Important: we deliberately read VS_FIXEDFILEINFO (the structured binary
// fields), NOT the StringTable's ProductVersion. The two CAN diverge on
// serviced builds — Microsoft sometimes pins the StringTable to the major
// release name (e.g. "10.0.26100.8115") while bumping VS_FIXEDFILEINFO per
// servicing update (e.g. "10.0.26100.8328"). Community-maintained RDP
// Wrapper INI files key their per-build sections to VS_FIXEDFILEINFO, so
// that's what we have to query to find offsets that match the *actual*
// loaded binary.
//
// File Explorer / Get-Item.VersionInfo.ProductVersion show the StringTable
// value, which is why a casual sanity check ("but the file says 8115!")
// disagrees with what we read here. That's expected.
//
// Layout we use:
//   dwProductVersionMS = (major << 16) | minor
//   dwProductVersionLS = (build << 16) | revision

const std = @import("std");
const c = @import("win/c.zig");

pub const Error = error{
    InfoSizeFailed,
    InfoTooLarge,
    InfoFetchFailed,
    QueryFailed,
    FormatFailed,
};

/// Max size of a typical PE version-info resource. termsrv.dll's is well
/// under this; bump if a future build ever exceeds it.
const VERSION_INFO_MAX: usize = 4096;

/// Returns the 4-part product version of the module at `module_path` (UTF-16,
/// null-terminated), formatted as ASCII into `out_buf` (e.g. "10.0.26100.8328").
pub fn readProductVersion(
    module_path: c.LPCWSTR,
    out_buf: []u8,
) Error![]u8 {
    var dummy_handle: c.DWORD = 0;
    const size = c.GetFileVersionInfoSizeW(module_path, &dummy_handle);
    if (size == 0) return Error.InfoSizeFailed;
    if (size > VERSION_INFO_MAX) return Error.InfoTooLarge;

    var ver_buf: [VERSION_INFO_MAX]u8 = undefined;
    if (c.GetFileVersionInfoW(module_path, 0, size, &ver_buf) == .FALSE)
        return Error.InfoFetchFailed;

    var info_ptr: ?*anyopaque = null;
    var info_len: u32 = 0;
    const root = std.unicode.utf8ToUtf16LeStringLiteral("\\");
    if (c.VerQueryValueW(&ver_buf, root, &info_ptr, &info_len) == .FALSE)
        return Error.QueryFailed;
    if (info_ptr == null or info_len < @sizeOf(c.VS_FIXEDFILEINFO))
        return Error.QueryFailed;

    const ffi: *const c.VS_FIXEDFILEINFO = @ptrCast(@alignCast(info_ptr.?));
    const ms = ffi.dwProductVersionMS;
    const ls = ffi.dwProductVersionLS;
    const major: u16 = @intCast(ms >> 16);
    const minor: u16 = @intCast(ms & 0xFFFF);
    const build: u16 = @intCast(ls >> 16);
    const revision: u16 = @intCast(ls & 0xFFFF);

    return std.fmt.bufPrint(out_buf, "{d}.{d}.{d}.{d}", .{ major, minor, build, revision }) catch
        Error.FormatFailed;
}
