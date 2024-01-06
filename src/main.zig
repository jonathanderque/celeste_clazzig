const std = @import("std");
const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});
const Surface = sdl.SDL_Surface;
const Window = sdl.SDL_Window;
const Renderer = sdl.SDL_Renderer;
const Texture = sdl.SDL_Texture;

const cart_data = @import("generated/celeste.zig");
const font = @import("font.zig").font;
const audio = @import("audio.zig");
const AudioEngine = audio.AudioEngine;

const base_palette = [_]sdl.SDL_Color{
    sdl.SDL_Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff }, //
    sdl.SDL_Color{ .r = 0x1d, .g = 0x2b, .b = 0x53, .a = 0xff },
    sdl.SDL_Color{ .r = 0x7e, .g = 0x25, .b = 0x53, .a = 0xff },
    sdl.SDL_Color{ .r = 0x00, .g = 0x87, .b = 0x51, .a = 0xff },
    sdl.SDL_Color{ .r = 0xab, .g = 0x52, .b = 0x36, .a = 0xff },
    sdl.SDL_Color{ .r = 0x5f, .g = 0x57, .b = 0x4f, .a = 0xff },
    sdl.SDL_Color{ .r = 0xc2, .g = 0xc3, .b = 0xc7, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0xf1, .b = 0xe8, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0x00, .b = 0x4d, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0xa3, .b = 0x00, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0xec, .b = 0x27, .a = 0xff },
    sdl.SDL_Color{ .r = 0x00, .g = 0xe4, .b = 0x36, .a = 0xff },
    sdl.SDL_Color{ .r = 0x29, .g = 0xad, .b = 0xff, .a = 0xff },
    sdl.SDL_Color{ .r = 0x83, .g = 0x76, .b = 0x9c, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0x77, .b = 0xa8, .a = 0xff },
    sdl.SDL_Color{ .r = 0xff, .g = 0xcc, .b = 0xaa, .a = 0xff },
};

const FRUIT_COUNT: usize = 30;
var palette: [16]sdl.SDL_Color = undefined;

// SDL globals
var screen: *Window = undefined;
var renderer: *Renderer = undefined;
var gfx_texture: *Texture = undefined;
var font_textures: [16]*Texture = undefined;
var should_reload_gfx_texture: bool = false;

fn load_texture(r: *Renderer, spritesheet: []const u8, width: usize, height: usize) ?*Texture {
    var surface = sdl.SDL_CreateRGBSurface(0, @intCast(width), @intCast(height), 32, 0, 0, 0, 0);
    defer sdl.SDL_FreeSurface(surface);

    const format = surface.*.format;
    const c = base_palette[0];
    const color_key = sdl.SDL_MapRGB(format, c.r, c.g, c.b);
    _ = sdl.SDL_SetColorKey(surface, sdl.SDL_TRUE, color_key);

    var surface_renderer = sdl.SDL_CreateSoftwareRenderer(surface);
    defer sdl.SDL_DestroyRenderer(surface_renderer);

    var i: usize = 0;
    var x: usize = 0;
    var y: usize = 0;
    while (i < spritesheet.len) : (i += 1) {
        const nibble1 = spritesheet[i] >> 4;
        const nibble2 = spritesheet[i] & 0xf;
        const c1 = palette[nibble1];
        const c2 = palette[nibble2];

        if (nibble2 > 0) {
            _ = sdl.SDL_SetRenderDrawColor(surface_renderer, c2.r, c2.g, c2.b, c2.a);
            _ = sdl.SDL_RenderDrawPoint(surface_renderer, @intCast(x), @intCast(y));
        }
        x += 1;
        if (nibble1 > 0) {
            _ = sdl.SDL_SetRenderDrawColor(surface_renderer, c1.r, c1.g, c1.b, c1.a);
            _ = sdl.SDL_RenderDrawPoint(surface_renderer, @intCast(x), @intCast(y));
        }
        x += 1;

        if (x >= width) {
            x = 0;
            y += 1;
        }
    }

    return sdl.SDL_CreateTextureFromSurface(r, surface);
}

fn load_font_textures(r: *Renderer) void {
    var i: usize = 0;
    while (i < font_textures.len) : (i += 1) {
        P8.pal_reset();
        palette[0] = palette[@mod(1 + i, 16)];
        palette[7] = palette[@mod(i, 16)];
        if (load_texture(r, &font, 128, 85)) |texture| {
            font_textures[i] = texture;
        } else {
            sdl.SDL_Log("Unable to create texture from surface: %s", sdl.SDL_GetError());
        }
    }
    P8.pal_reset();
}

fn reload_textures(r: *Renderer) void {
    if (should_reload_gfx_texture) {
        // reload_textures assumes the texture was already loaded; free the previous texture to avoid leaks
        sdl.SDL_DestroyTexture(gfx_texture);
        if (load_texture(r, cart_data.gfx[0..], 128, 128)) |texture| {
            gfx_texture = texture;
        } else {
            sdl.SDL_Log("Unable to create texture from surface: %s", sdl.SDL_GetError());
        }

        should_reload_gfx_texture = false;
    }
}

var button_state: u8 = 0;
var previous_button_state: u8 = 0;

fn released_key(key: P8.num) bool {
    const k: u3 = @intFromFloat(key);
    const mask: u8 = @as(u8, 1) << k;
    return (button_state & mask == 0) and (previous_button_state & mask != 0);
}

fn sdl_first_controller() ?*sdl.SDL_GameController {
    const controller_count = sdl.SDL_NumJoysticks();
    for (0..@intCast(controller_count)) |i| {
        const controller = sdl.SDL_GameControllerOpen(@intCast(i));
        if (controller) |_| {
            return controller;
        }
    }
    return null;
}

var audio_engine = AudioEngine.init();

pub fn sdl_audio_callback(arg_userdata: ?*anyopaque, arg_stream: [*c]u8, arg_len: c_int) callconv(.C) void {
    _ = arg_userdata;
    var stream = arg_stream;
    var len = arg_len;
    var snd: [*c]c_short = @as([*c]c_short, @ptrCast(@alignCast(stream)));
    len = @divTrunc(len, @sizeOf(c_short));

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const volume: f64 = @as(f64, 0.5) / 7;
        const sample = audio_engine.sample();

        snd[i] = @as(c_short, @intFromFloat(sample * volume * 32767));
    }
}

const PauseMenu = struct {
    pause: bool,
    quit: bool,
    option_index: usize,

    fn init() PauseMenu {
        return PauseMenu{
            .pause = false,
            .quit = false,
            .option_index = 0,
        };
    }

    fn toggle_pause(self: *PauseMenu) void {
        self.pause = !self.pause;
        audio_engine.toggle_pause();
        if (self.pause) {
            self.option_index = 0;
        }
    }

    fn update(self: *PauseMenu) void {
        if (!self.pause) {
            return;
        }
        if (released_key(k_up)) {
            if (self.option_index == 0) {
                self.option_index = option_ys.len - 1;
            } else {
                self.option_index -= 1;
            }
        }
        if (released_key(k_down)) {
            self.option_index += 1;
            if (self.option_index >= option_ys.len) {
                self.option_index = 0;
            }
        }
        if (released_key(k_jump) or released_key(k_dash)) {
            switch (self.option_index) {
                0 => {
                    self.toggle_pause();
                },
                1 => {
                    self.quit = true;
                },
                else => unreachable,
            }
        }
    }

    const cursor_symbol = 143;
    const option_ys = [_]u8{ 12, 19 };
    fn draw(self: *PauseMenu) void {
        if (!self.pause) {
            return;
        }

        const title_x = 6;
        const cursor_x = title_x;
        const option_x = title_x + 8;

        P8.rectfill(title_x - 2, 4, 75, 30, 0);
        P8.print("celeste clazzig", title_x, 5, 7);
        P8.print("RESUME", option_x, option_ys[0], 7);
        P8.print("QUIT", option_x, option_ys[1], 7);
        draw_symbol(cursor_symbol, cursor_x, option_ys[self.option_index], 7);
    }
};

var pause_menu = PauseMenu.init();

const ViewPort = struct {
    x: i32,
    y: i32,
    scale: u32,
    window_w: i32,
    window_h: i32,

    fn init() ViewPort {
        return ViewPort{
            .x = 0,
            .y = 0,
            .scale = 1,
            .window_w = 128,
            .window_h = 128,
        };
    }

    fn adjust(self: *ViewPort, window_w: i32, window_h: i32) void {
        self.window_w = window_w;
        self.window_h = window_h;
        const smallest = @min(window_w, window_h);
        if (smallest > 0) {
            self.scale = @divTrunc(@as(u32, @intCast(smallest)), 128);
            self.x = @divTrunc(window_w - @as(i32, @intCast(128 * self.scale)), 2);
            self.y = @divTrunc(window_h - @as(i32, @intCast(128 * self.scale)), 2);
            // std.log.info("view port adjusted to x: {}, y: {}, scale: {} from window w:{}, h:{}", .{ self.x, self.y, self.scale, window_w, window_h });
        }
    }
};

var view_port = ViewPort.init();

fn resize_window_callback() void {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSize(screen, &w, &h);
    view_port.adjust(w, h);
}

fn draw_view_port_borders() void {
    const c = palette[0];
    _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = 0, .w = view_port.x, .h = view_port.window_h });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = view_port.window_w - view_port.x, .y = 0, .w = view_port.x, .h = view_port.window_h });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = 0, .w = view_port.window_h, .h = view_port.y });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = view_port.window_h - view_port.y, .w = view_port.window_h, .h = view_port.y });
}

pub fn main() !void {
    std.debug.print("let's go\n", .{});
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO) != 0) {
        sdl.SDL_Log("Unable to initialize SDL: %s", sdl.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer sdl.SDL_Quit();
    std.debug.print("SDL_Init done\n", .{});

    const window_flags = sdl.SDL_WINDOW_MAXIMIZED | sdl.SDL_WINDOW_RESIZABLE;
    screen = sdl.SDL_CreateWindow("Celeste Clazzig", sdl.SDL_WINDOWPOS_UNDEFINED, sdl.SDL_WINDOWPOS_UNDEFINED, 128, 128, window_flags) orelse {
        sdl.SDL_Log("Unable to create window: %s", sdl.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyWindow(screen);

    renderer = sdl.SDL_CreateRenderer(screen, -1, sdl.SDL_RENDERER_ACCELERATED) orelse {
        sdl.SDL_Log("Unable to create renderer: %s", sdl.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    gfx_texture = load_texture(renderer, cart_data.gfx[0..], 128, 128) orelse {
        sdl.SDL_Log("Unable to create texture from surface: %s", sdl.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyTexture(gfx_texture);

    // Textures
    load_font_textures(renderer);
    defer {
        for (font_textures) |texture| {
            sdl.SDL_DestroyTexture(texture);
        }
    }
    P8.pal_reset();
    reload_textures(renderer);

    resize_window_callback();

    _ = sdl.SDL_InitSubSystem(sdl.SDL_INIT_GAMECONTROLLER);
    var controller: ?*sdl.SDL_GameController = sdl_first_controller();

    var desired_audio_spec: sdl.SDL_AudioSpec = undefined;
    var obtained_audio_spec: sdl.SDL_AudioSpec = undefined;

    desired_audio_spec.freq = audio.SAMPLE_RATE;
    desired_audio_spec.format = sdl.AUDIO_S16SYS;
    desired_audio_spec.channels = 1;
    desired_audio_spec.samples = 2048;
    desired_audio_spec.userdata = null;
    desired_audio_spec.callback = &sdl_audio_callback;

    var audio_device = sdl.SDL_OpenAudioDevice(0, 0, &desired_audio_spec, &obtained_audio_spec, 0);
    defer sdl.SDL_CloseAudioDevice(audio_device);
    if (audio_device == 0) {
        sdl.SDL_Log("Unable to initialize audio: %s", sdl.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    sdl.SDL_PauseAudioDevice(audio_device, 0);
    std.debug.print("opened audio device {}\n", .{audio_device});
    audio_engine.set_data(cart_data.music, cart_data.sfx);

    var should_init = true;

    var nextFrame = sdl.SDL_GetPerformanceCounter();
    var nextSecond = nextFrame;
    var fps: u32 = 0;
    const target_fps = 30;

    while (!pause_menu.quit) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl.SDL_QUIT => {
                    pause_menu.quit = true;
                },
                sdl.SDL_CONTROLLERDEVICEADDED => {
                    controller = sdl_first_controller();
                },
                sdl.SDL_CONTROLLERDEVICEREMOVED => {
                    _ = sdl.SDL_GameControllerClose(controller);
                    controller = null;
                },
                sdl.SDL_WINDOWEVENT => {
                    switch (event.window.event) {
                        sdl.SDL_WINDOWEVENT_RESIZED, sdl.SDL_WINDOWEVENT_SIZE_CHANGED => {
                            resize_window_callback();
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        const current_key_states = sdl.SDL_GetKeyboardState(null);

        button_state = 0;
        var key_left: u8 = if (current_key_states[sdl.SDL_SCANCODE_LEFT] != 0) (1 << k_left) else 0;
        var key_right: u8 = if (current_key_states[sdl.SDL_SCANCODE_RIGHT] != 0) (1 << k_right) else 0;
        var key_up: u8 = if (current_key_states[sdl.SDL_SCANCODE_UP] != 0) (1 << k_up) else 0;
        var key_down: u8 = if (current_key_states[sdl.SDL_SCANCODE_DOWN] != 0) (1 << k_down) else 0;
        var key_jump: u8 = if (current_key_states[sdl.SDL_SCANCODE_Z] != 0) (1 << k_jump) else 0;
        var key_dash: u8 = if (current_key_states[sdl.SDL_SCANCODE_X] != 0) (1 << k_dash) else 0;
        var key_menu: u8 = if (current_key_states[sdl.SDL_SCANCODE_ESCAPE] != 0) (1 << k_menu) else 0;

        if (current_key_states[sdl.SDLK_z] != 0) {
            key_jump = 1 << k_jump;
        }
        if (current_key_states[sdl.SDLK_x] != 0) {
            key_dash = 1 << k_dash;
        }

        if (controller) |_| {
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_LEFT) != 0) {
                key_left = 1 << k_left;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_RIGHT) != 0) {
                key_right = 1 << k_right;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_UP) != 0) {
                key_up = 1 << k_up;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_DOWN) != 0) {
                key_down = 1 << k_down;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_A) != 0) {
                key_jump = 1 << k_jump;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_B) != 0) {
                key_dash = 1 << k_dash;
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_START) != 0) {
                key_menu = 1 << k_menu;
            }
        }

        button_state = key_left | key_right | key_up | key_down | key_up | key_jump | key_dash | key_menu;

        if (sdl.SDL_GetPerformanceCounter() >= nextFrame) {
            while (sdl.SDL_GetPerformanceCounter() >= nextFrame) {
                if (released_key(k_menu)) {
                    pause_menu.toggle_pause();
                }
                // update
                if (should_init) {
                    _init();
                    should_init = false;
                }
                if (pause_menu.pause) {
                    pause_menu.update();
                } else {
                    _update();
                }
                previous_button_state = button_state;
                nextFrame += sdl.SDL_GetPerformanceFrequency() / target_fps;
            }
            fps += 1;
            if (sdl.SDL_GetPerformanceCounter() >= nextSecond) {
                // std.debug.print("fps: {}\n", .{fps});
                fps = 0;
                nextSecond += sdl.SDL_GetPerformanceFrequency();
            }

            if (pause_menu.pause) {
                pause_menu.draw();
            } else {
                _draw();
                draw_view_port_borders();
            }
            sdl.SDL_RenderPresent(renderer);
        } else {
            sdl.SDL_Delay(1);
        }
    }
}

fn draw_symbol(symbol: u8, x: c_int, y: c_int, col: usize) void {
    var src_rect: sdl.SDL_Rect = undefined;
    src_rect.x = @intCast(8 * (symbol % 16));
    src_rect.y = @intCast(8 * (symbol / 16));
    src_rect.w = @intFromFloat(8);
    src_rect.h = @intFromFloat(8);

    var dst_rect: sdl.SDL_Rect = undefined;
    dst_rect.x = x * @as(c_int, @intCast(view_port.scale)) + view_port.x;
    dst_rect.y = y * @as(c_int, @intCast(view_port.scale)) + view_port.y;
    dst_rect.w = @intCast(8 * view_port.scale);
    dst_rect.h = @intCast(8 * view_port.scale);
    _ = sdl.SDL_RenderCopy(renderer, font_textures[col], &src_rect, &dst_rect);
}

const p8tile = i8;
const P8Point = struct {
    x: P8.num,
    y: P8.num,
};
const P8Rect = struct {
    x: P8.num,
    y: P8.num,
    w: P8.num,
    h: P8.num,
};

const P8 = struct {
    const num = f32;
    fn btn(button: num) bool {
        const one: u8 = 1;
        return (button_state & (one << @as(u3, @intFromFloat(button))) != 0);
    }

    fn sfx(id: num) void {
        const sfx_id: usize = @intFromFloat(id);
        audio_engine.play_sfx(sfx_id);
    }

    fn music(id: num, fade: num, mask: num) void {
        const music_id: isize = @intFromFloat(id);
        audio_engine.play_music(music_id, @intFromFloat(fade), @intFromFloat(mask));
    }

    // Lua function pal()
    fn pal_reset() void {
        var i: usize = 0;
        while (i < palette.len) : (i += 1) {
            palette[i] = base_palette[i];
        }
        should_reload_gfx_texture = true;
    }

    fn pal(x: num, y: num) void {
        const xi: usize = @intFromFloat(x);
        palette[xi] = base_palette[@intFromFloat(y)];
        should_reload_gfx_texture = true;
    }

    fn screen_rect(x: num, y: num, w: c_int, h: c_int) sdl.SDL_Rect {
        const scale = @as(c_int, @intCast(view_port.scale));
        var rect: sdl.SDL_Rect = undefined;
        rect.x = @as(c_int, @intFromFloat(x - camera_x)) * scale + view_port.x;
        rect.y = @as(c_int, @intFromFloat(y - camera_y)) * scale + view_port.y;
        rect.w = w * scale;
        rect.h = h * scale;
        //std.log.debug("dest_rect({d:6.1}, {d:6.1}, {}, {}) -> {}", .{ x, y, w, h, rect });
        return rect;
    }

    // sprites
    fn spr(sprite: num, x: num, y: num, w: num, h: num, flip_x: bool, flip_y: bool) void {
        _ = w;
        _ = h;
        _ = flip_y;

        reload_textures(renderer);

        if (sprite >= 0) {
            var src_rect: sdl.SDL_Rect = undefined;
            src_rect.x = @intCast(8 * @as(c_int, @intFromFloat(@mod(sprite, 16))));

            src_rect.y = @intCast(8 * @as(c_int, @intFromFloat(@divTrunc(sprite, 16))));
            src_rect.w = @intCast(8);
            src_rect.h = @intCast(8);

            const dst_rect = screen_rect(x, y, 8, 8);

            var flip: c_uint = 0;
            if (flip_x) {
                flip = flip | sdl.SDL_FLIP_HORIZONTAL;
            }
            _ = sdl.SDL_RenderCopyEx(renderer, gfx_texture, &src_rect, &dst_rect, 0, 0, flip);
        }
    }

    // sprite flags
    fn fget(tile: usize, flag: num) bool {
        const f: u5 = @intFromFloat(flag);
        const one: u32 = 1;
        return tile < cart_data.gff.len and (cart_data.gff[tile] & (one << f)) != 0;
    }

    // shapes
    fn line(x1: num, y1: num, x2: num, y2: num, col: num) void {
        const c = palette[@mod(@as(usize, @intFromFloat(col)), palette.len)];
        _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);

        if (x1 != x2) {
            std.log.err("only vertical lines are supported ({d:6.1},{d:6.1})({d:6.1},{d:6.1})", .{ x1, y1, x2, y2 });
            return;
        }

        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x1, @min(y1, y2), 1, @as(c_int, @intFromFloat(y2 - y1 + 1))));
    }

    fn rectfill(x1: num, y1: num, x2: num, y2: num, col: num) void {
        const c = palette[@mod(@as(usize, @intFromFloat(col)), palette.len)];
        _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);

        const rect = screen_rect(x1, y1, @intFromFloat(x2 - x1 + 1), @intFromFloat(y2 - y1 + 1));
        _ = sdl.SDL_RenderFillRect(renderer, &rect);
    }

    fn circfill(x: num, y: num, r: num, col: num) void {
        const c = palette[@mod(@as(usize, @intFromFloat(col)), palette.len)];
        _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);
        if (r <= 1) {
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 1, y, 3, 1));
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x, y - 1, 1, 3));
        } else if (r <= 2) {
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 2, y - 1, 5, 3));
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 1, y - 2, 3, 5));
        } else if (r <= 3) {
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 3, y - 1, 7, 3));
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 1, y - 3, 3, 7));
            _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x - 2, y - 2, 5, 5));
        }
    }

    fn print(str: []const u8, x_arg: num, y_arg: num, col: num) void {
        var col_idx: usize = @intFromFloat(@mod(col, 16));
        var x: c_int = @intFromFloat(x_arg - camera_x);
        const y: c_int = @intFromFloat(y_arg - camera_y);

        for (str) |cconst| {
            var c = cconst;
            c = c & 0x7F;

            draw_symbol(c, x, y, col_idx);

            x = x + 4;
        }
    }

    // screen
    var camera_x: num = 0;
    var camera_y: num = 0;
    var camera_shake_option: bool = false;
    fn camera(x: num, y: num) void {
        if (camera_shake_option) {
            camera_x = x;
            camera_y = y;
        }
    }

    // map
    fn map(cel_x: num, cel_y: num, screen_x: num, screen_y: num, cel_w: num, cel_h: num, mask: num) void {
        reload_textures(renderer);

        var x: num = 0;
        const map_len = cart_data.map_low.len + cart_data.map_high.len;
        while (x < cel_w) : (x += 1) {
            var y: num = 0;
            while (y < cel_h) : (y += 1) {
                const tile_index: usize = @intFromFloat(x + cel_x + (y + cel_y) * 128);
                if (tile_index < map_len) {
                    const idx = @mod(tile_index, map_len);
                    const tile: u8 = if (idx < cart_data.map_low.len) cart_data.map_low[idx] else cart_data.map_high[idx - cart_data.map_low.len];
                    if (mask == 0 or (mask == 4 and cart_data.gff[tile] == 4) or fget(tile, if (mask != 4) mask - 1 else mask)) {
                        var src_rect: sdl.SDL_Rect = undefined;
                        src_rect.x = @intCast(8 * @mod(tile, 16));
                        src_rect.y = @intCast(8 * @divTrunc(tile, 16));
                        src_rect.w = @intCast(8);
                        src_rect.h = @intCast(8);

                        const dst_rect = screen_rect(screen_x + x * 8, screen_y + y * 8, 8, 8);

                        _ = sdl.SDL_RenderCopy(renderer, gfx_texture, &src_rect, &dst_rect);
                    }
                }
            }
        }
    }

    fn mget(tx: num, ty: num) p8tile {
        if (ty <= 31) {
            const idx: usize = @intFromFloat(tx + ty * 128);
            return @intCast(cart_data.map_low[idx]);
        } else {
            const idx: usize = @intFromFloat(tx + (ty - 32) * 128);
            return @intCast(cart_data.map_high[idx]);
        }
    }

    // math
    fn abs(n: num) num {
        return @fabs(n);
    }

    fn flr(n: num) num {
        return @floor(n);
    }

    fn min(n1: num, n2: num) num {
        return @min(n1, n2);
    }

    fn max(n1: num, n2: num) num {
        return @max(n1, n2);
    }

    fn rnd(rnd_max: num) num {
        const n: i64 = pico8_random(10000 * rnd_max);
        return @as(num, @floatFromInt(n)) / 10000;
    }

    fn sin(x: num) num {
        return -std.math.sin(x * 6.2831853071796); //https://pico-8.fandom.com/wiki/Math
    }

    fn cos(x: num) num {
        return -sin((x) + 0.25);
    }
};

var rnd_seed_lo: i64 = 0;
var rnd_seed_hi: i64 = 1;
fn pico8_random(max: P8.num) i64 { //decomp'd pico-8
    if (max == 0) {
        return 0;
    }
    rnd_seed_hi = @addWithOverflow(((rnd_seed_hi << 16) | (rnd_seed_hi >> 16)), rnd_seed_lo)[0];
    rnd_seed_lo = @addWithOverflow(rnd_seed_lo, rnd_seed_hi)[0];
    return @mod(rnd_seed_hi, @as(i64, @intFromFloat(max)));
}

////////////////////////////////////////
// begining of celeste.p8 lua section //
////////////////////////////////////////

// ~celeste~
// matt thorson + noel berry

// globals //
/////////////

var new_bg: bool = false;
var frames: P8.num = 0;
var deaths: P8.num = 0;
var max_djump: P8.num = 0;
var start_game: bool = false;
var start_game_flash: P8.num = 0;
var seconds: P8.num = 0;
var minutes: P8.num = 0;

var room: P8Point = P8Point{ .x = 0, .y = 0 };
var objects: [30]Object = undefined;
// types = {}
var freeze: P8.num = 0;
var shake: P8.num = 0;
var will_restart: bool = false;
var delay_restart: P8.num = 0;
var got_fruit: [30]bool = undefined;
var has_dashed: bool = false;
var sfx_timer: P8.num = 0;
var has_key: bool = false;
var pause_player: bool = false;
var flash_bg: bool = false;
var music_timer: P8.num = 0;

const k_left: P8.num = 0;
const k_right: P8.num = 1;
const k_up: P8.num = 2;
const k_down: P8.num = 3;
const k_jump: P8.num = 4;
const k_dash: P8.num = 5;
const k_menu: P8.num = 6;

// entry point //
/////////////////

fn _init() void {
    for (&objects) |*obj| {
        obj.common.active = false;
    }
    for (&clouds) |*c| {
        c.x = P8.rnd(128);
        c.y = P8.rnd(128);
        c.spd = 1 + P8.rnd(4);
        c.w = 32 + P8.rnd(32);
    }
    for (&dead_particles) |*particle| {
        particle.active = false;
    }
    for (&particles) |*p| {
        p.active = true;
        p.x = P8.rnd(128);
        p.y = P8.rnd(128);
        p.s = 0 + P8.flr(P8.rnd(5) / 4);
        p.spd = P8Point{ .x = 0.25 + P8.rnd(5), .y = 0 };
        p.off = P8.rnd(1);
        p.c = 6 + P8.flr(0.5 + P8.rnd(1));
    }
    title_screen();
}

fn title_screen() void {
    // std.debug.print("title screen\n", .{});
    for (0..30) |i| { // 0 <= i <= 29
        got_fruit[i] = false;
    }
    frames = 0;
    deaths = 0;
    max_djump = 1;
    start_game = false;
    start_game_flash = 0;
    P8.music(40, 0, 7);
    load_room(7, 3);
    //load_room(5, 2);
}

fn begin_game() void {
    frames = 0;
    seconds = 0;
    minutes = 0;
    music_timer = 0;
    start_game = false;
    P8.music(0, 0, 7);
    load_room(0, 0);
}

fn level_index() P8.num {
    return @mod(room.x, 8) + room.y * 8;
}

fn is_title() bool {
    return level_index() == 31;
}

// effects //
/////////////

const Cloud = struct {
    x: P8.num,
    y: P8.num,
    w: P8.num,
    spd: P8.num,
};

var clouds: [17]Cloud = undefined;

const Particle = struct {
    active: bool,
    x: P8.num,
    y: P8.num,
    t: P8.num = 0,
    h: P8.num = 0,
    s: P8.num = 0,
    off: P8.num = 0,
    c: P8.num = 0,
    spd: P8Point,
};

var particles: [25]Particle = undefined;
var dead_particles: [8]Particle = undefined;

// player entity //
///////////////////

const Player = struct {
    p_jump: bool,
    p_dash: bool,
    grace: P8.num,
    jbuffer: P8.num,
    djump: P8.num,
    dash_time: P8.num,
    dash_effect_time: P8.num,
    dash_target: P8Point,
    dash_accel: P8Point,
    spr_off: P8.num,
    was_on_ground: bool,
    hair: [5]Hair,

    fn init(self: *Player, common: *ObjectCommon) void {
        self.p_jump = false;
        self.p_dash = false;
        self.grace = 0;
        self.jbuffer = 0;
        self.djump = max_djump;
        self.dash_time = 0;
        self.dash_effect_time = 0;
        self.dash_target = P8Point{ .x = 0, .y = 0 };
        self.dash_accel = P8Point{ .x = 0, .y = 0 };
        common.hitbox = P8Rect{ .x = 1, .y = 3, .w = 6, .h = 5 };
        self.spr_off = 0;
        self.was_on_ground = false;
        common.spr = 5;
        create_hair(&self.hair, common);
    }

    fn update(self: *Player, common: *ObjectCommon) void {
        if (pause_player) return;

        var input: P8.num = 0;
        if (P8.btn(k_left)) {
            input = -1;
        } else if (P8.btn(k_right)) {
            input = 1;
        }

        // spikes collide
        if (spikes_at(common.x + common.hitbox.x, common.y + common.hitbox.y, common.hitbox.w, common.hitbox.h, common.spd.x, common.spd.y)) {
            kill_player(self, common);
            return;
        }

        // bottom death
        if (common.y > 128) {
            kill_player(self, common);
            return;
        }

        const on_ground = common.is_solid(0, 1);
        const on_ice = common.is_ice(0, 1);

        // smoke particles
        if (on_ground and !self.was_on_ground) {
            init_object(EntityType.smoke, common.x, common.y + 4);
        }

        const jump = P8.btn(k_jump) and !self.p_jump;
        self.p_jump = P8.btn(k_jump);
        if (jump) {
            self.jbuffer = 4;
        } else if (self.jbuffer > 0) {
            self.jbuffer -= 1;
        }

        const dash = P8.btn(k_dash) and !self.p_dash;
        self.p_dash = P8.btn(k_dash);

        if (on_ground) {
            self.grace = 6;
            if (self.djump < max_djump) {
                psfx(54);
                self.djump = max_djump;
            }
        } else if (self.grace > 0) {
            self.grace -= 1;
        }

        self.dash_effect_time -= 1;
        if (self.dash_time > 0) {
            init_object(EntityType.smoke, common.x, common.y);
            self.dash_time -= 1;
            common.spd.x = appr(common.spd.x, self.dash_target.x, self.dash_accel.x);
            common.spd.y = appr(common.spd.y, self.dash_target.y, self.dash_accel.y);
        } else {

            // move
            var maxrun: P8.num = 1;
            var accel: P8.num = 0.6;
            var deccel: P8.num = 0.15;

            if (!on_ground) {
                accel = 0.4;
            } else if (on_ice) {
                accel = 0.05;
                const input_facing: P8.num = if (common.flip_x) -1 else 1;
                if (input == input_facing) {
                    accel = 0.05;
                }
            }

            if (P8.abs(common.spd.x) > maxrun) {
                common.spd.x = appr(common.spd.x, sign(common.spd.x) * maxrun, deccel);
            } else {
                common.spd.x = appr(common.spd.x, input * maxrun, accel);
            }

            //facing
            if (common.spd.x != 0) {
                common.flip_x = (common.spd.x < 0);
            }

            // gravity
            var maxfall: P8.num = 2;
            var gravity: P8.num = 0.21;

            if (P8.abs(common.spd.y) <= 0.15) {
                gravity *= 0.5;
            }

            // wall slide
            if (input != 0 and common.is_solid(input, 0) and !common.is_ice(input, 0)) {
                maxfall = 0.4;
                if (P8.rnd(10) < 2) {
                    init_object(EntityType.smoke, common.x + input * 6, common.y);
                }
            }

            if (!on_ground) {
                common.spd.y = appr(common.spd.y, maxfall, gravity);
            }

            // jump
            if (self.jbuffer > 0) {
                if (self.grace > 0) {
                    // normal jump
                    psfx(1);
                    self.jbuffer = 0;
                    self.grace = 0;
                    common.spd.y = -2;
                    init_object(EntityType.smoke, common.x, common.y + 4);
                } else {
                    // wall jump
                    var wall_dir: P8.num = if (common.is_solid(3, 0)) 1 else 0;
                    wall_dir = if (common.is_solid(-3, 0)) -1 else wall_dir;
                    if (wall_dir != 0) {
                        psfx(2);
                        self.jbuffer = 0;
                        common.spd.y = -2;
                        common.spd.x = -wall_dir * (maxrun + 1);
                        if (!common.is_ice(wall_dir * 3, 0)) {
                            init_object(EntityType.smoke, common.x + wall_dir * 6, common.y);
                        }
                    }
                }
            }

            // dash
            const d_full: P8.num = 5;
            const d_half: P8.num = d_full * 0.70710678118;

            if (self.djump > 0 and dash) {
                init_object(EntityType.smoke, common.x, common.y);
                self.djump -= 1;
                self.dash_time = 4;
                has_dashed = true;
                self.dash_effect_time = 10;
                var v_input: P8.num = if (P8.btn(k_down)) 1 else 0;
                v_input = if (P8.btn(k_up)) -1 else v_input;
                if (input != 0) {
                    if (v_input != 0) {
                        common.spd.x = input * d_half;
                        common.spd.y = v_input * d_half;
                    } else {
                        common.spd.x = input * d_full;
                        common.spd.y = 0;
                    }
                } else if (v_input != 0) {
                    common.spd.x = 0;
                    common.spd.y = v_input * d_full;
                } else {
                    common.spd.x = if (common.flip_x) -1 else 1;
                    common.spd.y = 0;
                }

                psfx(3);
                freeze = 2;
                shake = 6;
                self.dash_target.x = 2 * sign(common.spd.x);
                self.dash_target.y = 2 * sign(common.spd.y);
                self.dash_accel.x = 1.5;
                self.dash_accel.y = 1.5;

                if (common.spd.y < 0) {
                    self.dash_target.y *= 0.75;
                }

                if (common.spd.y != 0) {
                    self.dash_accel.x *= 0.70710678118;
                }
                if (common.spd.x != 0) {
                    self.dash_accel.y *= 0.70710678118;
                }
            } else if (dash and self.djump <= 0) {
                psfx(9);
                init_object(EntityType.smoke, common.x, common.y);
            }
            self.spr_off += 0.25;
            if (!on_ground) {
                if (common.is_solid(input, 0)) {
                    common.spr = 5;
                } else {
                    common.spr = 3;
                }
            } else if (P8.btn(k_down)) {
                common.spr = 6;
            } else if (P8.btn(k_up)) {
                common.spr = 7;
            } else if ((common.spd.x == 0) or (!P8.btn(k_left) and !P8.btn(k_right))) {
                common.spr = 1;
            } else {
                common.spr = 1 + @mod(self.spr_off, 4);
            }

            // next level
            if (common.y < -4 and level_index() < 30) {
                next_room();
            }

            // was on the ground
            self.was_on_ground = on_ground;
        }
    }

    fn draw(self: *Player, common: *ObjectCommon) void {
        // clamp in screen
        if (common.x < -1 or common.x > 121) {
            common.x = clamp(common.x, -1, 121);
            common.spd.x = 0;
        }

        set_hair_color(self.djump);
        draw_hair(&self.hair, common, if (common.flip_x) -1 else 1);
        P8.spr(common.spr, common.x, common.y, 1, 1, common.flip_x, common.flip_y);
        unset_hair_color();
    }
};

fn psfx(x: P8.num) void {
    if (sfx_timer <= 0) {
        P8.sfx(x);
    }
}

const Hair = struct {
    x: P8.num,
    y: P8.num,
    size: P8.num,
    isLast: bool,
};

fn create_hair(hair: []Hair, common: *ObjectCommon) void {
    var i: P8.num = 0;
    while (i <= 4) : (i += 1) {
        hair[@intFromFloat(i)] = Hair{
            .x = common.x,
            .y = common.y,
            .size = P8.max(1, P8.min(2, 3 - i)),
            .isLast = (i == 4),
        };
    }
}

fn set_hair_color(djump: P8.num) void {
    const col =
        if (djump == 1)
        8
    else
        (if (djump == 2)
            (7 + P8.flr(@mod(frames / 3, 2)) * 4)
        else
            12);
    P8.pal(8, col);
}

fn draw_hair(hair: []Hair, common: *ObjectCommon, facing: P8.num) void {
    var last_x: P8.num = common.x + 4 - facing * 2;
    var last_y: P8.num = common.y;
    if (P8.btn(k_down)) {
        last_y += 4;
    } else {
        last_y += 3;
    }
    for (hair) |*h| {
        h.x += (last_x - h.x) / 1.5;
        h.y += (last_y + 0.5 - h.y) / 1.5;
        P8.circfill(h.x, h.y, h.size, 8);
        last_x = h.x;
        last_y = h.y;
    }
}

fn unset_hair_color() void {
    P8.pal(8, 8);
}

const PlayerSpawn = struct {
    target: P8Point,
    state: P8.num,
    delay: P8.num,
    hair: [5]Hair,

    fn init(self: *PlayerSpawn, common: *ObjectCommon) void {
        P8.sfx(4);
        common.spr = 3;
        self.target.x = common.x;
        self.target.y = common.y;
        common.y = 128;
        common.spd.y = -4;
        self.state = 0;
        self.delay = 0;
        common.solids = false;
        create_hair(&self.hair, common);
    }

    fn update(self: *PlayerSpawn, common: *ObjectCommon) void {
        if (self.state == 0) { // jumping up
            if (common.y < self.target.y + 16) {
                self.state = 1;
                self.delay = 3;
            }
        } else if (self.state == 1) { // falling
            common.spd.y += 0.5;
            if (common.spd.y > 0 and self.delay > 0) {
                common.spd.y = 0;
                self.delay -= 1;
            }
            if (common.spd.y > 0 and common.y > self.target.y) {
                common.y = self.target.y;
                common.spd = P8Point{ .x = 0, .y = 0 };
                self.state = 2;
                self.delay = 5;
                shake = 5;
                init_object(EntityType.smoke, common.x, common.y + 4);
                P8.sfx(5);
            }
        } else if (self.state == 2) { // landing
            self.delay -= 1;
            common.spr = 6;
            if (self.delay < 0) {
                destroy_object(common);
                init_object(EntityType.player, common.x, common.y);
            }
        }
    }

    fn draw(self: *PlayerSpawn, common: *ObjectCommon) void {
        set_hair_color(max_djump);
        draw_hair(&self.hair, common, 1);
        P8.spr(common.spr, common.x, common.y, 1, 1, common.flip_x, common.flip_y);
        unset_hair_color();
    }
};

const Spring = struct {
    hide_in: P8.num,
    hide_for: P8.num,
    delay: P8.num,

    fn init(self: *Spring, common: *ObjectCommon) void {
        _ = common;
        self.hide_in = 0;
        self.hide_for = 0;
    }

    fn update(self: *Spring, common: *ObjectCommon) void {
        if (self.hide_for > 0) {
            self.hide_for -= 1;
            if (self.hide_for <= 0) {
                common.spr = 18;
                self.delay = 0;
            }
        } else if (common.spr == 18) {
            var hit_opt = common.collide(EntityType.player, 0, 0);
            if (hit_opt) |hit| {
                if (hit.common.spd.y >= 0) {
                    common.spr = 19;
                    hit.common.y = common.y - 4;
                    hit.common.spd.x *= 0.2;
                    hit.common.spd.y = -3;
                    hit.specific.player.djump = max_djump;
                    self.delay = 10;
                    init_object(EntityType.smoke, common.x, common.y);

                    // breakable below us
                    var below_opt = common.collide(EntityType.fall_floor, 0, 1);
                    if (below_opt) |below| {
                        break_fall_floor(&below.specific.fall_floor, &below.common);
                    }

                    psfx(8);
                }
            }
        } else if (self.delay > 0) {
            self.delay -= 1;
            if (self.delay <= 0) {
                common.spr = 18;
            }
        }
        // begin hiding
        if (self.hide_in > 0) {
            self.hide_in -= 1;
            if (self.hide_in <= 0) {
                self.hide_for = 60;
                common.spr = 0;
            }
        }
    }
};

fn break_spring(self: *Spring) void {
    self.hide_in = 15;
}

const Balloon = struct {
    timer: P8.num,
    offset: P8.num,
    start: P8.num,

    //tile=22,
    fn init(self: *Balloon, common: *ObjectCommon) void {
        self.offset = P8.rnd(1);
        self.start = common.y;
        self.timer = 0;
        common.hitbox = P8Rect{ .x = -1, .y = -1, .w = 10, .h = 10 };
    }
    fn update(self: *Balloon, common: *ObjectCommon) void {
        if (common.spr == 22) {
            self.offset += 0.01;
            common.y = self.start + P8.sin(self.offset) * 2;
            var hit_opt = common.collide(EntityType.player, 0, 0);
            if (hit_opt) |hit| {
                if (hit.specific.player.djump < max_djump) {
                    psfx(6);
                    init_object(EntityType.smoke, common.x, common.y);
                    hit.specific.player.djump = max_djump;
                    common.spr = 0;
                    self.timer = 60;
                }
            }
        } else if (self.timer > 0) {
            self.timer = self.timer - 1;
        } else {
            psfx(7);
            init_object(EntityType.smoke, common.x, common.y);
            common.spr = 22;
        }
    }
    fn draw(self: *Balloon, common: *ObjectCommon) void {
        if (common.spr == 22) {
            P8.spr(13 + @mod(self.offset * 8, 3), common.x, common.y + 6, 1, 1, false, false);
            P8.spr(common.spr, common.x, common.y, 1, 1, false, false);
        }
    }
};

const FallFloor = struct {
    state: P8.num,
    delay: P8.num,

    fn init(self: *FallFloor, common: *ObjectCommon) void {
        self.state = 0;
        _ = common;
        // common.solid = true; // Typo in the original game
    }

    fn update(self: *FallFloor, common: *ObjectCommon) void {
        if (self.state == 0) { // idling
            if (common.check(EntityType.player, 0, -1) or common.check(EntityType.player, -1, 0) or common.check(EntityType.player, 1, 0)) {
                break_fall_floor(self, common);
            }
        } else if (self.state == 1) { // shaking
            self.delay -= 1;
            if (self.delay <= 0) {
                self.state = 2;
                self.delay = 60; // how long it hides for
                common.collideable = false;
            }
        } else if (self.state == 2) { // invisible, waiting to reset
            self.delay -= 1;
            if (self.delay <= 0 and !common.check(EntityType.player, 0, 0)) {
                psfx(7);
                self.state = 0;
                common.collideable = true;
                init_object(EntityType.smoke, common.x, common.y);
            }
        }
    }

    fn draw(self: *FallFloor, common: *ObjectCommon) void {
        if (self.state != 2) {
            if (self.state != 1) {
                P8.spr(23, common.x, common.y, 1, 1, false, false);
            } else {
                P8.spr(23 + (15 - self.delay) / 5, common.x, common.y, 1, 1, false, false);
            }
        }
    }
};

fn break_fall_floor(self: *FallFloor, common: *ObjectCommon) void {
    if (self.state == 0) {
        psfx(15);
        self.state = 1;
        self.delay = 15; // how long until it falls
        init_object(EntityType.smoke, common.x, common.y);
        var hit_opt = common.collide(EntityType.spring, 0, -1);
        if (hit_opt) |hit| {
            break_spring(&hit.specific.spring);
        }
    }
}

const Smoke = struct {
    fn init(self: *Smoke, common: *ObjectCommon) void {
        _ = self;
        common.spr = 29;
        common.spd.y = -0.1;
        common.spd.x = 0.3 + P8.rnd(0.2);
        common.x += -1 + P8.rnd(2);
        common.y += -1 + P8.rnd(2);
        common.flip_x = maybe();
        common.flip_y = maybe();
        common.solids = false;
    }
    fn update(self: *Smoke, common: *ObjectCommon) void {
        _ = self;
        common.spr += 0.2;
        if (common.spr >= 32) {
            destroy_object(common);
        }
    }
};

const Fruit = struct {
    start: P8.num,
    off: P8.num,
    //tile=26,
    //if_not_fruit=true,
    fn init(self: *Fruit, common: *ObjectCommon) void {
        self.start = common.y;
        self.off = 0;
    }

    fn update(self: *Fruit, common: *ObjectCommon) void {
        var hit_opt = common.collide(EntityType.player, 0, 0);
        if (hit_opt) |hit| {
            hit.specific.player.djump = max_djump;
            sfx_timer = 20;
            P8.sfx(13);
            got_fruit[@intFromFloat(level_index())] = true;
            init_object(EntityType.life_up, common.x, common.y);
            destroy_object(common);
            return;
        }
        self.off += 1;
        common.y = self.start + P8.sin(self.off / 40) * 2.5;
    }
};

const FlyFruit = struct {
    fly: bool,
    step: P8.num,
    sfx_delay: P8.num,
    start: P8.num,

    fn init(self: *FlyFruit, common: *ObjectCommon) void {
        self.start = common.y;
        self.fly = false;
        self.step = 0.5;
        common.solids = false;
        self.sfx_delay = 8;
    }

    fn update(self: *FlyFruit, common: *ObjectCommon) void {
        var do_destroy = false;
        //fly away
        if (self.fly) {
            if (self.sfx_delay > 0) {
                self.sfx_delay -= 1;
                if (self.sfx_delay <= 0) {
                    sfx_timer = 20;
                    P8.sfx(14);
                }
            }
            common.spd.y = appr(common.spd.y, -3.5, 0.25);
            if (common.y < -16) {
                do_destroy = true;
            }
        } else {
            if (has_dashed) {
                self.fly = true;
            }
            self.step += 0.05;
            common.spd.y = P8.sin(self.step) * 0.5;
        }
        // collect
        var hit_opt = common.collide(EntityType.player, 0, 0);
        if (hit_opt) |hit| {
            hit.specific.player.djump = max_djump;
            sfx_timer = 20;
            P8.sfx(13);
            got_fruit[@intFromFloat(level_index())] = true;
            init_object(EntityType.life_up, common.x, common.y);
            do_destroy = true;
        }
        if (do_destroy) {
            destroy_object(common);
        }
    }

    fn draw(self: *FlyFruit, common: *ObjectCommon) void {
        var off: P8.num = 0;
        if (!self.fly) {
            var dir = P8.sin(self.step);
            if (dir < 0) {
                off = 1 + P8.max(0, sign(common.y - self.start));
            }
        } else {
            off = @mod(off + 0.25, 3);
        }
        P8.spr(45 + off, common.x - 6, common.y - 2, 1, 1, true, false);
        P8.spr(common.spr, common.x, common.y, 1, 1, false, false);
        P8.spr(45 + off, common.x + 6, common.y - 2, 1, 1, false, false);
    }
};

const LifeUp = struct {
    duration: P8.num,
    flash: P8.num,

    fn init(self: *LifeUp, common: *ObjectCommon) void {
        common.spd.y = -0.25;
        self.duration = 30;
        common.x -= 2;
        common.y -= 4;
        self.flash = 0;
        common.solids = false;
    }

    fn update(self: *LifeUp, common: *ObjectCommon) void {
        self.duration -= 1;
        if (self.duration <= 0) {
            destroy_object(common);
        }
    }
    fn draw(self: *LifeUp, common: *ObjectCommon) void {
        self.flash += 0.5;
        P8.print("1000", common.x - 2, common.y, 7 + @mod(self.flash, 2));
    }
};

const FakeWall = struct {
    fn update(self: *FakeWall, common: *ObjectCommon) void {
        _ = self;
        common.hitbox = P8Rect{ .x = -1, .y = -1, .w = 18, .h = 18 };
        var hit_opt = common.collide(EntityType.player, 0, 0);
        if (hit_opt) |hit| {
            if (hit.specific.player.dash_effect_time > 0) {
                hit.common.spd.x = -sign(hit.common.spd.x) * 1.5;
                hit.common.spd.y = -1.5;
                hit.specific.player.dash_time = -1;
                sfx_timer = 20;
                P8.sfx(16);
                destroy_object(common);
                init_object(EntityType.smoke, common.x, common.y);
                init_object(EntityType.smoke, common.x + 8, common.y);
                init_object(EntityType.smoke, common.x, common.y + 8);
                init_object(EntityType.smoke, common.x + 8, common.y + 8);
                init_object(EntityType.fruit, common.x + 4, common.y + 4);
                return; //
            }
        }
        common.hitbox = P8Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    }

    fn draw(self: *FakeWall, common: *ObjectCommon) void {
        _ = self;
        P8.spr(64, common.x, common.y, 1, 1, false, false);
        P8.spr(65, common.x + 8, common.y, 1, 1, false, false);
        P8.spr(80, common.x, common.y + 8, 1, 1, false, false);
        P8.spr(81, common.x + 8, common.y + 8, 1, 1, false, false);
    }
};

const Key = struct {
    // tile=8,
    // if_not_fruit=true,
    fn update(self: *Key, common: *ObjectCommon) void {
        _ = self;
        const was = common.spr;
        common.spr = 9 + (P8.sin(frames / 30) + 0.5) * 1;
        const is = common.spr;
        if (is == 10 and is != was) {
            common.flip_x = !common.flip_x;
        }
        if (common.check(EntityType.player, 0, 0)) {
            P8.sfx(23);
            sfx_timer = 10;
            destroy_object(common);
            has_key = true;
        }
    }
};

const Chest = struct {
    timer: P8.num,
    start: P8.num,

    // tile=20,
    // if_not_fruit=true,
    fn init(self: *Chest, common: *ObjectCommon) void {
        common.x -= 4;
        self.start = common.x;
        self.timer = 20;
    }
    fn update(self: *Chest, common: *ObjectCommon) void {
        if (has_key) {
            self.timer -= 1;
            common.x = self.start - 1 + P8.rnd(3);
            if (self.timer <= 0) {
                sfx_timer = 20;
                P8.sfx(16);
                init_object(EntityType.fruit, common.x, common.y - 4);
                destroy_object(common);
            }
        }
    }
};

const Platform = struct {
    last: P8.num,
    dir: P8.num,

    fn init(self: *Platform, common: *ObjectCommon) void {
        common.x -= 4;
        common.solids = false;
        common.hitbox.w = 16;
        self.last = common.x;
    }

    fn update(self: *Platform, common: *ObjectCommon) void {
        common.spd.x = self.dir * 0.65;
        if (common.x < -16) {
            common.x = 128;
        }
        if (common.x > 128) {
            common.x = -16;
        }
        if (!common.check(EntityType.player, 0, 0)) {
            var hit_opt = common.collide(EntityType.player, 0, -1);
            if (hit_opt) |hit| {
                hit.common.move_x(common.x - self.last, 1);
            }
        }
        self.last = common.x;
    }

    fn draw(self: *Platform, common: *ObjectCommon) void {
        _ = self;
        P8.spr(11, common.x, common.y - 1, 1, 1, false, false);
        P8.spr(12, common.x + 8, common.y - 1, 1, 1, false, false);
    }
};

const Message = struct {
    text: []const u8,
    index: P8.num,
    last: P8.num,
    off: P8Point,

    fn draw(self: *Message, common: *ObjectCommon) void {
        self.text = "-- celeste mountain --#this memorial to those# perished on the climb";
        if (common.check(EntityType.player, 4, 0)) {
            if (self.index < @as(P8.num, @floatFromInt(self.text.len))) {
                self.index += 0.5;
                if (self.index >= self.last + 1) {
                    self.last += 1;
                    P8.sfx(35);
                }
            }
            self.off = P8Point{ .x = 8, .y = 96 };
            var i: P8.num = 0;
            while (i < self.index) : (i += 1) {
                if (self.text[@intFromFloat(i)] != '#') {
                    P8.rectfill(self.off.x - 2, self.off.y - 2, self.off.x + 7, self.off.y + 6, 7);
                    P8.print(self.text[@intFromFloat(i)..@intFromFloat(1 + i)], self.off.x, self.off.y, 0);
                    self.off.x += 5;
                } else {
                    self.off.x = 8;
                    self.off.y += 7;
                }
            }
        } else {
            self.index = 0;
            self.last = 0;
        }
    }
};

const BigChest = struct {
    state: P8.num,
    timer: P8.num,
    particle_count: P8.num,
    particles: [50]Particle,

    fn init(self: *BigChest, common: *ObjectCommon) void {
        self.state = 0;
        common.hitbox.w = 16;
    }

    fn draw(self: *BigChest, common: *ObjectCommon) void {
        if (self.state == 0) {
            var hit_opt = common.collide(EntityType.player, 0, 8);
            if (hit_opt) |hit| {
                if (hit.common.is_solid(0, 1)) {
                    P8.music(-1, 500, 7);
                    P8.sfx(37);
                    pause_player = true;
                    hit.common.spd.x = 0;
                    hit.common.spd.y = 0;
                    self.state = 1;
                    init_object(EntityType.smoke, common.x, common.y);
                    init_object(EntityType.smoke, common.x + 8, common.y);
                    self.timer = 60;
                    self.particle_count = 0;
                    for (&self.particles) |*p| {
                        p.active = false;
                    }
                }
            }
            P8.spr(96, common.x, common.y, 1, 1, false, false);
            P8.spr(97, common.x + 8, common.y, 1, 1, false, false);
        } else if (self.state == 1) {
            self.timer -= 1;
            shake = 5;
            flash_bg = true;
            if (self.timer <= 45 and self.particle_count < 50) {
                self.particles[@intFromFloat(self.particle_count)] = Particle{
                    .active = true,
                    .x = 1 + P8.rnd(14),
                    .y = 0,
                    .h = 32 + P8.rnd(32),
                    .spd = P8Point{
                        .x = 0,
                        .y = 8 + P8.rnd(8),
                    },
                };
                self.particle_count += 1;
            }
            if (self.timer < 0) {
                self.state = 2;
                self.particle_count = 0;
                flash_bg = false;
                new_bg = true;
                init_object(EntityType.orb, common.x + 4, common.y + 4);
                pause_player = false;
            }
            for (&self.particles) |*p| {
                p.y += p.spd.y;
                P8.line(common.x + p.x, common.y + 8 - p.y, common.x + p.x, P8.min(common.y + 8 - p.y + p.h, common.y + 8), 7);
            }
        }
        P8.spr(112, common.x, common.y + 8, 1, 1, false, false);
        P8.spr(113, common.x + 8, common.y + 8, 1, 1, false, false);
    }
};

const Orb = struct {
    fn init(self: *Orb, common: *ObjectCommon) void {
        _ = self;
        common.spd.y = -4;
        common.solids = false;
        // unused this.particles={}
    }
    fn draw(self: *Orb, common: *ObjectCommon) void {
        _ = self;
        common.spd.y = appr(common.spd.y, 0, 0.5);
        var hit_opt = common.collide(EntityType.player, 0, 0);
        if (hit_opt) |hit| {
            if (common.spd.y == 0) {
                music_timer = 45;
                P8.sfx(51);
                freeze = 10;
                shake = 10;
                destroy_object(common);
                max_djump = 2;
                hit.specific.player.djump = 2;
                return;
            }
        }

        P8.spr(102, common.x, common.y, 1, 1, false, false);
        const off: P8.num = frames / 30;
        var i: P8.num = 0;
        while (i <= 7) : (i += 1) {
            P8.circfill(common.x + 4 + P8.cos(off + i / 8) * 8, common.y + 4 + P8.sin(off + i / 8) * 8, 1, 7);
        }
    }
};

const Flag = struct {
    show: bool,
    score: P8.num,

    fn init(self: *Flag, common: *ObjectCommon) void {
        common.x += 5;
        self.score = 0;
        self.show = false;
        var i: usize = 0;
        while (i < FRUIT_COUNT) : (i += 1) {
            if (got_fruit[i]) {
                self.score += 1;
            }
        }
    }
    fn draw(self: *Flag, common: *ObjectCommon) void {
        common.spr = 118 + @mod((frames / 5), 3);
        P8.spr(common.spr, common.x, common.y, 1, 1, false, false);
        if (self.show) {
            var str: [20]u8 = undefined;
            @memset(&str, 0);
            P8.rectfill(32, 2, 96, 31, 0);
            P8.spr(26, 55, 6, 1, 1, false, false);
            _ = std.fmt.bufPrint(&str, "x {} ", .{@as(usize, @intFromFloat(self.score))}) catch {
                return;
            };
            P8.print(&str, 64, 9, 7);
            draw_time(49, 16);
            _ = std.fmt.bufPrint(&str, "deaths {} ", .{@as(usize, @intFromFloat(deaths))}) catch {
                return;
            };
            P8.print(&str, 48, 24, 7);
        } else if (common.check(EntityType.player, 0, 0)) {
            P8.sfx(55);
            sfx_timer = 30;
            self.show = true;
        }
    }
};

const RoomTitle = struct {
    delay: P8.num,

    fn init(self: *RoomTitle) void {
        self.delay = 5;
    }
    fn draw(self: *RoomTitle, common: *ObjectCommon) void {
        self.delay -= 1;
        if (self.delay < -30) {
            destroy_object(common);
        } else if (self.delay < 0) {
            P8.rectfill(24, 58, 104, 70, 0);
            if (room.x == 3 and room.y == 1) {
                P8.print("old site", 48, 62, 7);
            } else if (level_index() == 30) {
                P8.print("summit", 52, 62, 7);
            } else {
                const level = (1 + level_index()) * 100;
                var str: [16]u8 = undefined;
                @memset(&str, 0);
                _ = std.fmt.bufPrint(&str, "{} m", .{@as(i32, @intFromFloat(level))}) catch {
                    return;
                };
                const offset: P8.num = if (level < 1000) 2 else 0;
                P8.print(&str, 52 + offset, 62, 7);
            }
            //print("//-",86,64-2,13)

            draw_time(4, 4);
        }
    }
};

const EntityType = enum(p8tile) {
    balloon = 22,
    big_chest = 96,
    chest = 20,
    fake_wall = 64,
    fall_floor = 23,
    flag = 118,
    fly_fruit = 28,
    fruit = 26,
    key = 8,
    life_up = -4,
    message = 86,
    orb = -6,
    platform = -3,
    player = -2,
    player_spawn = 1,
    room_title = -1,
    smoke = -5,
    spring = 18,

    fn if_not_fruit(self: EntityType) bool {
        switch (self) {
            EntityType.chest, EntityType.fly_fruit, EntityType.fruit, EntityType.fake_wall, EntityType.key => {
                return true;
            },
            else => {
                return false;
            },
        }
    }
};

const all_entity_types = [_]EntityType{
    .balloon,
    .big_chest,
    .chest,
    .fake_wall,
    .fall_floor,
    .flag,
    .fly_fruit,
    .fruit,
    .key,
    .life_up,
    .message,
    .orb,
    .platform,
    .player,
    .player_spawn,
    .room_title,
    .smoke,
    .spring,
};

const ObjectCommon = struct {
    entity_type: EntityType,
    active: bool,
    x: P8.num,
    y: P8.num,
    hitbox: P8Rect,
    spd: P8Point,
    rem: P8Point,
    spr: P8.num,
    flip_x: bool,
    flip_y: bool,
    solids: bool,
    collideable: bool,

    fn init(self: *ObjectCommon, x: P8.num, y: P8.num, entity_type: EntityType) void {
        self.entity_type = entity_type;
        self.active = true;
        self.x = x;
        self.y = y;
        self.hitbox = P8Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };
        self.spd.x = 0;
        self.spd.y = 0;
        self.spr = @floatFromInt(@intFromEnum(entity_type));
        self.flip_x = false;
        self.flip_y = false;
        self.solids = true;
        self.collideable = true;
    }

    fn collide(self: *ObjectCommon, entity_type: EntityType, ox: P8.num, oy: P8.num) ?*Object {
        // local other
        for (&objects) |*other| {
            // TODO compare object ids: if (other.common.active and other.common.entity_type == entity_type and other.common != self.* and other.collideable and
            if (other.common.active and other.common.entity_type == entity_type and other.common.collideable and
                other.common.x + other.common.hitbox.x + other.common.hitbox.w > self.x + self.hitbox.x + ox and
                other.common.y + other.common.hitbox.y + other.common.hitbox.h > self.y + self.hitbox.y + oy and
                other.common.x + other.common.hitbox.x < self.x + self.hitbox.x + self.hitbox.w + ox and
                other.common.y + other.common.hitbox.y < self.y + self.hitbox.y + self.hitbox.h + oy)
            {
                return other;
            }
        }
        return null;
    }

    fn check(self: *ObjectCommon, entity_type: EntityType, ox: P8.num, oy: P8.num) bool {
        return self.collide(entity_type, ox, oy) != null;
    }

    fn is_ice(self: *ObjectCommon, ox: P8.num, oy: P8.num) bool {
        return ice_at(self.x + self.hitbox.x + ox, self.y + self.hitbox.y + oy, self.hitbox.w, self.hitbox.h);
    }

    fn move(self: *ObjectCommon, ox: P8.num, oy: P8.num) void {
        var amount: P8.num = 0;

        self.rem.x += ox;
        amount = P8.flr(self.rem.x + 0.5);
        self.rem.x -= amount;
        self.move_x(amount, 0);

        self.rem.y += oy;
        amount = P8.flr(self.rem.y + 0.5);
        self.rem.y -= amount;
        self.move_y(amount);
    }

    fn move_x(self: *ObjectCommon, amount: P8.num, start: P8.num) void {
        if (self.solids) {
            const step = sign(amount);
            var i: P8.num = start;
            while (i <= P8.abs(amount)) : (i += 1) { // i <= amount
                if (!self.is_solid(step, 0)) {
                    self.x += step;
                } else {
                    self.spd.x = 0;
                    self.rem.x = 0;
                    break;
                }
            }
        } else {
            self.x += amount;
        }
    }

    fn move_y(self: *ObjectCommon, amount: P8.num) void {
        if (self.solids) {
            const step = sign(amount);
            var i: P8.num = 0;
            while (i <= P8.abs(amount)) : (i += 1) {
                if (!self.is_solid(0, step)) {
                    self.y += step;
                } else {
                    self.spd.y = 0;
                    self.rem.y = 0;
                    break;
                }
            }
        } else {
            self.y += amount;
        }
    }

    fn is_solid(self: *ObjectCommon, ox: P8.num, oy: P8.num) bool {
        if (oy > 0 and !self.check(EntityType.platform, ox, 0) and self.check(EntityType.platform, ox, oy)) {
            return true;
        }
        return solid_at(self.x + self.hitbox.x + ox, self.y + self.hitbox.y + oy, self.hitbox.w, self.hitbox.h) or self.check(EntityType.fall_floor, ox, oy) or self.check(EntityType.fake_wall, ox, oy);
    }
};

const ObjectSpecific = union(EntityType) {
    balloon: Balloon,
    big_chest: BigChest,
    chest: Chest,
    fake_wall: FakeWall,
    fall_floor: FallFloor,
    flag: Flag,
    fly_fruit: FlyFruit,
    fruit: Fruit,
    key: Key,
    life_up: LifeUp,
    message: Message,
    orb: Orb,
    platform: Platform,
    player: Player,
    player_spawn: PlayerSpawn,
    room_title: RoomTitle,
    smoke: Smoke,
    spring: Spring,
};

const Object = struct {
    common: ObjectCommon,
    specific: ObjectSpecific,
};

fn init_object(etype: EntityType, x: P8.num, y: P8.num) void {
    _ = create_object(etype, x, y);
}

fn create_object(etype: EntityType, x: P8.num, y: P8.num) *Object {
    if (etype.if_not_fruit() and got_fruit[@intFromFloat(level_index())]) {
        return undefined;
    }

    var common: ObjectCommon = undefined;
    common.init(x, y, etype);
    var specific: ObjectSpecific =
        switch (etype) {
        EntityType.balloon => blk: {
            var b: Balloon = undefined;
            b.init(&common);
            break :blk ObjectSpecific{ .balloon = b };
        },
        EntityType.big_chest => blk: {
            var b: BigChest = undefined;
            b.init(&common);
            break :blk ObjectSpecific{ .big_chest = b };
        },
        EntityType.chest => blk: {
            var c: Chest = undefined;
            c.init(&common);
            break :blk ObjectSpecific{ .chest = c };
        },
        EntityType.fall_floor => blk: {
            var f: FallFloor = undefined;
            f.init(&common);
            break :blk ObjectSpecific{ .fall_floor = f };
        },
        EntityType.fake_wall => blk: {
            var f: FakeWall = FakeWall{};
            break :blk ObjectSpecific{ .fake_wall = f };
        },
        EntityType.flag => blk: {
            var f: Flag = undefined;
            f.init(&common);
            break :blk ObjectSpecific{ .flag = f };
        },
        EntityType.fly_fruit => blk: {
            var f: FlyFruit = undefined;
            f.init(&common);
            break :blk ObjectSpecific{ .fly_fruit = f };
        },
        EntityType.fruit => blk: {
            var f: Fruit = undefined;
            f.init(&common);
            break :blk ObjectSpecific{ .fruit = f };
        },
        EntityType.key => blk: {
            var k: Key = Key{};
            break :blk ObjectSpecific{ .key = k };
        },
        EntityType.life_up => blk: {
            var s: LifeUp = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .life_up = s };
        },
        EntityType.message => blk: {
            var m: Message = undefined;
            break :blk ObjectSpecific{ .message = m };
        },
        EntityType.orb => blk: {
            var o: Orb = undefined;
            o.init(&common);
            break :blk ObjectSpecific{ .orb = o };
        },
        EntityType.smoke => blk: {
            var s: Smoke = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .smoke = s };
        },
        EntityType.platform => blk: {
            var s: Platform = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .platform = s };
        },
        EntityType.room_title => blk: {
            var s: RoomTitle = undefined;
            s.init();
            break :blk ObjectSpecific{ .room_title = s };
        },
        EntityType.player_spawn => blk: {
            var s: PlayerSpawn = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .player_spawn = s };
        },
        EntityType.player => blk: {
            var s: Player = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .player = s };
        },
        EntityType.spring => blk: {
            var s: Spring = undefined;
            s.init(&common);
            break :blk ObjectSpecific{ .spring = s };
        },
    };
    const object = Object{
        .common = common,
        .specific = specific,
    };

    var i: usize = 0;
    while (i < objects.len) : (i += 1) {
        if (objects[i].common.active == false) {
            objects[i] = object;
            break;
        }
    }
    return &objects[i];
}

// room functions //
////////////////////

fn restart_room() void {
    will_restart = true;
    delay_restart = 15;
}

fn next_room() void {
    if (room.x == 2 and room.y == 1) {
        P8.music(30, 500, 7);
    } else if (room.x == 3 and room.y == 1) {
        P8.music(20, 500, 7);
    } else if (room.x == 4 and room.y == 2) {
        P8.music(30, 500, 7);
    } else if (room.x == 5 and room.y == 3) {
        P8.music(30, 500, 7);
    }

    if (room.x == 7) {
        load_room(0, room.y + 1);
    } else {
        load_room(room.x + 1, room.y);
    }
}

fn load_room(x: P8.num, y: P8.num) void {
    has_dashed = false;
    has_key = false;

    // remove existing objects
    for (&objects) |*obj| {
        destroy_object(&obj.common);
    }

    // current room
    room.x = x;
    room.y = y;

    // entities
    var tx: P8.num = 0;
    while (tx <= 15) : (tx += 1) {
        var ty: P8.num = 0;
        while (ty <= 15) : (ty += 1) {
            const tile = P8.mget(room.x * 16 + tx, room.y * 16 + ty);
            if (tile == 11) {
                var p = create_object(EntityType.platform, tx * 8, ty * 8);
                p.specific.platform.dir = -1;
            } else if (tile == 12) {
                var p = create_object(EntityType.platform, tx * 8, ty * 8);
                p.specific.platform.dir = 1;
            } else if (tile > 0) {
                for (all_entity_types) |et| {
                    if (tile == @intFromEnum(et)) {
                        init_object(et, tx * 8, ty * 8);
                    }
                }
            }
        }
    }

    if (!is_title()) {
        init_object(EntityType.room_title, 0, 0);
    }
}

// update function //
/////////////////////

fn _update() void {
    frames = @mod((frames + 1), 30);
    if (frames == 0 and level_index() < 30) {
        seconds = @mod((seconds + 1), 60);
        if (seconds == 0) {
            minutes += 1;
        }
    }

    if (music_timer > 0) {
        music_timer -= 1;
        if (music_timer <= 0) {
            P8.music(10, 0, 7);
        }
    }

    if (sfx_timer > 0) {
        sfx_timer -= 1;
    }

    // cancel if freeze
    if (freeze > 0) {
        freeze -= 1;
        return;
    }

    // screenshake
    if (shake > 0) {
        shake -= 1;
        P8.camera(0, 0);
        if (shake > 0) {
            P8.camera(-2 + P8.rnd(5), -2 + P8.rnd(5));
        }
    }

    // restart (soon)
    if (will_restart and delay_restart > 0) {
        delay_restart -= 1;
        if (delay_restart <= 0) {
            will_restart = false;
            load_room(room.x, room.y);
        }
    }

    // update each object
    for (&objects) |*obj| {
        update_object(obj);
    }

    // start game
    if (is_title()) {
        if (!start_game and (P8.btn(k_jump) or P8.btn(k_dash))) {
            P8.music(-1, 0, 0);
            start_game_flash = 50;
            start_game = true;
            P8.sfx(38);
        }
        if (start_game) {
            start_game_flash -= 1;
            if (start_game_flash <= -30) {
                begin_game();
            }
        }
    }
}

// drawing functions //
///////////////////////

fn _draw() void {
    if (freeze > 0) {
        return;
    }

    // reset all palette values
    P8.pal_reset();

    // start game flash
    if (start_game) {
        var c: P8.num = 10;
        if (start_game_flash > 10) {
            if (@mod(frames, 10) < 5) {
                c = 7;
            }
        } else if (start_game_flash > 5) {
            c = 2;
        } else if (start_game_flash > 0) {
            c = 1;
        } else {
            c = 0;
        }
        if (c < 10) {
            P8.pal(6, c);
            P8.pal(12, c);
            P8.pal(13, c);
            P8.pal(5, c);
            P8.pal(1, c);
            P8.pal(7, c);
        }
    }

    // clear screen
    var bg_col: P8.num = 0;
    if (flash_bg) {
        bg_col = frames / 5;
    } else if (new_bg) {
        bg_col = 2;
    }
    P8.rectfill(0, 0, 128, 128, bg_col);

    // clouds
    if (!is_title()) {
        for (&clouds) |*c| {
            c.x += c.spd;
            P8.rectfill(c.x, c.y, c.x + c.w, c.y + 4 + (1 - c.w / 64) * 12, if (new_bg) 14 else 1);
            if (c.x > 128) {
                c.x = -c.w;
                c.y = P8.rnd(128 - 8);
            }
        }
    }

    // draw bg terrain
    P8.map(room.x * 16, room.y * 16, 0, 0, 16, 16, 4);

    // -- platforms/big chest
    for (&objects) |*o| {
        if (o.common.entity_type == EntityType.platform or o.common.entity_type == EntityType.big_chest) {
            draw_object(o);
        }
    }

    // draw terrain
    const off: P8.num = if (is_title()) -4 else 0;
    P8.map(room.x * 16, room.y * 16, off, 0, 16, 16, 2);

    // draw objects
    for (&objects) |*o| {
        if (o.common.entity_type != EntityType.platform and o.common.entity_type != EntityType.big_chest) {
            draw_object(o);
        }
    }

    // draw fg terrain
    P8.map(room.x * 16, room.y * 16, 0, 0, 16, 16, 8);

    // -- particles
    for (&particles) |*p| {
        p.x += p.spd.x;
        p.y += P8.sin(p.off);
        p.off += P8.min(0.05, p.spd.x / 32);
        P8.rectfill(p.x, p.y, p.x + p.s, p.y + p.s, p.c);
        if (p.x > 128 + 4) {
            p.x = -4;
            p.y = P8.rnd(128);
        }
    }

    for (&dead_particles) |*p| {
        if (p.active) {
            p.x += p.spd.x;
            p.y += p.spd.y;
            p.t -= 1;
            if (p.t <= 0) {
                p.active = false;
            }
            P8.rectfill(p.x - p.t / 5, p.y - p.t / 5, p.x + p.t / 5, p.y + p.t / 5, 14 + @mod(p.t, 2));
        }
    }

    // draw outside of the screen for screenshake
    P8.rectfill(-5, -5, -1, 133, 0);
    P8.rectfill(-5, -5, 133, -1, 0);
    P8.rectfill(-5, 128, 133, 133, 0);
    P8.rectfill(128, -5, 133, 133, 0);

    // credits
    if (is_title()) {
        P8.print("x+c", 58, 80, 5);
        P8.print("matt thorson", 42, 96, 5);
        P8.print("noel berry", 46, 102, 5);
    }

    if (level_index() == 30) {
        var p: ?*Object = null;
        for (&objects) |*obj| {
            if (obj.common.entity_type == EntityType.player) {
                p = obj;
                break;
            }
        }
        if (p) |player| {
            const diff = P8.min(24, 40 - P8.abs(player.common.x + 4 - 64));
            P8.rectfill(0, 0, diff, 128, 0);
            P8.rectfill(128 - diff, 0, 128, 128, 0);
        }
    }
}

fn draw_object(object: *Object) void {
    if (object.common.active) {
        switch (object.specific) {
            EntityType.balloon => |*b| {
                b.draw(&object.common);
            },
            EntityType.big_chest => |*b| {
                b.draw(&object.common);
            },
            EntityType.fall_floor => |*ff| {
                ff.draw(&object.common);
            },
            EntityType.fake_wall => |*fw| {
                fw.draw(&object.common);
            },
            EntityType.flag => |*f| {
                f.draw(&object.common);
            },
            EntityType.fly_fruit => |*ff| {
                ff.draw(&object.common);
            },
            EntityType.life_up => |*lu| {
                lu.draw(&object.common);
            },
            EntityType.message => |*m| {
                m.draw(&object.common);
            },
            EntityType.orb => |*o| {
                o.draw(&object.common);
            },
            EntityType.platform => |*p| {
                p.draw(&object.common);
            },
            EntityType.player_spawn => |*ps| {
                ps.draw(&object.common);
            },
            EntityType.player => |*p| {
                p.draw(&object.common);
            },
            EntityType.room_title => |*rt| {
                rt.draw(&object.common);
            },
            EntityType.chest, EntityType.fruit, EntityType.key, EntityType.smoke, EntityType.spring => {
                if (object.common.spr > 0) {
                    P8.spr(object.common.spr, object.common.x, object.common.y, 1, 1, object.common.flip_x, object.common.flip_y);
                }
            },
        }
    }
}

fn draw_time(x: P8.num, y: P8.num) void {
    const s: u32 = @intFromFloat(seconds);
    const m: u32 = @intFromFloat(@mod(minutes, 60));
    const h: u32 = @intFromFloat(@divTrunc(minutes, 60));

    P8.rectfill(x, y, x + 32, y + 6, 0);
    //	print((h<10 and "0"..h or h)..":"..(m<10 and "0"..m or m)..":"..(s<10 and "0"..s or s),x+1,y+1,7)
    var str: [20]u8 = undefined;
    @memset(&str, 0);
    _ = std.fmt.bufPrint(&str, "{:0>2}:{:0>2}:{:0>2} ", .{ h, m, s }) catch {
        return;
    };
    P8.print(&str, x + 1, y + 1, 7);
}

//// TODO: to be reintegrated at the proper place
/////////////////////////////////////////////////

fn kill_player(player: *Player, common: *ObjectCommon) void {
    _ = player;
    sfx_timer = 12;
    P8.sfx(0);
    deaths += 1;
    shake = 10;
    destroy_object(common);
    var dir: P8.num = 0;
    for (&dead_particles) |*p| {
        const angle = (dir / 8);
        p.active = true;
        p.x = common.x + 4;
        p.y = common.y + 4;
        p.t = 10;
        p.spd = P8Point{
            .x = P8.sin(angle) * 3,
            .y = P8.cos(angle) * 3,
        };
        dir += 1;
    }
    restart_room();
}

fn destroy_object(common: *ObjectCommon) void {
    common.active = false;
}

fn update_object(object: *Object) void {
    if (object.common.active) {
        object.common.move(object.common.spd.x, object.common.spd.y);
        switch (object.specific) {
            EntityType.balloon => |*b| {
                b.update(&object.common);
            },
            EntityType.big_chest => |_| {},
            EntityType.chest => |*c| {
                c.update(&object.common);
            },
            EntityType.fall_floor => |*ff| {
                ff.update(&object.common);
            },
            EntityType.fake_wall => |*fw| {
                fw.update(&object.common);
            },
            EntityType.flag => |_| {},
            EntityType.fly_fruit => |*ff| {
                ff.update(&object.common);
            },
            EntityType.fruit => |*f| {
                f.update(&object.common);
            },
            EntityType.key => |*k| {
                k.update(&object.common);
            },
            EntityType.life_up => |*lu| {
                lu.update(&object.common);
            },
            EntityType.message => |_| {},
            EntityType.orb => |_| {},
            EntityType.platform => |*p| {
                p.update(&object.common);
            },
            EntityType.player_spawn => |*ps| {
                ps.update(&object.common);
            },
            EntityType.player => |*p| {
                p.update(&object.common);
            },
            EntityType.smoke => |*s| {
                s.update(&object.common);
            },
            EntityType.spring => |*s| {
                s.update(&object.common);
            },
            EntityType.room_title => |_| {},
        }
    }
}

fn tile_at(x: P8.num, y: P8.num) p8tile {
    return P8.mget(room.x * 16 + x, room.y * 16 + y);
}

fn spikes_at(x: P8.num, y: P8.num, w: P8.num, h: P8.num, xspd: P8.num, yspd: P8.num) bool {
    var i: P8.num = P8.max(0, P8.flr(x / 8));
    while (i <= P8.min(15, (x + w - 1) / 8)) : (i += 1) {
        var j: P8.num = P8.max(0, P8.flr(y / 8));
        while (j <= P8.min(15, (y + h - 1) / 8)) : (j += 1) {
            const tile = tile_at(i, j);
            if (tile == 17 and (@mod(y + h - 1, 8) >= 6 or y + h == j * 8 + 8) and yspd >= 0) {
                return true;
            } else if (tile == 27 and @mod(y, 8) <= 2 and yspd <= 0) {
                return true;
            } else if (tile == 43 and @mod(x, 8) <= 2 and xspd <= 0) {
                return true;
            } else if (tile == 59 and (@mod(x + w - 1, 8) >= 6 or x + w == i * 8 + 8) and xspd >= 0) {
                return true;
            }
        }
    }
    return false;
}

fn tile_flag_at(x: P8.num, y: P8.num, w: P8.num, h: P8.num, flag: P8.num) bool {
    var i: P8.num = P8.max(0, @divTrunc(x, 8));
    while (i <= P8.min(15, (x + w - 1) / 8)) : (i += 1) {
        var j = P8.max(0, @divTrunc(y, 8));
        while (j <= P8.min(15, (y + h - 1) / 8)) : (j += 1) {
            if (P8.fget(@intCast(tile_at(i, j)), flag)) {
                return true;
            }
        }
    }
    return false;
}

fn maybe() bool {
    return P8.rnd(1) < 0.5;
}

fn solid_at(x: P8.num, y: P8.num, w: P8.num, h: P8.num) bool {
    return tile_flag_at(x, y, w, h, 0);
}

fn ice_at(x: P8.num, y: P8.num, w: P8.num, h: P8.num) bool {
    return tile_flag_at(x, y, w, h, 4);
}

fn clamp(x: P8.num, a: P8.num, b: P8.num) P8.num {
    return P8.max(a, P8.min(b, x));
}

fn appr(val: P8.num, target: P8.num, amount: P8.num) P8.num {
    return if (val > target) P8.max(val - amount, target) else P8.min(val + amount, target);
}

fn sign(v: P8.num) P8.num {
    return if (v > 0) 1 else (if (v < 0) -1 else 0);
}
