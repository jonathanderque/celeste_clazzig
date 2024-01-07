const std = @import("std");
const Step = std.Build.Step;

pub fn download_carts(step: *Step, prog_node: *std.Progress.Node) !void {
    _ = step;
    _ = prog_node;

    const http = std.http;

    // find a way to reuse b.allocator instead?
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    // TODO: generate file!

    var http_client = http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var http_headers = std.http.Headers{ .allocator = allocator };
    defer http_headers.deinit();
    try http_headers.append("accept", "*/*");

    const uri = std.Uri.parse("https://www.lexaloffle.com/bbs/cposts/1/15133.p8.png") catch unreachable;

    var http_request = try http_client.request(.GET, uri, http_headers, .{});
    defer http_request.deinit();

    try http_request.start();
    try http_request.wait();

    const cart = try http_request.reader().readAllAlloc(allocator, 48 * 1024);
    defer allocator.free(cart);

    var cart_file = try std.fs.cwd().createFile("src/cart/15133.p8.png", .{ .read = true });
    defer cart_file.close();

    try cart_file.writeAll(cart);
}

pub fn create_cart_download_step(b: *std.build.Builder) *Step {
    const self = b.allocator.create(Step) catch @panic("OOM");
    self.* = Step.init(.{
        .id = Step.Id.custom,
        .owner = b,
        .name = "download carts",
        .makeFn = download_carts,
    });
    return self;
}

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

    //// Cart download
    var cart_download_step = create_cart_download_step(b);
    const cart_download_run_step = b.step("download-cart", "Download celeste classic cart");
    cart_download_run_step.dependOn(cart_download_step);

    //// Cart asset extraction
    const cart_extractor = b.addExecutable(.{
        .name = "cart_extractor",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/cart_extractor/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    cart_extractor.linkLibC();

    cart_extractor.addIncludePath(.{ .path = "src/cart_extractor/" });
    cart_extractor.addCSourceFile(.{
        .file = .{ .path = "src/cart_extractor/stb_image.c" },
        .flags = &[_][]const u8{"-std=c99"},
        //.flags = &[_][]const u8{},
    });

    b.installArtifact(cart_extractor);
    const extract_cart = b.addRunArtifact(cart_extractor);

    //// Game
    const game = b.addExecutable(.{
        .name = "celeste_clazzig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    game.linkSystemLibrary("SDL2");

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
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
