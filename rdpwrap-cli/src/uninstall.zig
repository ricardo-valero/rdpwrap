// uninstall verb — Windows-only.
//
// Steps:
//   1. Verify running as admin.
//   2. Stop TermService and capture running dependents.
//   3. Reset HKLM\...\TermService\Parameters\ServiceDll back to %SystemRoot%\System32\termsrv.dll.
//   4. Delete %ProgramFiles%\RDP Wrapper\{rdpwrap.dll, rdpwrap.ini}.
//   5. Remove the Defender exclusion.
//   6. Remove the firewall rule unless --keep-firewall.
//   7. Start TermService and dependents.

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
const DEFAULT_SERVICE_DLL = "%SystemRoot%\\System32\\termsrv.dll";

const Args = struct {
    keep_firewall: bool = false,
};

pub fn run(ctx: Context, raw: []const []const u8) !void {
    const args = parseArgs(raw) catch |e| {
        log.err(ctx, "uninstall: {s}", .{@errorName(e)});
        std.process.exit(2);
    };

    if (!admin.isElevated()) {
        log.err(ctx, "uninstall requires elevation. Re-run from an admin shell.", .{});
        std.process.exit(1);
    }

    const program_files = try path.programFiles(ctx.arena, ctx.environ);
    const install_dir = try path.join(ctx.arena, &.{ program_files, "RDP Wrapper" });
    const dll_path = try path.join(ctx.arena, &.{ install_dir, "rdpwrap.dll" });
    const ini_path = try path.join(ctx.arena, &.{ install_dir, "rdpwrap.ini" });

    const dependents = svc.enumRunningDependents(ctx.arena, TERM_SERVICE) catch &.{};
    log.step(ctx, "stopping TermService", .{});
    svc.stop(ctx.arena, TERM_SERVICE) catch |e| {
        log.err(ctx, "stop {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
        std.process.exit(1);
    };

    log.step(ctx, "resetting ServiceDll to default termsrv.dll", .{});
    reg.setExpandStringHklm(ctx.arena, SERVICE_DLL_KEY, "ServiceDll", DEFAULT_SERVICE_DLL) catch |e| {
        log.err(ctx, "registry reset failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    log.step(ctx, "removing files", .{});
    deleteIfExists(ctx, dll_path);
    deleteIfExists(ctx, ini_path);
    std.Io.Dir.cwd().deleteDir(ctx.io, install_dir) catch {}; // best effort

    log.step(ctx, "removing Defender exclusion (best-effort)", .{});
    const defender_script = try std.fmt.allocPrint(
        ctx.arena,
        "Remove-MpPreference -ExclusionPath '{s}' -ErrorAction SilentlyContinue",
        .{install_dir},
    );
    exec.powershell(ctx.gpa, ctx.io, defender_script) catch {};

    if (!args.keep_firewall) {
        log.step(ctx, "removing firewall rule", .{});
        exec.run(ctx.gpa, ctx.io, &.{
            "netsh", "advfirewall", "firewall",
            "delete", "rule",
            "name=Remote Desktop",
        }) catch {};
    }

    log.step(ctx, "starting TermService", .{});
    svc.start(ctx.arena, TERM_SERVICE) catch |e| {
        log.err(ctx, "start {s} failed: {s}", .{ TERM_SERVICE, @errorName(e) });
        std.process.exit(1);
    };
    for (dependents) |d| {
        log.step(ctx, "starting dependent: {s}", .{d});
        svc.start(ctx.arena, d) catch
            log.warn(ctx, "could not restart dependent {s}", .{d});
    }

    log.ok(ctx, "uninstall complete.", .{});
}

fn parseArgs(raw: []const []const u8) !Args {
    var args = Args{};
    for (raw) |a| {
        if (std.mem.eql(u8, a, "--keep-firewall")) {
            args.keep_firewall = true;
        } else {
            return error.UnknownFlag;
        }
    }
    return args;
}

fn deleteIfExists(ctx: Context, p: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, p) catch {};
}
