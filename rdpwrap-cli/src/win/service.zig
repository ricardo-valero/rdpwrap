// Service control wrappers (advapi32). Stop/start with dependent tracking.

const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    OpenManagerFailed,
    OpenServiceFailed,
    StopFailed,
    StartFailed,
    QueryFailed,
    EnumDependentsFailed,
    Timeout,
    InvalidUtf8,
    OutOfMemory,
};

pub const Status = enum { stopped, start_pending, stop_pending, running, other };

fn statusFromDword(d: c.DWORD) Status {
    return switch (d) {
        c.SERVICE_STOPPED => .stopped,
        c.SERVICE_START_PENDING => .start_pending,
        c.SERVICE_STOP_PENDING => .stop_pending,
        c.SERVICE_RUNNING => .running,
        else => .other,
    };
}

fn openManager() Error!c.SC_HANDLE {
    return c.OpenSCManagerW(null, null, c.SC_MANAGER_ALL_ACCESS) orelse
        return Error.OpenManagerFailed;
}

fn openService(scm: c.SC_HANDLE, name: [:0]const u16, access: c.DWORD) Error!c.SC_HANDLE {
    return c.OpenServiceW(scm, name.ptr, access) orelse Error.OpenServiceFailed;
}

pub fn queryStatus(arena: std.mem.Allocator, name: []const u8) Error!Status {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const scm = try openManager();
    defer _ = c.CloseServiceHandle(scm);
    const svc = try openService(scm, name_w, c.SERVICE_QUERY_STATUS);
    defer _ = c.CloseServiceHandle(svc);

    var ss: c.SERVICE_STATUS = undefined;
    if (!c.QueryServiceStatus(svc, &ss).toBool()) return Error.QueryFailed;
    return statusFromDword(ss.dwCurrentState);
}

/// Stop a service. Caller is responsible for stopping dependents first; use
/// `enumRunningDependents` to discover them.
pub fn stop(arena: std.mem.Allocator, name: []const u8) Error!void {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const scm = try openManager();
    defer _ = c.CloseServiceHandle(scm);
    const svc = try openService(scm, name_w, c.SERVICE_STOP | c.SERVICE_QUERY_STATUS);
    defer _ = c.CloseServiceHandle(svc);

    var ss: c.SERVICE_STATUS = undefined;
    if (!c.QueryServiceStatus(svc, &ss).toBool()) return Error.QueryFailed;
    if (statusFromDword(ss.dwCurrentState) == .stopped) return;

    if (!c.ControlService(svc, c.SERVICE_CONTROL_STOP, &ss).toBool()) return Error.StopFailed;
    try waitFor(svc, .stopped, 30_000);
}

pub fn start(arena: std.mem.Allocator, name: []const u8) Error!void {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const scm = try openManager();
    defer _ = c.CloseServiceHandle(scm);
    const svc = try openService(scm, name_w, c.SERVICE_START | c.SERVICE_QUERY_STATUS);
    defer _ = c.CloseServiceHandle(svc);

    var ss: c.SERVICE_STATUS = undefined;
    if (!c.QueryServiceStatus(svc, &ss).toBool()) return Error.QueryFailed;
    if (statusFromDword(ss.dwCurrentState) == .running) return;

    if (!c.StartServiceW(svc, 0, null).toBool()) {
        // ERROR_SERVICE_ALREADY_RUNNING (1056) is fine.
        const last = std.os.windows.GetLastError();
        if (@intFromEnum(last) != 1056) return Error.StartFailed;
    }
    try waitFor(svc, .running, 30_000);
}

fn waitFor(svc: c.SC_HANDLE, target: Status, timeout_ms: u32) Error!void {
    const poll_interval_ms: u32 = 200;
    const max_iters = (timeout_ms / poll_interval_ms) + 1;
    var ss: c.SERVICE_STATUS = undefined;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        if (!c.QueryServiceStatus(svc, &ss).toBool()) return Error.QueryFailed;
        if (statusFromDword(ss.dwCurrentState) == target) return;
        c.Sleep(poll_interval_ms);
    }
    return Error.Timeout;
}

/// Returns the names (UTF-8, arena-allocated) of services that depend on
/// `name` and are currently running. Useful before stopping the parent.
pub fn enumRunningDependents(
    arena: std.mem.Allocator,
    name: []const u8,
) Error![][]const u8 {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const scm = try openManager();
    defer _ = c.CloseServiceHandle(scm);
    const svc = try openService(scm, name_w, c.SERVICE_ENUMERATE_DEPENDENTS);
    defer _ = c.CloseServiceHandle(svc);

    // Probe required size.
    var bytes_needed: c.DWORD = 0;
    var count: c.DWORD = 0;
    _ = c.EnumDependentServicesW(svc, c.SERVICE_ACTIVE, null, 0, &bytes_needed, &count);
    if (bytes_needed == 0) return &.{};

    const buf = try arena.alignedAlloc(u8, .of(c.ENUM_SERVICE_STATUSW), bytes_needed);
    if (!c.EnumDependentServicesW(
        svc,
        c.SERVICE_ACTIVE,
        @ptrCast(buf.ptr),
        bytes_needed,
        &bytes_needed,
        &count,
    ).toBool()) return Error.EnumDependentsFailed;

    const entries: [*]c.ENUM_SERVICE_STATUSW = @alignCast(@ptrCast(buf.ptr));
    var out = try arena.alloc([]const u8, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name_ptr: [*:0]u16 = entries[i].lpServiceName;
        const wlen = std.mem.indexOfSentinel(u16, 0, name_ptr);
        out[i] = std.unicode.utf16LeToUtf8Alloc(arena, name_ptr[0..wlen]) catch
            return Error.InvalidUtf8;
    }
    return out;
}
