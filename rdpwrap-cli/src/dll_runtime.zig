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
//   6. For each enabled patch, VirtualProtect → write bytes/trampoline →
//      restore protection.
//
// We do all of this exactly once, on the first call into ServiceMain or
// SvchostPushServiceGlobals (whichever happens first). Subsequent calls
// just forward to the captured function pointers.

const std = @import("std");
const c = @import("win/c.zig");
const ini_mod = @import("ini.zig");
const pe = @import("pe.zig");
const patcher = @import("patcher.zig");
const log = @import("dll_log.zig");

// Service entry typedefs.
pub const ServiceMainFn = *const fn (dwArgc: c.DWORD, lpszArgv: ?*anyopaque) callconv(.winapi) void;
pub const PushServiceGlobalsFn = *const fn (lpGlobalData: ?*anyopaque) callconv(.winapi) void;

// ── Process-wide state ───────────────────────────────────────────────────

const State = struct {
    initialized: bool = false,
    real_service_main: ?ServiceMainFn = null,
    real_push_service_globals: ?PushServiceGlobalsFn = null,
};

var state: State = .{};
// Two atomics implement classic double-checked init: `init_done` is the
// fast-path flag; `init_started` ensures only one thread runs initializeOnce.
var init_done: bool = false;
var init_started: u32 = 0;

// ── Public entry points (called from main.zig's exported wrappers) ───────

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

    // CAS to claim the init slot. If another thread won, spin-wait for it.
    if (@cmpxchgStrong(u32, &init_started, 0, 1, .acquire, .monotonic) != null) {
        while (!@atomicLoad(bool, &init_done, .acquire)) std.atomic.spinLoopHint();
        return;
    }

    initializeOnce() catch |e| {
        log.line("rdpwrap: init failed");
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  reason: {s}", .{@errorName(e)}) catch "  reason: <fmt>";
        log.line(msg);
    };
    state.initialized = true;
    @atomicStore(bool, &init_done, true, .release);
}

const InitError = error{
    LoadTermsrvFailed,
    ResolveServiceMainFailed,
    OutOfMemory,
} || pe.Error;

fn initializeOnce() InitError!void {
    log.line("rdpwrap (zig): initializing");

    // 1. LoadLibrary the real termsrv.dll. This maps it into our process.
    const termsrv_name = std.unicode.utf8ToUtf16LeStringLiteral("termsrv.dll");
    const hTermSrv = c.LoadLibraryW(termsrv_name);
    if (hTermSrv == null) return InitError.LoadTermsrvFailed;

    // 2. Resolve real ServiceMain + SvchostPushServiceGlobals.
    const sm_name = "ServiceMain";
    const psg_name = "SvchostPushServiceGlobals";
    const sm = c.GetProcAddress(hTermSrv, @ptrCast(sm_name)) orelse
        return InitError.ResolveServiceMainFailed;
    state.real_service_main = @ptrCast(sm);
    if (c.GetProcAddress(hTermSrv, @ptrCast(psg_name))) |psg| {
        state.real_push_service_globals = @ptrCast(psg);
    }

    log.line("rdpwrap: termsrv.dll loaded and entry points captured");

    // The actual patching pipeline (read INI, read termsrv version, apply
    // offsets, etc.) lands in the next sub-PR. Phase 2c goal is just to
    // prove forwarding works end-to-end without crashing svchost.
    log.line("rdpwrap: forwarding to real ServiceMain (no patches applied yet)");
}
