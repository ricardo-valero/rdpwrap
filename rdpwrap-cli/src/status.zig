// status verb — Phase 1 skeleton.
//
// Will print:
//   termsrv.dll version
//   HKLM\SYSTEM\CurrentControlSet\Services\TermService\Parameters\ServiceDll
//   rdpwrap.ini Updated= line (if installed)
//   Whether the running termsrv version has a section in the INI

const Context = @import("main.zig").Context;
const log = @import("log.zig");

pub fn run(ctx: Context) !void {
    log.warn(ctx, "status: not implemented yet (Phase 1 scaffold)", .{});
}
