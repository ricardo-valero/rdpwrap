// update verb — fetch a fresher rdpwrap.ini from a community source.
//
// Flow:
//   1. Verify elevation + that rdpwrap.dll is installed (else: nothing to update).
//   2. Resolve the source URL (--url overrides --from, --from picks from sources[]).
//   3. HTTPS GET via std.http.Client; stream the body into an Allocating writer.
//   4. Sanity-check the body looks like an rdpwrap.ini (contains [Main]).
//   5. Stop TermService so svchost releases its file lock on rdpwrap.ini.
//   6. Write the new content to the install dir.
//   7. Start TermService so the new INI takes effect.

const std = @import("std");
const Context = @import("main.zig").Context;
const log = @import("log.zig");

const admin = @import("win/admin.zig");
const svc = @import("win/service.zig");
const path = @import("win/path.zig");

const TERM_SERVICE = "TermService";
const INI_NAME = "rdpwrap.ini";
const DLL_NAME = "rdpwrap.dll";

const Source = struct {
    name: []const u8,
    url: []const u8,
};

const sources = [_]Source{
    .{
        .name = "sebaxakerhtc",
        .url = "https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini",
    },
    .{
        .name = "asmtron",
        .url = "https://raw.githubusercontent.com/asmtron/rdpwrap/master/res/rdpwrap.ini",
    },
};

const default_source = "sebaxakerhtc";

const Args = struct {
    url: ?[]const u8 = null,
    from: ?[]const u8 = null,
    skip_restart: bool = false,
};

pub fn run(ctx: Context, raw: []const []const u8) !void {
    const args = parseArgs(raw) catch |e| {
        log.err(ctx, "update: {s}", .{@errorName(e)});
        log.err(ctx, "usage: update [--url <url>] [--from <source>] [--no-restart]", .{});
        log.err(ctx, "sources: sebaxakerhtc (default), asmtron", .{});
        std.process.exit(2);
    };

    if (!admin.isElevated()) {
        log.err(ctx, "update requires elevation. Re-run from an admin shell.", .{});
        std.process.exit(1);
    }

    const url = resolveUrl(ctx, args);

    const program_files = try path.programFiles(ctx.arena, ctx.environ);
    const install_dir = try path.join(ctx.arena, &.{ program_files, "RDP Wrapper" });
    const dll_path = try path.join(ctx.arena, &.{ install_dir, DLL_NAME });
    const ini_path = try path.join(ctx.arena, &.{ install_dir, INI_NAME });

    // Refuse to update when rdpwrap isn't installed — there's nothing to
    // update, and writing the INI alone wouldn't activate anything.
    const cwd = std.Io.Dir.cwd();
    if (cwd.openFile(ctx.io, dll_path, .{})) |f| {
        f.close(ctx.io);
    } else |_| {
        log.err(ctx, "rdpwrap.dll not present at {s}", .{install_dir});
        log.err(ctx, "  run `install` first", .{});
        std.process.exit(1);
    }

    log.step(ctx, "fetching {s}", .{url});
    const body = fetch(ctx, url) catch |e| {
        log.err(ctx, "fetch failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    log.step(ctx, "downloaded {d} bytes", .{body.len});

    if (std.mem.indexOf(u8, body, "[Main]") == null) {
        log.err(ctx, "response does not look like rdpwrap.ini ([Main] section missing)", .{});
        std.process.exit(1);
    }

    // On a live system TermService usually has running dependents
    // (UmRdpService, SessionEnv, ...). ControlService(STOP) returns
    // ERROR_DEPENDENT_SERVICES_RUNNING unless we stop them first.
    var dependents: []const []const u8 = &.{};
    if (!args.skip_restart) {
        dependents = svc.enumRunningDependents(ctx.arena, TERM_SERVICE) catch |e| blk: {
            log.warn(ctx, "could not enumerate dependents ({s}); continuing", .{@errorName(e)});
            break :blk &.{};
        };
        for (dependents) |d| {
            log.step(ctx, "stopping dependent: {s}", .{d});
            svc.stop(ctx.arena, d) catch |e|
                log.warn(ctx, "  {s} stop failed: {s}", .{ d, @errorName(e) });
        }

        log.step(ctx, "stopping TermService", .{});
        svc.stop(ctx.arena, TERM_SERVICE) catch |e| {
            log.err(ctx, "stop {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
            std.process.exit(1);
        };
    }

    log.step(ctx, "writing {s}", .{ini_path});
    cwd.writeFile(ctx.io, .{ .sub_path = ini_path, .data = body }) catch |e| {
        log.err(ctx, "write failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    if (!args.skip_restart) {
        log.step(ctx, "starting TermService", .{});
        svc.start(ctx.arena, TERM_SERVICE) catch |e| {
            log.err(ctx, "start {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
            std.process.exit(1);
        };

        for (dependents) |d| {
            log.step(ctx, "starting dependent: {s}", .{d});
            svc.start(ctx.arena, d) catch |e|
                log.warn(ctx, "  {s} start failed: {s}", .{ d, @errorName(e) });
        }
    }

    log.ok(ctx, "update complete", .{});
}

fn resolveUrl(ctx: Context, args: Args) []const u8 {
    if (args.url) |u| return u;
    const name = args.from orelse default_source;
    for (sources) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.url;
    }
    log.err(ctx, "unknown source: {s}", .{name});
    log.err(ctx, "known sources: sebaxakerhtc, asmtron", .{});
    std.process.exit(2);
}

fn fetch(ctx: Context, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{
        .allocator = ctx.gpa,
        .io = ctx.io,
    };
    defer client.deinit();

    const now = std.Io.Timestamp.now(ctx.io, .real);
    try client.ca_bundle.rescan(ctx.gpa, ctx.io, now);

    var alloc_w: std.Io.Writer.Allocating = .init(ctx.arena);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &alloc_w.writer,
    });

    if (result.status != .ok) {
        log.err(ctx, "HTTP {d}", .{@intFromEnum(result.status)});
        return error.HttpNotOk;
    }

    return alloc_w.written();
}

fn parseArgs(raw: []const []const u8) !Args {
    var args: Args = .{};
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const a = raw[i];
        if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            args.url = raw[i];
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            args.from = raw[i];
        } else if (std.mem.eql(u8, a, "--no-restart")) {
            args.skip_restart = true;
        } else {
            return error.UnknownFlag;
        }
    }
    return args;
}
