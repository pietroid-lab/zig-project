const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mbrcli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Executa o interpretador MBR");
    run_step.dependOn(&run_cmd.step);

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mbr.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/validation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_validation_tests = b.addRunArtifact(validation_tests);

    const test_step = b.step("test", "Executa os testes automatizados");
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_validation_tests.step);
}
