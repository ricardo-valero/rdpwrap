// install verb — Phase 1 skeleton.
//
// Planned flow (mirrors scripts/headless-install/install.ps1):
//   1. Verify running as admin (Win32 token check).
//   2. Add Defender exclusion for the install dir.
//   3. Create install dir; ACL it for Local System + Service group.
//   4. Copy rdpwrap.dll and rdpwrap.ini into the install dir.
//   5. Stop TermService and capture running dependents.
//   6. Set HKLM\...\TermService\Parameters\ServiceDll = install dir DLL path.
//   7. Add firewall rule for TCP/UDP 3389 (initially via netsh; later INetFwPolicy2).
//   8. Start TermService; restart any captured dependents.
//   9. Verify ServiceDll is correctly pointed.

const Context = @import("main.zig").Context;
const log = @import("log.zig");

pub fn run(ctx: Context, args: []const []const u8) !void {
    _ = args;
    log.warn(ctx, "install: not implemented yet (Phase 1 scaffold)", .{});
    log.step(ctx, "planned: drop DLL, point ServiceDll, open firewall, restart TermService", .{});
}
