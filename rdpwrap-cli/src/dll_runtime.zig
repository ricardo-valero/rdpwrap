// First-call orchestration for the wrapped svchost service entrypoints.
//
// `ServiceMain` and `SvchostPushServiceGlobals` are both forwarders. Before
// either touches termsrv.dll, the wrapper must:
//
//   1. LoadLibrary the real termsrv.dll (this maps it into the process).
//   2. GetProcAddress the real ServiceMain + SvchostPushServiceGlobals.
//   3. Read rdpwrap.ini from the install dir.
//   4. Read the loaded termsrv.dll's ProductVersion.
//   5. Find the matching INI section.
//   6. For each enabled patch, VirtualProtect → write bytes → restore.
//
// Steps 1–2 are mandatory: without them we have nothing to forward to and
// svchost crashes. Steps 3–6 are best-effort — if the INI is missing or the
// build is unknown, we still forward, just without any patches applied.
//
// We do all of this exactly once, on the first call into ServiceMain or
// SvchostPushServiceGlobals (whichever happens first). Subsequent calls just
// forward to the captured function pointers.

const std = @import("std");
const c = @import("win/c.zig");
const ini_mod = @import("ini.zig");
const pe = @import("pe.zig");
const patcher = @import("patcher.zig");
const log = @import("dll_log.zig");
const dll_version = @import("dll_version.zig");
const dll_patch = @import("dll_patch.zig");
const dll_hooks = @import("dll_hooks.zig");

// Service entry typedefs.
pub const ServiceMainFn = *const fn (dwArgc: c.DWORD, lpszArgv: ?*anyopaque) callconv(.winapi) void;
pub const PushServiceGlobalsFn = *const fn (lpGlobalData: ?*anyopaque) callconv(.winapi) void;

// ── Process-wide state ───────────────────────────────────────────────────

const State = struct {
    initialized: bool = false,
    self_module: c.HMODULE = null,
    termsrv_module: c.HMODULE = null,
    real_service_main: ?ServiceMainFn = null,
    real_push_service_globals: ?PushServiceGlobalsFn = null,
};

var state: State = .{};
// Two atomics implement classic double-checked init: `init_done` is the
// fast-path flag; `init_started` ensures only one thread runs initializeOnce.
var init_done: bool = false;
var init_started: u32 = 0;

// ── Public entry points ──────────────────────────────────────────────────

pub fn setSelfModule(h: c.HMODULE) void {
    state.self_module = h;
}

pub fn callServiceMain(argc: c.DWORD, argv: ?*anyopaque) void {
    ensureInitialized();
    if (state.real_service_main) |fp| fp(argc, argv);
}

pub fn callPushServiceGlobals(lpGlobalData: ?*anyopaque) void {
    ensureInitialized();
    if (state.real_push_service_globals) |fp| fp(lpGlobalData);
}

// ── Initialization ───────────────────────────────────────────────────────

fn ensureInitialized() void {
    if (@atomicLoad(bool, &init_done, .acquire)) return;

    if (@cmpxchgStrong(u32, &init_started, 0, 1, .acquire, .monotonic) != null) {
        while (!@atomicLoad(bool, &init_done, .acquire)) std.atomic.spinLoopHint();
        return;
    }

    loadTermsrv() catch |e| {
        logError("init: load termsrv failed", e);
        @atomicStore(bool, &init_done, true, .release);
        return;
    };

    // Patching is best-effort — forwarding stays alive even if any of this
    // fails. We log the reason and continue.
    applyPatches() catch |e| {
        logError("init: patching skipped", e);
    };

    state.initialized = true;
    @atomicStore(bool, &init_done, true, .release);
}

const LoadError = error{
    LoadTermsrvFailed,
    ResolveServiceMainFailed,
};

fn loadTermsrv() LoadError!void {
    log.line("rdpwrap (zig): initializing");

    const termsrv_name = std.unicode.utf8ToUtf16LeStringLiteral("termsrv.dll");
    const hTermSrv = c.LoadLibraryW(termsrv_name);
    if (hTermSrv == null) return LoadError.LoadTermsrvFailed;
    state.termsrv_module = hTermSrv;

    const sm = c.GetProcAddress(hTermSrv, "ServiceMain") orelse
        return LoadError.ResolveServiceMainFailed;
    state.real_service_main = @ptrCast(sm);

    if (c.GetProcAddress(hTermSrv, "SvchostPushServiceGlobals")) |psg| {
        state.real_push_service_globals = @ptrCast(psg);
    }

    log.line("rdpwrap: termsrv.dll loaded and entry points captured");
}

const PatchError = error{
    TermsrvHandleMissing,
    SelfHandleMissing,
    GetTermsrvPathFailed,
    GetSelfPathFailed,
    PathTooLong,
    NoBackslash,
    OpenIniFailed,
    ReadIniFailed,
    IniFileTooLarge,
    PeParseFailed,
    NoSectionForVersion,
    OutOfMemory,
} || dll_version.Error;

fn applyPatches() PatchError!void {
    const hTermSrv = state.termsrv_module orelse return PatchError.TermsrvHandleMissing;
    const self_h = state.self_module orelse return PatchError.SelfHandleMissing;

    // termsrv.dll path → version.
    var termsrv_path: [260]u16 = undefined;
    const tn = c.GetModuleFileNameW(hTermSrv, @ptrCast(&termsrv_path), termsrv_path.len);
    if (tn == 0 or tn >= termsrv_path.len) return PatchError.GetTermsrvPathFailed;
    termsrv_path[tn] = 0;

    var version_buf: [32]u8 = undefined;
    const version = try dll_version.readProductVersion(@ptrCast(&termsrv_path), &version_buf);
    {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  termsrv.dll version: {s}", .{version}) catch "  termsrv version: ?";
        log.line(msg);
    }

    // Our own path → INI path.
    var self_path: [260]u16 = undefined;
    const sn = c.GetModuleFileNameW(self_h, @ptrCast(&self_path), self_path.len);
    if (sn == 0 or sn >= self_path.len) return PatchError.GetSelfPathFailed;

    var ini_path: [260]u16 = undefined;
    _ = buildIniPath(self_path[0..sn], &ini_path) catch |e| {
        logError("  build INI path failed", e);
        return PatchError.PathTooLong;
    };

    // PE info from in-memory termsrv (just the headers, first page).
    const base_const: [*]const u8 = @ptrCast(hTermSrv);
    const pe_info = pe.parse(base_const[0..0x1000]) catch {
        return PatchError.PeParseFailed;
    };
    {
        var buf: [120]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  termsrv arch: {s}, size_of_code: {x}, size_of_image: {x}", .{
            @tagName(pe_info.arch), pe_info.size_of_code, pe_info.size_of_image,
        }) catch "  pe info: ?";
        log.line(msg);
    }

    // Read + parse INI.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ini_bytes = readWholeFile(arena, @ptrCast(&ini_path)) catch |e| {
        logError("  read rdpwrap.ini failed", e);
        return PatchError.OpenIniFailed;
    };
    {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  rdpwrap.ini read ({d}b)", .{ini_bytes.len}) catch "  ini read";
        log.line(msg);
    }

    var ini = ini_mod.parse(arena, ini_bytes) catch |e| {
        logError("  parse rdpwrap.ini failed", e);
        return PatchError.ReadIniFailed;
    };
    defer ini.deinit();

    // Section lookup.
    const section = ini.getSection(version) orelse {
        log.line("  no INI section for this termsrv version — skipping patches");
        return PatchError.NoSectionForVersion;
    };

    // Apply.
    const arch: patcher.Arch = switch (pe_info.arch) {
        .x64 => .x64,
        .x86 => .x86,
    };
    const base_mut: [*]u8 = @ptrCast(@constCast(base_const));

    // Populate the SLInit override table *before* the trampoline lands, so
    // the first call into New_CSLQuery_Initialize sees a fully-set table.
    dll_hooks.setupSLInit(&ini, base_mut, pe_info.size_of_image, version, arena) catch |e| {
        logError("  SLInit setup failed", e);
    };

    const stats = dll_patch.applySection(base_mut, pe_info.size_of_code, section, &ini, arch, self_h, arena);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "rdpwrap: patches applied={d} skipped={d} failed={d}", .{
        stats.applied, stats.skipped, stats.failed,
    }) catch "rdpwrap: done";
    log.line(msg);
}

// ── Helpers ──────────────────────────────────────────────────────────────

fn buildIniPath(self_path_w: []const u16, out: []u16) ![]u16 {
    // Find last '\' in the DLL path so we can swap "rdpwrap.dll" → "rdpwrap.ini".
    var i: usize = self_path_w.len;
    while (i > 0) : (i -= 1) {
        if (self_path_w[i - 1] == '\\') break;
    } else return error.NoBackslash;
    const dir_len = i;

    const ini_name = std.unicode.utf8ToUtf16LeStringLiteral("rdpwrap.ini");
    const total = dir_len + ini_name.len;
    if (total + 1 > out.len) return error.PathTooLong;

    @memcpy(out[0..dir_len], self_path_w[0..dir_len]);
    var j: usize = 0;
    while (j < ini_name.len) : (j += 1) out[dir_len + j] = ini_name[j];
    out[total] = 0;
    return out[0..total];
}

fn readWholeFile(alloc: std.mem.Allocator, path_w: c.LPCWSTR) ![]u8 {
    const handle = c.CreateFileW(
        path_w,
        c.GENERIC_READ,
        c.FILE_SHARE_READ,
        null,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return error.OpenIniFailed;
    defer std.os.windows.CloseHandle(handle);

    var size_high: c.DWORD = 0;
    const size_low = c.GetFileSize(handle, &size_high);
    if (size_low == c.INVALID_FILE_SIZE) return error.ReadIniFailed;
    if (size_high != 0) return error.IniFileTooLarge;

    const buf = try alloc.alloc(u8, size_low);
    var bytes_read: c.DWORD = 0;
    if (c.ReadFile(handle, buf.ptr, size_low, &bytes_read, null) == .FALSE)
        return error.ReadIniFailed;
    return buf[0..bytes_read];
}

fn logError(prefix: []const u8, e: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ prefix, @errorName(e) }) catch prefix;
    log.line(msg);
}
