// update verb — Phase 1 skeleton.

const Context = @import("main.zig").Context;
const log = @import("log.zig");

pub fn run(ctx: Context, args: []const []const u8) !void {
    _ = args;
    log.warn(ctx, "update: not implemented yet (Phase 1 scaffold)", .{});
}
