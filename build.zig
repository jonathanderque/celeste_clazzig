const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const cart_downloader_exe = b.addExecutable(.{
        .name = "cart_downloader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cart_downloader/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const cart_download_run_cmd = b.addRunArtifact(cart_downloader_exe);
    const cart_download_run_step = b.step("download-cart", "Download celeste classic cart");
    cart_download_run_step.dependOn(&cart_download_run_cmd.step);

    var cart_extractor_mod = b.createModule(.{
        .root_source_file = b.path("src/cart_extractor/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cart_extractor_mod.link_libc = true;
    cart_extractor_mod.addIncludePath(b.path("src/cart_extractor/"));
    cart_extractor_mod.addCSourceFile(.{
        .file = b.path("src/cart_extractor/stb_image.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    const cart_extractor = b.addExecutable(.{
        .name = "cart_extractor",
        .root_module = cart_extractor_mod,
    });

    b.installArtifact(cart_extractor);
    const extract_cart = b.addRunArtifact(cart_extractor);

    var libretro_core_mod = b.createModule(.{
        .root_source_file = b.path("src/main_libretro.zig"),
        .target = target,
        .optimize = optimize,
    });
    libretro_core_mod.addIncludePath(b.path("src"));
    const libretro_core = b.addLibrary(.{
        .name = "retro-celeste_clazzig",
        .root_module = libretro_core_mod,
    });
    libretro_core.step.dependOn(&extract_cart.step);
    b.installArtifact(libretro_core);

    const sdl_dep = b.dependency("SDL", .{
        .optimize = optimize,
        .target = target,
    });
    var game_mod = b.createModule(.{
        .root_source_file = b.path("src/main_sdl2.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_mod.linkLibrary(sdl_dep.artifact("SDL2"));
    const game = b.addExecutable(.{
        .name = "celeste_clazzig_sdl2",
        .root_module = game_mod,
    });

    game.step.dependOn(&extract_cart.step);

    b.installArtifact(game);

    const run_cmd = b.addRunArtifact(game);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/num_fixpoint.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests_mod.link_libc = true;
    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
