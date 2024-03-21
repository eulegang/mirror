const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("mirror", .{
        .root_source_file = .{ .path = "src/mirror.zig" },
    });

    const lib = b.addStaticLibrary(.{
        .name = "mirror",
        .root_source_file = .{ .path = "src/mirror.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    b.installArtifact(lib);

    const lib_unit_tests_libc = b.addTest(.{
        .root_source_file = .{ .path = "src/mirror.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib_unit_tests_libc.linkLibC();

    const lib_unit_tests_os = b.addTest(.{
        .root_source_file = .{ .path = "src/mirror.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib_unit_tests_libc.linkLibC();

    const run_lib_unit_tests_libc = b.addRunArtifact(lib_unit_tests_libc);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests_os);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests_libc.step);
    test_step.dependOn(&run_lib_unit_tests.step);
}
