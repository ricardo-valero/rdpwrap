// pdb-fetch verb — download the PDB matching the live termsrv.dll from
// Microsoft's public symbol server.
//
// Flow:
//   1. Read termsrv.dll, extract CodeView debug info (GUID, age, PDB name).
//   2. Format the symbol server URL.
//   3. HTTPS GET; stream the body directly to the output file (PDBs can be
//      tens of megabytes — buffering in memory is wasteful).
//
// Output path defaults to ".\<pdbname>" (e.g. ".\termsrv.pdb") in the
// invoking process's working directory, override with --out <path>.

const std = @import("std");
const Context = @import("main.zig").Context;
const log = @import("log.zig");

const pe = @import("pe.zig");
const http = @import("http.zig");

const TERMSRV_PATH = "C:\\Windows\\System32\\termsrv.dll";

const Args = struct {
    out: ?[]const u8 = null,
};

pub fn run(ctx: Context, raw: []const []const u8) !void {
    const args = parseArgs(raw) catch |e| {
        log.err(ctx, "pdb-fetch: {s}", .{@errorName(e)});
        log.err(ctx, "usage: pdb-fetch [--out <path>]", .{});
        std.process.exit(2);
    };

    // 1. Read termsrv + extract debug info.
    log.step(ctx, "reading {s}", .{TERMSRV_PATH});
    const debug = (try readTermsrvDebug(ctx)) orelse {
        log.err(ctx, "no CodeView debug entry in termsrv.dll", .{});
        std.process.exit(1);
    };

    var url_buf: [512]u8 = undefined;
    const url = pe.formatSymbolUrl(&url_buf, debug) catch |e| {
        log.err(ctx, "symbol URL format failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    // 2. Decide output path. Default = "<pdbname>" in cwd.
    const out_path = args.out orelse debug.pdb_name;
    log.step(ctx, "fetching {s}", .{url});
    log.step(ctx, "writing  {s}", .{out_path});

    // 3. Stream HTTPS body directly to disk. Sized buffer is reused inside
    // File.Writer; no need to hold the whole PDB in RAM.
    const cwd = std.Io.Dir.cwd();
    var f = cwd.createFile(ctx.io, out_path, .{ .truncate = true }) catch |e| {
        log.err(ctx, "open {s} failed: {s}", .{ out_path, @errorName(e) });
        std.process.exit(1);
    };
    defer f.close(ctx.io);

    var write_buf: [64 * 1024]u8 = undefined;
    var fw = f.writer(ctx.io, &write_buf);

    const status = http.fetch(ctx.gpa, ctx.io, url, &fw.interface) catch |e| {
        log.err(ctx, "fetch failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    fw.interface.flush() catch |e| {
        log.err(ctx, "flush failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    if (status != .ok) {
        log.err(ctx, "HTTP {d}", .{@intFromEnum(status)});
        std.process.exit(1);
    }

    const st = f.stat(ctx.io) catch null;
    if (st) |s| {
        log.ok(ctx, "downloaded {d} bytes", .{s.size});
    } else {
        log.ok(ctx, "downloaded {s}", .{out_path});
    }
}

fn readTermsrvDebug(ctx: Context) !?pe.DebugInfo {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(ctx.io, TERMSRV_PATH, .{});
    defer f.close(ctx.io);

    const st = try f.stat(ctx.io);
    if (st.size > 32 * 1024 * 1024) return error.TermsrvTooLarge;
    const size_usize: usize = @intCast(st.size);
    const data = try ctx.arena.alloc(u8, size_usize);
    var off: u64 = 0;
    while (off < st.size) {
        const n = try f.readPositionalAll(ctx.io, data[off..size_usize], off);
        if (n == 0) break;
        off += n;
    }

    return try pe.parseDebugInfo(data);
}

fn parseArgs(raw: []const []const u8) !Args {
    var args: Args = .{};
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const a = raw[i];
        if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            args.out = raw[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return args;
}
