// install verb — Windows-only.
//
// Mirrors scripts/headless-install/install.ps1. Steps:
//   1. Verify running as admin.
//   2. Validate --dll and --ini files exist.
//   3. Create install dir at %ProgramFiles%\RDP Wrapper.
//   4. Best-effort: add Defender exclusion (powershell subprocess).
//   5. Stop TermService and capture running dependents.
//   6. Copy DLL and INI to install dir.
//   7. Set HKLM\...\TermService\Parameters\ServiceDll to %ProgramFiles%\RDP Wrapper\rdpwrap.dll.
//   8. Add firewall rule for TCP/UDP 3389 unless --no-firewall.
//   9. Start TermService and any captured dependents.
//   10. Verify ServiceDll points to rdpwrap.dll.

const std = @import("std");
const Context = @import("main.zig").Context;
const log = @import("log.zig");

const admin = @import("win/admin.zig");
const reg = @import("win/registry.zig");
const svc = @import("win/service.zig");
const exec = @import("win/exec.zig");
const path = @import("win/path.zig");

const TERM_SERVICE = "TermService";
const SERVICE_DLL_KEY = "SYSTEM\\CurrentControlSet\\Services\\TermService\\Parameters";
const DLL_NAME = "rdpwrap.dll";
const INI_NAME = "rdpwrap.ini";

const Args = struct {
    dll: []const u8,
    ini: []const u8,
    skip_firewall: bool = false,
};

pub fn run(ctx: Context, raw: []const []const u8) !void {
    const args = parseArgs(raw) catch |e| {
        log.err(ctx, "install: {s}", .{@errorName(e)});
        log.err(ctx, "usage: install --dll <path> --ini <path> [--no-firewall]", .{});
        std.process.exit(2);
    };

    if (!admin.isElevated()) {
        log.err(ctx, "install requires elevation. Re-run from an admin shell.", .{});
        std.process.exit(1);
    }

    // Validate input files exist.
    try requireFile(ctx, args.dll);
    try requireFile(ctx, args.ini);

    const program_files = try path.programFiles(ctx.arena, ctx.environ);
    const install_dir = try path.join(ctx.arena, &.{ program_files, "RDP Wrapper" });
    const dll_dest = try path.join(ctx.arena, &.{ install_dir, DLL_NAME });
    const ini_dest = try path.join(ctx.arena, &.{ install_dir, INI_NAME });
    const service_dll_value = try std.fmt.allocPrint(
        ctx.arena,
        "%ProgramFiles%\\RDP Wrapper\\{s}",
        .{DLL_NAME},
    );

    log.step(ctx, "creating install dir: {s}", .{install_dir});
    std.Io.Dir.cwd().createDirPath(ctx.io, install_dir) catch |e| {
        log.err(ctx, "createDirPath failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    log.step(ctx, "adding Defender exclusion (best-effort)", .{});
    const defender_script = try std.fmt.allocPrint(
        ctx.arena,
        "Add-MpPreference -ExclusionPath '{s}' -ErrorAction SilentlyContinue",
        .{install_dir},
    );
    exec.powershell(ctx.gpa, ctx.io, defender_script) catch
        log.warn(ctx, "Defender exclusion failed; continuing.", .{});

    // Capture dependents BEFORE stopping TermService.
    log.step(ctx, "enumerating TermService dependents", .{});
    const dependents = svc.enumRunningDependents(ctx.arena, TERM_SERVICE) catch |e| blk: {
        log.warn(ctx, "could not enumerate dependents ({s}); continuing", .{@errorName(e)});
        break :blk &.{};
    };
    if (dependents.len > 0) {
        log.step(ctx, "running dependents: {d}", .{dependents.len});
        for (dependents) |d| log.step(ctx, "  - {s}", .{d});
    }

    log.step(ctx, "stopping TermService", .{});
    svc.stop(ctx.arena, TERM_SERVICE) catch |e| {
        log.err(ctx, "stop {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
        std.process.exit(1);
    };

    log.step(ctx, "copying DLL: {s} -> {s}", .{ args.dll, dll_dest });
    try copyFile(ctx, args.dll, dll_dest);
    log.step(ctx, "copying INI: {s} -> {s}", .{ args.ini, ini_dest });
    try copyFile(ctx, args.ini, ini_dest);

    log.step(ctx, "setting ServiceDll = {s}", .{service_dll_value});
    reg.setExpandStringHklm(ctx.arena, SERVICE_DLL_KEY, "ServiceDll", service_dll_value) catch |e| {
        log.err(ctx, "registry write failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    if (!args.skip_firewall) {
        log.step(ctx, "opening firewall for TCP/UDP 3389", .{});
        addFirewallRule(ctx, "TCP") catch log.warn(ctx, "TCP firewall rule failed; continuing", .{});
        addFirewallRule(ctx, "UDP") catch log.warn(ctx, "UDP firewall rule failed; continuing", .{});
    }

    log.step(ctx, "starting TermService", .{});
    svc.start(ctx.arena, TERM_SERVICE) catch |e| {
        log.err(ctx, "start {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
        std.process.exit(1);
    };

    for (dependents) |d| {
        log.step(ctx, "starting dependent: {s}", .{d});
        svc.start(ctx.arena, d) catch
            log.warn(ctx, "could not restart dependent {s}; manual intervention may be needed", .{d});
    }

    // Verify.
    const final = (try reg.readStringHklm(ctx.arena, SERVICE_DLL_KEY, "ServiceDll")) orelse {
        log.err(ctx, "ServiceDll not set after install", .{});
        std.process.exit(1);
    };
    if (std.mem.indexOf(u8, final, DLL_NAME) == null) {
        log.err(ctx, "ServiceDll points to '{s}', not rdpwrap.dll", .{final});
        std.process.exit(1);
    }
    log.ok(ctx, "ServiceDll = {s}", .{final});
    log.ok(ctx, "install complete.", .{});
}

fn parseArgs(raw: []const []const u8) !Args {
    var dll: ?[]const u8 = null;
    var ini: ?[]const u8 = null;
    var skip_firewall = false;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const a = raw[i];
        if (std.mem.eql(u8, a, "--dll")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            dll = raw[i];
        } else if (std.mem.eql(u8, a, "--ini")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            ini = raw[i];
        } else if (std.mem.eql(u8, a, "--no-firewall")) {
            skip_firewall = true;
        } else {
            return error.UnknownFlag;
        }
    }
    return .{
        .dll = dll orelse return error.MissingDll,
        .ini = ini orelse return error.MissingIni,
        .skip_firewall = skip_firewall,
    };
}

fn requireFile(ctx: Context, p: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(ctx.io, p, .{}) catch |e| {
        log.err(ctx, "cannot open {s}: {s}", .{ p, @errorName(e) });
        return e;
    };
    f.close(ctx.io);
}

fn copyFile(ctx: Context, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(src, cwd, dst, ctx.io, .{});
}

fn addFirewallRule(ctx: Context, proto: []const u8) !void {
    const argv = [_][]const u8{
        "netsh", "advfirewall",       "firewall",
        "add",   "rule",
        "name=Remote Desktop",
        "dir=in",
        try std.fmt.allocPrint(ctx.arena, "protocol={s}", .{proto}),
        "localport=3389",
        "profile=any",
        "action=allow",
    };
    try exec.run(ctx.gpa, ctx.io, &argv);
}
