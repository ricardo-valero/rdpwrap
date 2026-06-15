// Hook functions exported from rdpwrap.dll for `<Family>Hook.<arch>` INI
// entries to target via JMP trampoline.
//
// Currently just one hook: `New_CSLQuery_Initialize`, which fully replaces
// termsrv.dll's CSLQuery::Initialize. The original function checks SKU/policy
// fields and decides whether RDP can run; our replacement skips that check
// and just writes the desired values into those fields directly, then
// returns S_OK so termsrv proceeds to bind the listener.
//
// The override table is populated by `setupSLInit` during init (before the
// trampoline is installed), so by the time termsrv first calls
// CSLQuery::Initialize via the trampoline, we already know exactly which
// addresses to write and what values to write.

const std = @import("std");
const c = @import("win/c.zig");
const ini_mod = @import("ini.zig");
const log = @import("dll_log.zig");

const Override = struct {
    ptr: *volatile u32,
    value: u32,
};

const MAX_OVERRIDES = 16;
var overrides: [MAX_OVERRIDES]Override = undefined;
var overrides_count: usize = 0;

/// Field names + default values matching upstream Fusix. Each name is the
/// key in `[<version>-SLInit]` whose value is a hex offset relative to
/// termsrv's base address.
const fields = [_]struct { name: []const u8, default: u32 }{
    .{ .name = "bServerSku", .default = 1 },
    .{ .name = "bRemoteConnAllowed", .default = 1 },
    .{ .name = "bFUSEnabled", .default = 1 },
    .{ .name = "bAppServerAllowed", .default = 1 },
    .{ .name = "bMultimonAllowed", .default = 1 },
    .{ .name = "lMaxUserSessions", .default = 0 },
    .{ .name = "ulMaxDebugSessions", .default = 0 },
    .{ .name = "bInitialized", .default = 1 },
};

/// Walk `[<version>-SLInit]` for field offsets, `[SLInit]` for values, and
/// populate the override table that `New_CSLQuery_Initialize` will consume.
/// No-op when the subsection is absent — the hook stays harmless.
pub fn setupSLInit(
    ini: *const ini_mod.Ini,
    termsrv_base: [*]u8,
    image_size: u32,
    version_str: []const u8,
    arena: std.mem.Allocator,
) !void {
    overrides_count = 0;

    const subsection = try std.mem.concat(arena, u8, &.{ version_str, "-SLInit" });
    if (ini.getSection(subsection) == null) {
        log.line("  no [<version>-SLInit] subsection - SLInit hook will be a no-op");
        return;
    }

    for (fields) |f| {
        const offset_opt = ini.getHex(subsection, f.name, .x64, arena) catch {
            continue;
        };
        const offset = offset_opt orelse continue;
        if (offset + 4 > image_size) continue;

        const value_opt = ini.getHex("SLInit", f.name, .any, arena) catch null;
        const value64 = value_opt orelse f.default;
        const value: u32 = @truncate(value64);

        if (overrides_count >= MAX_OVERRIDES) {
            log.line("  too many SLInit overrides, truncating");
            break;
        }

        const off_usize: usize = @intCast(offset);
        const ptr: *volatile u32 = @ptrCast(@alignCast(termsrv_base + off_usize));
        overrides[overrides_count] = .{ .ptr = ptr, .value = value };
        overrides_count += 1;

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "  SLInit {s} = {d} @ +{x}",
            .{ f.name, value, offset },
        ) catch "  SLInit field";
        log.line(msg);
    }
}

/// Replacement for termsrv.dll's CSLQuery::Initialize. Writes the precomputed
/// override values into the policy struct and returns S_OK. Reached via the
/// JMP trampoline that `dll_patch.applyHookFamily` installs at the original
/// function's entry.
///
/// No allocation, no INI access — everything is precomputed during init.
/// Argument count is intentionally zero: termsrv's CSLQuery::Initialize is a
/// C++ method so it receives `this` in RCX (x64) on entry; we ignore it.
var hook_logged: bool = false;

pub export fn New_CSLQuery_Initialize() callconv(.winapi) u32 {
    if (!hook_logged) {
        hook_logged = true;
        log.line("rdpwrap: New_CSLQuery_Initialize fired");
    }
    var i: usize = 0;
    while (i < overrides_count) : (i += 1) {
        overrides[i].ptr.* = overrides[i].value;
    }
    return 0; // S_OK
}
