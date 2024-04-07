const std = @import("std");
const Allocator = std.mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const retro = @cImport({
    @cInclude("libs/libretro.h");
});

const p8 = @import("p8.zig");
const P8API = p8.API;
const celeste = @import("celeste.zig");
const cart_data = @import("generated/celeste.zig");
const font = @import("font.zig").font;
const audio = @import("audio.zig");
const AudioEngine = audio.AudioEngine;

pub fn n(_n: anytype) P8API.num {
    return P8API.num.from_int(_n);
}

pub fn nf(_n: f32) P8API.num {
    return P8API.num.from_float(_n);
}

var log_cb: retro.retro_log_printf_t = std.mem.zeroes(retro.retro_log_printf_t);
var environ_cb: retro.retro_environment_t = std.mem.zeroes(retro.retro_environment_t);
var video_cb: retro.retro_video_refresh_t = std.mem.zeroes(retro.retro_video_refresh_t);
var audio_cb: retro.retro_audio_sample_t = std.mem.zeroes(retro.retro_audio_sample_t);
var audio_batch_cb: retro.retro_audio_sample_batch_t = std.mem.zeroes(retro.retro_audio_sample_batch_t);
var input_poll_cb: retro.retro_input_poll_t = std.mem.zeroes(retro.retro_input_poll_t);
var input_state_cb: retro.retro_input_state_t = std.mem.zeroes(retro.retro_input_state_t);

var logging: retro.struct_retro_log_callback = std.mem.zeroes(retro.struct_retro_log_callback);
//pub extern fn fallback_log(level: retro.enum_retro_log_level, fmt: [*c]const u8, ...) void;
pub extern fn memset(__s: ?*anyopaque, __c: c_int, __n: c_ulong) ?*anyopaque;

const screen_shake_option = "screen_shake";
const global_volume_option = "global_volume_option";

var gpa = GeneralPurposeAllocator(.{}){};

const transparent_pixel: u32 = 0xff000000;
const base_palette = [_]u32{
    0x000000, //
    0x1d2b53,
    0x7e2553,
    0x008751,
    0xab5236,
    0x5f574f,
    0xc2c3c7,
    0xfff1e8,
    0xff004d,
    0xffa300,
    0xffec27,
    0x00e436,
    0x29adff,
    0x83769c,
    0xff77a8,
    0xffccaa,
};

fn load_texture(output: *[]u32, spritesheet: []const u8, width: usize, height: usize, palette: []u32) void {
    _ = width;
    _ = height;

    const transparent = palette[0];
    var i: usize = 0;
    // var x: usize = 0;
    // var y: usize = 0;
    var j: usize = 0;
    while (i < spritesheet.len) : (i += 1) {
        const nibble1 = spritesheet[i] >> 4;
        const nibble2 = spritesheet[i] & 0xf;
        const c1 = palette[nibble1];
        const c2 = palette[nibble2];

        output.*[j] = if (c2 == transparent) transparent_pixel else c2;
        j += 1;
        output.*[j] = if (c1 == transparent) transparent_pixel else c1;
        j += 1;
    }
}

const RetroCeleste = celeste.celeste(p8_api);
const RetroData = struct {
    //gpa: GPA,
    allocator: Allocator,
    palette: [16]u32,
    frame_buffer: []u32,
    gfx_texture: []u32,
    base_font_textures: [16][]u32,
    font_textures: [16][]u32,
    should_reload_gfx_texture: bool,
    // screen shake
    screen_shake: bool,
    camera_x: isize,
    camera_y: isize,
    // input
    button_state: u8,
    previous_button_state: u8,
    // sound
    audio_engine: AudioEngine,
    // misc state
    should_init: bool,
    frame_counter: u8,

    pub fn init(allocator: Allocator) !RetroData {
        const frame_buffer = try allocator.alloc(u32, screen_height * screen_height);
        const gfx_texture = try allocator.alloc(u32, screen_height * screen_height);
        var result: RetroData = RetroData{
            .allocator = allocator,
            .frame_buffer = frame_buffer,
            .gfx_texture = gfx_texture,
            .base_font_textures = undefined,
            .font_textures = undefined,
            .should_reload_gfx_texture = true,
            .palette = undefined,
            .screen_shake = true,
            .camera_x = 0,
            .camera_y = 0,
            .button_state = 0,
            .previous_button_state = 0,
            .audio_engine = AudioEngine.init(),
            .should_init = true,
            .frame_counter = 0,
        };

        // font textures
        result.palette[0] = base_palette[0];
        var i: usize = 0;
        while (i < result.base_font_textures.len) : (i += 1) {
            if (i == 0) {
                // HACK: needed for Old-Site Memorial message:
                // we really want palette[0] here, but black on black does not work
                result.palette[7] = 0x01;
            } else {
                result.palette[7] = base_palette[@mod(i, 16)];
            }
            var font_texture = try allocator.alloc(u32, screen_height * screen_height);
            load_texture(&font_texture, &font, 128, 85, &result.palette);
            result.base_font_textures[i] = font_texture;
        }

        result.audio_engine.set_data(cart_data.music, cart_data.sfx);

        return result;
    }

    pub fn deinit(self: *RetroData) void {
        var i: usize = 0;
        while (i < self.base_font_textures.len) : (i += 1) {
            self.allocator.free(self.base_font_textures[i]);
        }

        self.allocator.free(self.frame_buffer);
        self.allocator.free(self.gfx_texture);
    }

    pub fn reload_textures(self: *RetroData) void {
        if (self.should_reload_gfx_texture) {
            load_texture(&self.gfx_texture, cart_data.gfx[0..], 128, 128, &self.palette);
            self.should_reload_gfx_texture = false;
        }
    }
};

pub export fn retro_api_version() c_uint {
    return retro.RETRO_API_VERSION;
}

pub export fn retro_set_controller_port_device(port: c_uint, device: c_uint) void {
    log_cb.?(retro.RETRO_LOG_INFO, "Plugging device %u into port %u.\n", device, port);
}

pub export fn retro_set_environment(cb: retro.retro_environment_t) void {
    environ_cb = cb;
    var vars = [_]retro.retro_variable{
        retro.retro_variable{ .key = screen_shake_option, .value = "Screen Shake; true|false" },
        retro.retro_variable{ .key = global_volume_option, .value = "Global Volume; 0|1|2|3|4|5|6|7|8|9|10" },
        retro.retro_variable{ .key = null, .value = null },
    };

    _ = cb.?(retro.RETRO_ENVIRONMENT_SET_VARIABLES, @as(?*anyopaque, @ptrCast(&vars)));

    var no_content: bool = true;
    _ = cb.?(retro.RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_content);

    if (cb.?(retro.RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging)) {
        log_cb = logging.log;
    }
}

pub export fn retro_set_video_refresh(cb: retro.retro_video_refresh_t) void {
    video_cb = cb;
}

pub export fn audio_set_state(enable: bool) void {
    _ = enable;
}

pub export fn retro_set_audio_sample(cb: retro.retro_audio_sample_t) void {
    audio_cb = cb;
}

pub export fn retro_set_audio_sample_batch(cb: retro.retro_audio_sample_batch_t) void {
    audio_batch_cb = cb;
}

pub export fn retro_set_input_poll(cb: retro.retro_input_poll_t) void {
    input_poll_cb = cb;
}

pub export fn retro_set_input_state(cb: retro.retro_input_state_t) void {
    input_state_cb = cb;
}

pub export fn retro_get_system_info(info: [*c]retro.struct_retro_system_info) void {
    _ = memset(@as(?*anyopaque, @ptrCast(info)), 0, @sizeOf(retro.struct_retro_system_info));
    info.*.library_name = "Celeste Clazzig";
    info.*.library_version = "v0.1";
    info.*.need_fullpath = false;
    info.*.valid_extensions = null;
}

const screen_width: usize = 128;
const screen_height: usize = 128;
const FPS: usize = 60;

pub export fn retro_get_system_av_info(info: [*c]retro.struct_retro_system_av_info) void {
    info.*.timing = retro.struct_retro_system_timing{
        .fps = @floatFromInt(FPS),
        .sample_rate = audio.SAMPLE_RATE,
    };
    info.*.geometry = retro.struct_retro_game_geometry{
        .base_width = screen_width,
        .base_height = screen_height,
        .max_width = screen_width,
        .max_height = screen_height,
        .aspect_ratio = 1.0,
    };
}

pub export fn retro_reset() void {
    // TODO
}

var retro_data: RetroData = undefined;
pub export fn retro_init() void {
    retro_data = RetroData.init(gpa.allocator()) catch {
        return undefined;
    };
    p8_pal_reset();
}

pub export fn retro_deinit() void {
    retro_data.deinit();
    const leaked = gpa.deinit();
    if (leaked == std.heap.Check.leak) {
        std.log.err("leak detected", .{});
    }
}

pub export fn retro_load_game(info: [*c]const retro.struct_retro_game_info) bool {
    _ = info;
    var fmt: retro.retro_pixel_format = retro.RETRO_PIXEL_FORMAT_XRGB8888;
    if (!environ_cb.?(retro.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt)) {
        log_cb.?(retro.RETRO_LOG_INFO, "XRGB8888 is not supported.\n");
        return false;
    }

    var audio_descr: retro.retro_audio_callback = retro.retro_audio_callback{
        .callback = audio_callback,
        .set_state = audio_set_state,
    };
    if (!environ_cb.?(retro.RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK, @as(?*anyopaque, @ptrCast(&audio_descr)))) {
        log_cb.?(retro.RETRO_LOG_INFO, "error while initiating audio callback\n");
        return false;
    }

    check_variables();

    return true;
}

pub export fn retro_unload_game() void {}

pub export fn retro_load_game_special(@"type": c_uint, info: [*c]const retro.struct_retro_game_info, num: usize) bool {
    _ = info;
    if (@"type" != 0x200)
        return false;
    if (num != 2)
        return false;
    return retro_load_game(null);
}

pub export fn retro_get_region() c_uint {
    return retro.RETRO_REGION_PAL;
}

pub export fn retro_serialize_size() usize {
    return 0;
}

pub export fn retro_serialize(data: ?*anyopaque, size: usize) bool {
    _ = data;
    _ = size;
    return false;
}

pub export fn retro_unserialize(data: ?*const anyopaque, size: usize) bool {
    _ = data;
    _ = size;
    return false;
}

pub export fn retro_cheat_reset() void {}
pub export fn retro_cheat_set(index: c_uint, enabled: bool, code: [*c]const u8) void {
    _ = index;
    _ = enabled;
    _ = code;
}

pub export fn retro_get_memory_data(id: c_uint) ?*anyopaque {
    _ = id;
    return null;
}
pub export fn retro_get_memory_size(id: c_uint) usize {
    _ = id;
    return 0;
}

pub export fn retro_run() void {
    if (retro_data.frame_counter % 2 == 0) {
        retro_data.frame_counter = 0;
        update_input();
        update();
        render();
        retro_data.previous_button_state = retro_data.button_state;
    }
    video_cb.?(@as(?*anyopaque, @ptrCast(retro_data.frame_buffer)), screen_width, screen_height, 0);
    retro_data.frame_counter += 1;

    var updated = false;
    if (environ_cb.?(retro.RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) and updated) {
        check_variables();
    }
}

pub fn update_input() void {
    input_poll_cb.?();

    const one: u8 = 1;
    const key_left: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_LEFT) != 0) (one << p8.k_left.to_int(u3)) else 0;
    const key_right: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_RIGHT) != 0) (one << p8.k_right.to_int(u3)) else 0;
    const key_up: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_UP) != 0) (one << p8.k_up.to_int(u3)) else 0;
    const key_down: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_DOWN) != 0) (one << p8.k_down.to_int(u3)) else 0;
    const key_jump: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_B) != 0) (one << p8.k_jump.to_int(u3)) else 0;
    const key_dash: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_A) != 0) (one << p8.k_dash.to_int(u3)) else 0;
    const key_menu: u8 = if (input_state_cb.?(0, retro.RETRO_DEVICE_JOYPAD, 0, retro.RETRO_DEVICE_ID_JOYPAD_START) != 0) (one << p8.k_menu.to_int(u3)) else 0;

    retro_data.button_state = key_left | key_right | key_up | key_down | key_up | key_jump | key_dash | key_menu;
}

pub fn update() void {
    if (retro_data.should_init) {
        retro_data.should_init = false;
        RetroCeleste._init();
    }
    RetroCeleste._update();
}

pub fn render() void {
    RetroCeleste._draw();
}

pub fn check_variables() void {
    var core_var = retro.retro_variable{
        .key = screen_shake_option,
        .value = null,
    };
    if (environ_cb.?(retro.RETRO_ENVIRONMENT_GET_VARIABLE, &core_var)) {
        retro_data.screen_shake = (core_var.value[0] == 't');
        if (retro_data.screen_shake == false) {
            retro_data.camera_x = 0;
            retro_data.camera_y = 0;
        }
    }

    core_var.key = global_volume_option;
    core_var.value = null;
    if (environ_cb.?(retro.RETRO_ENVIRONMENT_GET_VARIABLE, &core_var)) {
        const val: []const u8 = std.mem.sliceTo(core_var.value, 0);
        const vol_int: isize = std.fmt.parseInt(isize, val, 10) catch 5;
        if (vol_int >= 0 and vol_int <= 10) {
            retro_data.audio_engine.global_volume = @as(usize, @intCast(vol_int)) * 10;
        }
    }
}

pub fn audio_callback() callconv(.C) void {
    var i: usize = 0;
    const len: usize = audio.SAMPLE_RATE / FPS;
    while (i < len) : (i += 1) {
        const sample = retro_data.audio_engine.sample();
        const adjusted_sample: i16 = @as(i16, @intFromFloat(sample * 32767));
        audio_cb.?(adjusted_sample, adjusted_sample);
    }
}

fn draw_symbol(symbol: u8, x: c_int, y: c_int, col: usize) void {
    const src_x: usize = @intCast(8 * (symbol % 16));
    const src_y: usize = @intCast(8 * (symbol / 16));
    blit(retro_data.font_textures[col], src_x, src_y, @intCast(x), @intCast(y), 8, 8, false);
}

// Pico8 API
fn p8_btn(button: P8API.num) bool {
    const one: u8 = 1;
    return (retro_data.button_state & (one << button.to_int(u3)) != 0);
}
fn p8_sfx(id: P8API.num) void {
    const sfx_id: usize = id.to_int(usize);
    retro_data.audio_engine.play_sfx(sfx_id);
}

fn p8_music(id: P8API.num, fade: P8API.num, mask: P8API.num) void {
    const music_id: isize = id.to_int(isize);
    retro_data.audio_engine.play_music(music_id, fade.to_int(u32), mask.to_int(u32));
}

fn p8_pal_reset() void {
    var i: usize = 0;
    while (i < retro_data.palette.len) : (i += 1) {
        retro_data.palette[i] = base_palette[i];
        retro_data.font_textures[i] = retro_data.base_font_textures[i];
    }
    retro_data.should_reload_gfx_texture = true;
}

fn p8_pal(x: P8API.num, y: P8API.num) void {
    const xi: usize = x.to_int(usize);
    retro_data.palette[xi] = base_palette[y.to_int(usize)];
    retro_data.font_textures[xi] = retro_data.base_font_textures[y.to_int(usize)];
    retro_data.should_reload_gfx_texture = true;
}

fn p8_camera(x: P8API.num, y: P8API.num) void {
    if (retro_data.screen_shake) {
        retro_data.camera_x = x.to_int(isize);
        retro_data.camera_y = y.to_int(isize);
    }
}

fn p8_print(str: []const u8, x_arg: P8API.num, y_arg: P8API.num, col: P8API.num) void {
    const col_idx: usize = col.mod(P8API.num.from_int(16)).to_int(usize);
    var x: c_int = x_arg.sub(P8API.num.from_int(retro_data.camera_x)).to_int(c_int);
    const y: c_int = y_arg.sub(P8API.num.from_int(retro_data.camera_y)).to_int(c_int);

    for (str) |cconst| {
        var c = cconst;
        c = c & 0x7F;

        draw_symbol(c, x, y, col_idx);

        x = x + 4;
    }
}

fn p8_num_to_screen(x: P8API.num) isize {
    if (x.lt(n(0))) {
        return 0;
    } else if (x.ge(P8API.num.from_int(screen_width))) { // TODO semantically not correct for height
        return screen_width - 1;
    } else {
        return x.floor().to_int(isize);
    }
}

fn p8_set_pixel(x: isize, y: isize, c: u32) void {
    if (x >= 0 and x < screen_width and y >= 0 and y < screen_height) {
        const xi: usize = @intCast(x);
        const yi: usize = @intCast(y);
        retro_data.frame_buffer[xi + yi * screen_width] = c;
    }
}

fn p8_line(x1: P8API.num, y1: P8API.num, x2: P8API.num, y2: P8API.num, col: P8API.num) void {
    const c = retro_data.palette[col.mod(P8API.num.from_int(retro_data.palette.len)).to_int(usize)];

    if (x1.ne(x2)) {
        std.log.err("only vertical lines are supported ({d:6.1},{d:6.1})({d:6.1},{d:6.1})", .{ x1.to_float(f32), y1.to_float(f32), x2.to_float(f32), y2.to_float(f32) });
        return;
    }

    const x: isize = p8_num_to_screen(x1);
    var y: isize = p8_num_to_screen(y1.min(y2));
    const y_max: isize = p8_num_to_screen(y1.max(y2));
    while (y < y_max) : (y += 1) {
        p8_set_pixel(x - retro_data.camera_x, y - retro_data.camera_y, c);
    }
}

fn dim(d1: P8API.num, d2: P8API.num) usize {
    return @intFromFloat(@abs(d2 - d1));
}

fn p8_rectfill(x1: P8API.num, y1: P8API.num, x2: P8API.num, y2: P8API.num, col: P8API.num) void {
    const c = retro_data.palette[col.mod(P8API.num.from_int(retro_data.palette.len)).to_int(usize)];

    var x: isize = x1.to_int(isize);
    const x_max: isize = x2.add(n(1)).to_int(isize);
    const y_max: isize = y2.add(n(1)).to_int(isize);
    while (x < x_max) : (x += 1) {
        var y: isize = y1.to_int(isize);
        while (y < y_max) : (y += 1) {
            p8_set_pixel(x - retro_data.camera_x, y - retro_data.camera_y, c);
        }
    }
}

fn p8_circfill(x: P8API.num, y: P8API.num, r: P8API.num, col: P8API.num) void {
    if (r.le(n(1))) {
        p8_rectfill(x.sub(n(1)), y, x.add(n(1)), y, col);
        p8_rectfill(x, y.sub(n(1)), x, y.add(n(1)), col);
    } else if (r.le(n(2))) {
        p8_rectfill(x.sub(n(2)), y.sub(n(1)), x.add(n(2)), y.add(n(1)), col);
        p8_rectfill(x.sub(n(1)), y.sub(n(2)), x.add(n(1)), y.add(n(2)), col);
    } else if (r.le(n(3))) {
        p8_rectfill(x.sub(n(3)), y.sub(n(1)), x.add(n(3)), y.add(n(1)), col);
        p8_rectfill(x.sub(n(1)), y.sub(n(3)), x.sub(n(1)), y.add(n(3)), col);
        p8_rectfill(x.sub(n(2)), y.sub(n(2)), x.add(n(2)), y.add(n(2)), col);
    }
}

fn blit(texture: []u32, src_x: usize, src_y: usize, dst_x: isize, dst_y: isize, width: usize, height: usize, flip_x: bool) void {
    var x: usize = 0;
    while (x < width) : (x += 1) {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const px_x: isize = if (flip_x)
                dst_x + @as(isize, @intCast(width - x - 1))
            else
                dst_x + @as(isize, @intCast(x));
            const px_y: isize = dst_y + @as(isize, @intCast(y));
            if (px_x >= 0 and px_x < screen_width and px_y >= 0 and px_y < screen_height) {
                const pixel = texture[src_x + x + (src_y + y) * screen_width];
                if (pixel != transparent_pixel) {
                    p8_set_pixel(px_x - retro_data.camera_x, px_y - retro_data.camera_y, pixel);
                }
            }
        }
    }
}

fn p8_spr(sprite: P8API.num, x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, flip_x: bool, flip_y: bool) void {
    _ = w;
    _ = h;
    _ = flip_y;

    retro_data.reload_textures();

    if (sprite.ge(n(0))) {
        const src_x: usize = sprite.mod(n(16)).to_int(usize) * 8;
        const src_y: usize = sprite.divTrunc(n(16)).to_int(usize) * 8;

        blit(retro_data.gfx_texture, src_x, src_y, x.to_int(isize), y.to_int(isize), 8, 8, flip_x);
    }
}

// sprite flags
fn p8_fget(tile: usize, flag: P8API.num) bool {
    const f: u5 = flag.to_int(u5);
    const one: u32 = 1;
    return tile < cart_data.gff.len and (cart_data.gff[tile] & (one << f)) != 0;
}

// map
fn p8_map(cel_x: P8API.num, cel_y: P8API.num, screen_x: P8API.num, screen_y: P8API.num, cel_w: P8API.num, cel_h: P8API.num, mask: P8API.num) void {
    retro_data.reload_textures();

    var x: P8API.num = n(0);
    const map_len = cart_data.map_low.len + cart_data.map_high.len;
    while (x.lt(cel_w)) : (x = x.add(n(1))) {
        var y: P8API.num = n(0);
        while (y.lt(cel_h)) : (y = y.add(n(1))) {
            const tile_index: usize = x.add(cel_x).add(y.add(cel_y).mul(n(128))).to_int(usize);
            if (tile_index < map_len) {
                const idx = @mod(tile_index, map_len);
                const tile: u8 = if (idx < cart_data.map_low.len) cart_data.map_low[idx] else cart_data.map_high[idx - cart_data.map_low.len];
                if (mask.eq(n(0)) or (mask.eq(n(4)) and cart_data.gff[tile] == 4) or p8_fget(tile, if (mask.ne(n(4))) mask.sub(n(1)) else mask)) {
                    const src_x: usize = @intCast(8 * @mod(tile, 16));
                    const src_y: usize = @intCast(8 * @divTrunc(tile, 16));

                    const dst_x: isize = screen_x.add(x.mul(n(8))).to_int(isize);
                    const dst_y: isize = screen_y.add(y.mul(n(8))).to_int(isize);

                    blit(retro_data.gfx_texture, src_x, src_y, dst_x, dst_y, 8, 8, false);
                }
            }
        }
    }
}

fn p8_mget(tx: P8API.num, ty: P8API.num) P8API.tile {
    if (ty.le(n(31))) {
        const idx: usize = tx.add(ty.mul(n(128))).to_int(usize);
        return @intCast(cart_data.map_low[idx]);
    } else {
        const idx: usize = tx.add(ty.sub(n(32)).mul(n(128))).to_int(usize);
        return @intCast(cart_data.map_high[idx]);
    }
}
// math
fn p8_abs(x: P8API.num) P8API.num {
    return x.abs();
}

fn p8_flr(x: P8API.num) P8API.num {
    return x.floor();
}

fn p8_min(n1: P8API.num, n2: P8API.num) P8API.num {
    return n1.min(n2);
}

fn p8_max(n1: P8API.num, n2: P8API.num) P8API.num {
    return n1.max(n2);
}

fn p8_rnd(rnd_max: P8API.num) P8API.num {
    return P8API.num.random(rnd_max);
}

fn p8_sin(x: P8API.num) P8API.num {
    return x.mul(nf(6.2831853071796)).sin().neg(); //https://pico-8.fandom.com/wiki/Math
}

fn p8_cos(x: P8API.num) P8API.num {
    return p8_sin(x.add(nf(0.25))).neg();
}

const p8_api = P8API{
    .btn = p8_btn,
    .sfx = p8_sfx,
    .music = p8_music,
    .pal_reset = p8_pal_reset,
    .pal = p8_pal,
    .camera = p8_camera,
    .print = p8_print,
    .line = p8_line,
    .rectfill = p8_rectfill,
    .circfill = p8_circfill,
    .spr = p8_spr,
    .fget = p8_fget,
    .map = p8_map,
    .mget = p8_mget,
    .abs = p8_abs,
    .flr = p8_flr,
    .min = p8_min,
    .max = p8_max,
    .rnd = p8_rnd,
    .sin = p8_sin,
    .cos = p8_cos,
};
