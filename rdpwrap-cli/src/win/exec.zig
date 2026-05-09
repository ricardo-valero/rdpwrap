// Subprocess helpers — wrappers around std.process.run for tools we shell out
// to (netsh, powershell). Everything goes through a single helper so we have
// one place to add logging or a --dry-run flag later.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    SpawnFailed,
    NonZeroExit,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
) Error!void {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
    }) catch return Error.SpawnFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return Error.NonZeroExit,
        else => return Error.NonZeroExit,
    }
}

/// Convenience: invoke PowerShell with `-NoProfile -Command "<script>"`.
pub fn powershell(
    gpa: std.mem.Allocator,
    io: Io,
    script: []const u8,
) Error!void {
    try run(gpa, io, &.{ "powershell", "-NoProfile", "-Command", script });
}
