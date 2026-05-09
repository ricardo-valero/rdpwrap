// Consistent prefixed output for human consumers.
// `[*]` step in progress, `[+]` success, `[-]` error/abort, `[!]` warning.

const std = @import("std");
const Io = std.Io;

const Context = @import("main.zig").Context;

pub fn step(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    write(ctx, "[*] ", fmt, args, false);
}

pub fn ok(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    write(ctx, "[+] ", fmt, args, false);
}

pub fn warn(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    write(ctx, "[!] ", fmt, args, false);
}

pub fn err(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    write(ctx, "[-] ", fmt, args, true);
}

fn write(
    ctx: Context,
    comptime prefix: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    to_stderr: bool,
) void {
    const file = if (to_stderr) Io.File.stderr() else Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    const iw = &w.interface;
    iw.writeAll(prefix) catch return;
    iw.print(fmt, args) catch return;
    iw.writeAll("\n") catch return;
    iw.flush() catch return;
}
