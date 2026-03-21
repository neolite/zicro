const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    // Core library module
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Terminal executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    exe_mod.addImport("core", core_mod);

    const exe = b.addExecutable(.{
        .name = "zicro",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zicro editor");
    run_step.dependOn(&run_cmd.step);

    // Core library tests
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{ .root_module = core_test_mod });
    core_tests.linkLibC();
    const run_core_tests = b.addRunArtifact(core_tests);

    // Terminal tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    test_mod.addImport("core", core_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_unit_tests.step);

    // GUI executable (macOS native)
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("gui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("core", core_mod);

    const gui_exe = b.addExecutable(.{
        .name = "zicro-gui",
        .root_module = gui_mod,
    });
    gui_exe.linkLibC();
    gui_exe.linkFramework("Cocoa");
    gui_exe.linkFramework("CoreGraphics");

    b.installArtifact(gui_exe);

    const run_gui_cmd = b.addRunArtifact(gui_exe);
    if (b.args) |args| {
        run_gui_cmd.addArgs(args);
    }
    const run_gui_step = b.step("run-gui", "Run zicro GUI demo");
    run_gui_step.dependOn(&run_gui_cmd.step);

    // SDL2 GUI window (real window)
    const gui_window_mod = b.createModule(.{
        .root_source_file = b.path("gui/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_window_mod.addImport("core", core_mod);

    const gui_window_exe = b.addExecutable(.{
        .name = "zicro-gui-window",
        .root_module = gui_window_mod,
    });
    gui_window_exe.linkLibC();
    gui_window_exe.linkSystemLibrary("SDL2");

    b.installArtifact(gui_window_exe);

    const run_gui_window_cmd = b.addRunArtifact(gui_window_exe);
    if (b.args) |args| {
        run_gui_window_cmd.addArgs(args);
    }
    const run_gui_window_step = b.step("run-gui-window", "Run zicro GUI window (SDL2)");
    run_gui_window_step.dependOn(&run_gui_window_cmd.step);
}
