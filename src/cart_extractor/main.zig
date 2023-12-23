const std = @import("std");
const stbi = @cImport({
    @cDefine("STBI_ONLY_PNG", "");
    @cInclude("stb_image.h");
});
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;

pub fn extract(allocator: Allocator, path: []const u8, w: Writer) !void {
    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const image_path = try std.fs.realpath(path, &path_buffer);
    const image_file = try std.fs.openFileAbsolute(image_path, .{});
    defer image_file.close();

    const stats = try image_file.stat();
    const file_content = try image_file.readToEndAlloc(allocator, stats.size);
    defer allocator.free(file_content);
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    //const img_data = stbi.stbi_load(@ptrCast(path), &width, &height, &channels, 0);
    const img_data = stbi.stbi_load_from_memory(@ptrCast(file_content), @intCast(file_content.len), &width, &height, &channels, 0);
    const raw = img_data[0..@intCast(width * height * channels)];

    var rom = ArrayList(u8).init(allocator);
    defer rom.deinit();
    var i: usize = 0;
    while (i < raw.len) : (i += @intCast(channels)) {
        const r: u8 = raw[i + 0];
        const b: u8 = raw[i + 1];
        const g: u8 = raw[i + 2];
        const a: u8 = raw[i + 3];

        const pico_byte =
            (a & 0x3) << 6 | (r & 0x3) << 4 | (b & 0x3) << 2 | (g & 0x3) << 0;
        try rom.append(pico_byte);
    }

    try w.writeAll("//\n// Warning: this file is auto-generated.\n//\n\n");

    try w.writeAll("pub const rom = [_]u8{\n");
    i = 0;
    for (rom.items) |b| {
        try w.print("0x{x:0>2}, ", .{b});
        i += 1;
        if (@mod(i, 128) == 0) {
            try w.writeAll("\n");
            i = 0;
        }
    }
    try w.writeAll("};\n\n");
    try w.writeAll("pub const gfx = rom[0 .. 0x2000];\n");
    try w.writeAll("pub const map_low = rom[0x2000 .. 0x3000];\n");
    try w.writeAll("pub const map_high = rom[0x1000 .. 0x2000];\n");
    try w.writeAll("pub const gff = rom[0x3000 .. 0x3100];\n");
    try w.writeAll("pub const music = rom[0x3100 .. 0x3200];\n");
    try w.writeAll("pub const sfx = rom[0x3200 .. 0x4300];\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == std.heap.Check.leak) {
            std.log.err("leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    var out_file = try std.fs.cwd().createFile("src/generated/celeste.zig", .{ .read = true });
    defer out_file.close();

    const cart_path = "src/cart/15133.p8.png";

    try extract(allocator, cart_path, out_file.writer());
}
