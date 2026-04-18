const std = @import("std");
const Step = std.Build.Step;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    //// Cart downloader
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

    //// Cart asset extraction
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
        //.flags = &[_][]const u8{},
    });
    const cart_extractor = b.addExecutable(.{
        .name = "cart_extractor",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = cart_extractor_mod,
    });

    b.installArtifact(cart_extractor);
    const extract_cart = b.addRunArtifact(cart_extractor);

    //// Libretro core
    var libretro_core_mod = b.createModule(.{
        .root_source_file = b.path("src/main_libretro.zig"),
        .target = target,
        .optimize = optimize,
    });
    libretro_core_mod.addIncludePath(b.path("src"));
    const libretro_core = b.addLibrary(.{
        .name = "retro-celeste_clazzig",
        .linkage = .dynamic,
        .root_module = libretro_core_mod,
    });
    libretro_core.step.dependOn(&extract_cart.step);
    b.installArtifact(libretro_core);

    //// Game
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
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = game_mod,
    });

    game.step.dependOn(&extract_cart.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(game);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(game);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
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

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
