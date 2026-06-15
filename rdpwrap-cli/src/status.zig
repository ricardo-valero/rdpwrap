// status verb — read-only sanity check.
//
// Prints:
//   * termsrv.dll's VS_FIXEDFILEINFO ProductVersion (what the wrapper uses
//     for INI section lookup)
//   * TermService state (running / stopped / ...)
//   * HKLM\...\TermService\Parameters\ServiceDll value (wrapper hooked or not)
//   * Install dir contents (rdpwrap.dll / rdpwrap.ini presence)
//   * rdpwrap.ini [Main].Updated date
//   * Whether the INI has a section for the running termsrv version
//
// Doesn't require elevation — everything here is read-only. If a value
// can't be obtained, the line just says so rather than aborting.

const std = @import("std");
const Context = @import("main.zig").Context;
const log = @import("log.zig");

const reg = @import("win/registry.zig");
const svc = @import("win/service.zig");
const path = @import("win/path.zig");
const ver = @import("dll_version.zig");
const ini_mod = @import("ini.zig");

const TERM_SERVICE = "TermService";
const SERVICE_DLL_KEY = "SYSTEM\\CurrentControlSet\\Services\\TermService\\Parameters";
const TERMSRV_PATH = "C:\\Windows\\System32\\termsrv.dll";
const DLL_NAME = "rdpwrap.dll";
const INI_NAME = "rdpwrap.ini";

pub fn run(ctx: Context) !void {
    const program_files = try path.programFiles(ctx.arena, ctx.environ);
    const install_dir = try path.join(ctx.arena, &.{ program_files, "RDP Wrapper" });
    const dll_path = try path.join(ctx.arena, &.{ install_dir, DLL_NAME });
    const ini_path = try path.join(ctx.arena, &.{ install_dir, INI_NAME });

    // ── termsrv ──────────────────────────────────────────────────────────
    log.step(ctx, "termsrv.dll", .{});
    var ver_buf: [32]u8 = undefined;
    const termsrv_w = std.unicode.utf8ToUtf16LeAllocZ(ctx.arena, TERMSRV_PATH) catch null;
    const ts_version: []const u8 = if (termsrv_w) |w|
        (ver.readProductVersion(w.ptr, &ver_buf) catch "<failed>")
    else
        "<utf16-conv-failed>";
    log.step(ctx, "  ProductVersion (VS_FIXEDFILEINFO): {s}", .{ts_version});

    const ts_status = svc.queryStatus(ctx.arena, TERM_SERVICE) catch .other;
    log.step(ctx, "  TermService state: {s}", .{@tagName(ts_status)});

    // ── registry ─────────────────────────────────────────────────────────
    log.step(ctx, "registry HKLM\\{s}", .{SERVICE_DLL_KEY});
    const service_dll_raw = reg.readStringHklm(ctx.arena, SERVICE_DLL_KEY, "ServiceDll") catch null;
    const service_dll = (service_dll_raw orelse null) orelse "<not set>";
    log.step(ctx, "  ServiceDll = {s}", .{service_dll});
    const wrapper_active = std.mem.indexOf(u8, service_dll, "rdpwrap") != null;
    log.step(ctx, "  wrapper: {s}", .{if (wrapper_active) "active" else "inactive"});

    // ── install dir ──────────────────────────────────────────────────────
    log.step(ctx, "install dir: {s}", .{install_dir});
    const dll_present = fileExists(ctx, dll_path);
    const ini_present = fileExists(ctx, ini_path);
    log.step(ctx, "  rdpwrap.dll: {s}", .{if (dll_present) "present" else "MISSING"});
    log.step(ctx, "  rdpwrap.ini: {s}", .{if (ini_present) "present" else "MISSING"});

    // ── INI metadata ─────────────────────────────────────────────────────
    if (ini_present) {
        if (readIniMeta(ctx, ini_path, ts_version)) |meta| {
            log.step(ctx, "  ini [Main].Updated = {s}", .{meta.updated orelse "<not set>"});
            log.step(ctx, "  ini section for {s}: {s}", .{
                ts_version,
                if (meta.has_section) "found" else "MISSING (run `update`)",
            });
        } else |e| {
            log.warn(ctx, "  ini parse failed: {s}", .{@errorName(e)});
        }
    }
}

const IniMeta = struct {
    updated: ?[]const u8,
    has_section: bool,
};

fn readIniMeta(ctx: Context, ini_path: []const u8, ts_version: []const u8) !IniMeta {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(ctx.io, ini_path, .{});
    defer f.close(ctx.io);

    // The INI cap of 5 MB is way bigger than any real rdpwrap.ini.
    const st = try f.stat(ctx.io);
    if (st.size > 5 * 1024 * 1024) return error.IniTooLarge;
    const size_usize: usize = @intCast(st.size);
    const data = try ctx.arena.alloc(u8, size_usize);
    var off: u64 = 0;
    while (off < st.size) {
        const n = try f.readPositionalAll(ctx.io, data[off..size_usize], off);
        if (n == 0) break;
        off += n;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    var ini = try ini_mod.parse(arena_state.allocator(), data);

    var updated: ?[]const u8 = null;
    if (try ini.getValue("Main", "Updated", .any, arena_state.allocator())) |v| {
        updated = try ctx.arena.dupe(u8, v);
    }

    return .{
        .updated = updated,
        .has_section = ini.hasSection(ts_version),
    };
}

fn fileExists(ctx: Context, p: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openFile(ctx.io, p, .{})) |f| {
        f.close(ctx.io);
        return true;
    } else |_| {
        return false;
    }
}
