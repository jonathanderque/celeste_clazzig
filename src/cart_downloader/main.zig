const std = @import("std");
const http = std.http;
const Location = std.http.Client.FetchOptions.Location;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var http_client = http.Client{ .io = init.io, .allocator = allocator };
    defer http_client.deinit();

    const header_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buffer);

    const uri = std.Uri.parse("https://www.lexaloffle.com/bbs/cposts/1/15133.p8.png") catch unreachable;
    const location: Location = Location{ .uri = uri };

    var cart_file = try std.Io.Dir.cwd().createFile(init.io, "src/cart/15133.p8.png", .{});
    defer cart_file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var cart_writer = cart_file.writer(init.io, &buffer);

    const status = try http_client.fetch(.{
        .location = location,
        .method = .GET,
        .response_writer = &cart_writer.interface,
    });

    try cart_writer.end();
    if (status.status != .ok) {
        std.debug.print("could not download cart, aborting.\n", .{});
        std.debug.print("status: {}\n", .{status});
        std.process.exit(1);
    }
}
