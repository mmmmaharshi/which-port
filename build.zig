//! Builds which-port for every target it ships to, from one host.
//!
//! Exists because the cross-compilation loop was six hand-typed `zig build-exe`
//! invocations, which is exactly the kind of loop that gets retyped slightly
//! differently each release. This is that loop, written once.
//!
//!   zig build                  the binary for this machine
//!   zig build all-targets      every shipped target, into zig-out/release/
//!   zig build test             the five unit suites for this machine
//!
//! Deliberately absent: a `test` target that runs the live round-trips. Those
//! need a real kernel on the machine being tested and a different invocation per
//! platform, which is what scripts/test-all.ps1 is for. Two test entry points
//! would be one too many.

const std = @import("std");

/// Every target a release attaches. musl on both Linux architectures so the
/// binary needs nothing beside it.
const release_targets = [_]Target{
    .{ .name = "x86_64-windows", .os = .windows, .arch = .x86_64 },
    .{ .name = "aarch64-windows", .os = .windows, .arch = .aarch64 },
    .{ .name = "x86_64-linux-musl", .os = .linux, .arch = .x86_64, .abi = .musl },
    .{ .name = "aarch64-linux-musl", .os = .linux, .arch = .aarch64, .abi = .musl },
    .{ .name = "x86_64-macos", .os = .macos, .arch = .x86_64, .buildable = false },
    .{ .name = "aarch64-macos", .os = .macos, .arch = .aarch64, .buildable = false },
};

const Target = struct {
    name: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    abi: ?std.Target.Abi = null,
    /// False while this target cannot compile, which is the case only for macOS
    /// until the lsof lookup lands. Override from the command line to try anyway.
    buildable: bool = true,

    fn query(self: Target) std.Target.Query {
        return .{ .os_tag = self.os, .cpu_arch = self.arch, .abi = self.abi };
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Small, not the default Debug: a user copying one file onto their PATH
    // should not be copying a debug build. ADR 0001 measured this at roughly
    // 490 KB stripped. Zig 0.17 renamed the CLI's ReleaseSmall to `small`; both
    // spellings reach the same enum member and produce byte-identical binaries.
    const release: std.builtin.Optimize = .small;

    const exe = b.addExecutable(.{
        .name = "which-port",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = release,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run which-port").dependOn(&run.step);

    // Declares no new work. It exists to name the host binary's build step, so the
    // suite below can say `zig build test` covers "the binary compiles" too and
    // drop the separate `zig build-exe src/main.zig` invocation. main.zig is
    // reached by no test file, so nothing else in this file compiles it.
    const host = b.step("host", "Build which-port for this machine");
    host.dependOn(b.getInstallStep());

    // One step per shipped target, so `zig build all-targets` is the whole
    // release build and a failure names the target that failed rather than
    // surfacing as one opaque non-zero exit.
    //
    // macOS is skipped rather than failed on. It has no lookup yet, so building
    // it is a compile error that says so -- and a build step that always fails
    // is a build step everyone learns to ignore, which is how the broken WSL path
    // in test-all.ps1 survived. `zig build all-targets` stays green while four of
    // six targets exist, and lights up the moment the sixth does. The ticket that
    // owns the release says six, not the five it says twice.
    const all_step = b.step("all-targets", "Build every shipped target into zig-out/release/");

    for (release_targets) |t| {
        if (!t.buildable) continue;

        const cross = b.addExecutable(.{
            .name = b.fmt("which-port-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query()),
                .optimize = release,
            }),
        });
        // Attached rather than installed: a cross-built binary named for its
        // target lands beside the others, and `zig build` alone still leaves one
        // un-suffixed file for this machine.
        const install = b.addInstallArtifact(cross, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        all_step.dependOn(&install.step);
    }

    // The five unit suites. They are OS-free by construction -- the parsers take
    // captured text and addr takes bytes -- so they run anywhere, which is the
    // point of keeping them separate from the live round-trips.
    //
    // occupier is listed in its own right rather than relied on through lookup.
    // Zig registers a file's tests only when something forces it to be analysed,
    // and lookup.zig refers to every part of occupier.zig from inside function
    // bodies, so `zig test src/lookup.zig` reports zero tests and the Occupier
    // contract would go unverified. The same laziness is what lets the macOS
    // @compileError stay out of the way; it cuts both ways.
    const test_step = b.step("test", "Run the OS-free unit suites");

    for ([_][]const u8{ "addr", "parse_proc", "report", "occupier", "lookup" }) |suite| {
        const tests = b.addTest(.{
            .name = b.fmt("{s}-test", .{suite}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{suite})),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
