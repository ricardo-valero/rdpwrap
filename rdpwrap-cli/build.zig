const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to cross-compiling for Windows x64. Override via -Dtarget=...
    const default_target = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    };
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // ── rdpwrap-cli.exe ──────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "rdpwrap-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run.step);

    // ── rdpwrap.dll ──────────────────────────────────────────────────────
    // The wrapper DLL svchost loads in place of termsrv.dll. Built for the
    // same target as the CLI; ships in the same release zip.
    const dll = b.addLibrary(.{
        .name = "rdpwrap",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dll_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(dll);

    // ── Tests ────────────────────────────────────────────────────────────
    // Tests run on the host (not the cross-compile target) so we can exercise
    // pure-Zig modules like the INI parser, PE reader, and patcher without
    // Wine. Each module is its own test root so a failure in one doesn't mask
    // another.
    const host_target = b.graph.host;
    const test_step = b.step("test", "Run unit tests on the host");

    const test_modules = [_][]const u8{
        "src/ini.zig",
        "src/pe.zig",
        "src/patcher.zig",
    };
    for (test_modules) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = host_target,
                .optimize = optimize,
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
