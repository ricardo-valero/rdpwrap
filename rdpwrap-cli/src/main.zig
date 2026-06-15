// rdpwrap-cli — minimal RDP Wrapper installer.

const std = @import("std");
const Io = std.Io;

const install = @import("install.zig");
const uninstall_mod = @import("uninstall.zig");
const update_mod = @import("update.zig");
const status_mod = @import("status.zig");
const pdb_fetch_mod = @import("pdb_fetch.zig");

const Verb = enum { install, uninstall, update, status, @"pdb-fetch", help };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    var stderr_buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const ew = &stderr.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printUsage(ew);
        std.process.exit(2);
    }

    const verb = parseVerb(args[1]) orelse {
        try ew.print("[-] unknown verb: {s}\n", .{args[1]});
        try printUsage(ew);
        try ew.flush();
        std.process.exit(2);
    };

    const ctx = Context{
        .io = io,
        .arena = arena,
        .gpa = gpa,
        .environ = init.environ_map,
    };
    const rest = args[2..];

    switch (verb) {
        .install => try install.run(ctx, rest),
        .uninstall => try uninstall_mod.run(ctx, rest),
        .update => try update_mod.run(ctx, rest),
        .status => try status_mod.run(ctx),
        .@"pdb-fetch" => try pdb_fetch_mod.run(ctx, rest),
        .help => try printUsage(ew),
    }
    try ew.flush();
}

pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
};

fn parseVerb(s: []const u8) ?Verb {
    const map = .{
        .{ "install", Verb.install },
        .{ "uninstall", Verb.uninstall },
        .{ "update", Verb.update },
        .{ "status", Verb.status },
        .{ "pdb-fetch", Verb.@"pdb-fetch" },
        .{ "help", Verb.help },
        .{ "--help", Verb.help },
        .{ "-h", Verb.help },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return null;
}

fn printUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\rdpwrap-cli - minimal RDP Wrapper installer
        \\
        \\USAGE
        \\  rdpwrap-cli install --dll <path> --ini <path> [--no-firewall]
        \\  rdpwrap-cli uninstall [--keep-firewall]
        \\  rdpwrap-cli update [--url <url>] [--from <source>] [--no-restart]
        \\  rdpwrap-cli status
        \\  rdpwrap-cli pdb-fetch [--out <path>]
        \\  rdpwrap-cli help
        \\
        \\Update sources:
        \\  sebaxakerhtc (default), asmtron
        \\
        \\Defaults:
        \\  install dir = %ProgramFiles%\RDP Wrapper
        \\
    );
}
