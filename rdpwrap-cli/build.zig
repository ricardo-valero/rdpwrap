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

    const exe = b.addExecutable(.{
        .name = "rdpwrap-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Single-binary release: no PDB / no debug info side-files in ReleaseSmall.
    b.installArtifact(exe);

    // `zig build run -- <args>` runs the binary on the host. Useful for the
    // `status`/`help` paths that don't require Windows APIs to behave.
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run.step);
}
