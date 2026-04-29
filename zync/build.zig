const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL 의존성 설정
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zync",
        // 핵심 수정: .root_source_file 대신 .root_module을 사용해야 합니다.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // SDL3 라이브러리 링크
    const sdl_lib = sdl_dep.artifact("SDL3");
    exe.root_module.linkLibrary(sdl_lib);
    exe.root_module.linkSystemLibrary("SDL3_ttf", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
