const std = @import("std");
const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});
const Surface = sdl.SDL_Surface;
const Window = sdl.SDL_Window;
const Renderer = sdl.SDL_Renderer;
const Texture = sdl.SDL_Texture;

const p8 = @import("p8.zig");
const P8API = p8.API;
const cart_data = @import("generated/celeste.zig");
const font = @import("font.zig").font;
const audio = @import("audio.zig");
const AudioEngine = audio.AudioEngine;

const celeste = @import("celeste.zig");

pub fn n(_n: anytype) P8API.num {
    return P8API.num.from_int(_n);
}

pub fn nf(_n: f32) P8API.num {
    return P8API.num.from_float(_n);
}

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

var palette: [16]sdl.SDL_Color = undefined;

// SDL globals
var screen: *Window = undefined;
var renderer: *Renderer = undefined;
var gfx_texture: *Texture = undefined;
var base_font_textures: [16]*Texture = undefined;
var font_textures: [16]*Texture = undefined;
var should_reload_gfx_texture: bool = false;

fn load_texture(r: *Renderer, spritesheet: []const u8, width: usize, height: usize) ?*Texture {
    const surface = sdl.SDL_CreateRGBSurface(0, @intCast(width), @intCast(height), 32, 0, 0, 0, 0);
    defer sdl.SDL_FreeSurface(surface);

    const format = surface.*.format;
    const c = palette[0];
    const color_key = sdl.SDL_MapRGB(format, c.r, c.g, c.b);
    _ = sdl.SDL_SetColorKey(surface, sdl.SDL_TRUE, color_key);

    const surface_renderer = sdl.SDL_CreateSoftwareRenderer(surface);
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
    while (i < base_font_textures.len) : (i += 1) {
        if (i == 0) {
            // HACK: needed for Old-Site Memorial message:
            // we really want palette[0] here, but black on black does not work
            palette[7] = sdl.SDL_Color{ .r = 0x01, .g = 0x00, .b = 0x00, .a = 0xff };
        } else {
            palette[7] = base_palette[@mod(i, 16)];
        }
        if (load_texture(r, &font, 128, 85)) |texture| {
            base_font_textures[i] = texture;
        } else {
            sdl.SDL_Log("Unable to create texture from surface: %s", sdl.SDL_GetError());
        }
    }
    p8_api.pal_reset();
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

fn released_key(key: P8API.num) bool {
    const k: u3 = key.to_int(u3);
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
    const stream = arg_stream;
    var len = arg_len;
    var snd: [*c]c_short = @as([*c]c_short, @ptrCast(@alignCast(stream)));
    len = @divTrunc(len, @sizeOf(c_short));

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const sample = audio_engine.sample();

        snd[i] = @as(c_short, @intFromFloat(sample * 32767));
    }
}

const PauseMenu = struct {
    pause: bool,
    quit: bool,
    fullscreen: bool,
    screen_shake: bool,

    option_index: usize,

    fn init() PauseMenu {
        return PauseMenu{
            .pause = false,
            .quit = false,
            .fullscreen = false,
            .screen_shake = false,
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
        if (released_key(p8.k_up)) {
            if (self.option_index == 0) {
                self.option_index = option_ys.len - 1;
            } else {
                self.option_index -= 1;
            }
        }
        if (released_key(p8.k_down)) {
            self.option_index += 1;
            if (self.option_index >= option_ys.len) {
                self.option_index = 0;
            }
        }
        if (released_key(p8.k_jump) or released_key(p8.k_dash) or released_key(p8.k_left) or released_key(p8.k_right)) {
            switch (self.option_index) {
                0 => {
                    self.toggle_pause();
                },
                1 => {
                    self.quit = true;
                },
                2 => {
                    self.fullscreen = !self.fullscreen;
                    set_fullscreen(self.fullscreen);
                },
                3 => {
                    self.screen_shake = !self.screen_shake;
                },
                4 => {
                    if (released_key(p8.k_left) and audio_engine.global_volume >= 10) {
                        audio_engine.global_volume -= 10;
                    }
                    if (released_key(p8.k_right) and audio_engine.global_volume <= 90) {
                        audio_engine.global_volume += 10;
                    }
                },
                else => unreachable,
            }
        }
    }

    const cursor_symbol = 143;
    const option_ys = [_]P8API.num{ n(12), n(19), n(40), n(47), n(68) };
    fn draw(self: *PauseMenu) void {
        if (!self.pause) {
            return;
        }

        const title_x = n(6);
        const cursor_x = title_x;
        const option_x = title_x.add(n(8));

        p8_api.rectfill(title_x.sub(n(2)), n(4), n(103), n(75), n(0));
        p8_api.print("celeste clazzig", title_x, n(5), n(7));
        p8_api.print("RESUME", option_x, option_ys[0], n(7));
        p8_api.print("QUIT", option_x, option_ys[1], n(7));
        p8_api.print("graphics options", title_x, option_ys[2].sub(n(7)), n(7));
        if (self.fullscreen) {
            p8_api.print("FULLSCREEN: on", option_x, option_ys[2], n(7));
        } else {
            p8_api.print("FULLSCREEN: off", option_x, option_ys[2], n(7));
        }
        if (self.screen_shake) {
            p8_api.print("SCREEN SHAKE: on", option_x, option_ys[3], n(7));
        } else {
            p8_api.print("SCREEN SHAKE: off", option_x, option_ys[3], n(7));
        }
        p8_api.print("sound options", title_x, option_ys[4].sub(n(7)), n(7));
        p8_api.print("GLOBAL VOLUME:", option_x, option_ys[4], n(7));

        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const rect_x: P8API.num = n(65).add(title_x).add(n(3 * i));
            const rect_y: P8API.num = n(2).add(option_ys[4]);
            if (10 * i >= audio_engine.global_volume) {
                p8_api.rectfill(rect_x, rect_y, rect_x.add(n(1)), rect_y.add(n(1)), n(7));
            } else {
                p8_api.rectfill(rect_x, rect_y.sub(n(2)), rect_x.add(n(1)), rect_y.add(n(2)), n(7));
            }
        }
        draw_symbol(cursor_symbol, cursor_x.to_int(c_int), option_ys[self.option_index].to_int(c_int), 7);
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

fn set_fullscreen(fullscreen: bool) void {
    const flag: u32 = if (fullscreen) sdl.SDL_WINDOW_FULLSCREEN_DESKTOP else 0;
    _ = sdl.SDL_SetWindowFullscreen(screen, flag);
    resize_window_callback();
}

fn draw_view_port_borders() void {
    const c = palette[0];
    _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = 0, .w = view_port.x, .h = view_port.window_h });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = view_port.window_w - view_port.x, .y = 0, .w = view_port.x, .h = view_port.window_h });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = 0, .w = view_port.window_w, .h = view_port.y });
    _ = sdl.SDL_RenderFillRect(renderer, &sdl.SDL_Rect{ .x = 0, .y = view_port.window_h - view_port.y, .w = view_port.window_w, .h = view_port.y });
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
        for (base_font_textures) |texture| {
            sdl.SDL_DestroyTexture(texture);
        }
    }
    p8_api.pal_reset();
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

    const audio_device = sdl.SDL_OpenAudioDevice(0, 0, &desired_audio_spec, &obtained_audio_spec, 0);
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

    const SDLCeleste = celeste.celeste(p8_api);

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
        const one: u8 = 1;
        var key_left: u8 = if (current_key_states[sdl.SDL_SCANCODE_LEFT] != 0) (one << p8.k_left.to_int(u3)) else 0;
        var key_right: u8 = if (current_key_states[sdl.SDL_SCANCODE_RIGHT] != 0) (one << p8.k_right.to_int(u3)) else 0;
        var key_up: u8 = if (current_key_states[sdl.SDL_SCANCODE_UP] != 0) (one << p8.k_up.to_int(u3)) else 0;
        var key_down: u8 = if (current_key_states[sdl.SDL_SCANCODE_DOWN] != 0) (one << p8.k_down.to_int(u3)) else 0;
        var key_jump: u8 = if (current_key_states[sdl.SDL_SCANCODE_Z] != 0) (one << p8.k_jump.to_int(u3)) else 0;
        var key_dash: u8 = if (current_key_states[sdl.SDL_SCANCODE_X] != 0) (one << p8.k_dash.to_int(u3)) else 0;
        var key_menu: u8 = if (current_key_states[sdl.SDL_SCANCODE_ESCAPE] != 0) (one << p8.k_menu.to_int(u3)) else 0;

        if (current_key_states[sdl.SDLK_z] != 0) {
            key_jump = one << p8.k_jump.to_int(u3);
        }
        if (current_key_states[sdl.SDLK_x] != 0) {
            key_dash = one << p8.k_dash.to_int(u3);
        }

        if (controller) |_| {
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_LEFT) != 0) {
                key_left = one << p8.k_left.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_RIGHT) != 0) {
                key_right = one << p8.k_right.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_UP) != 0) {
                key_up = one << p8.k_up.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_DPAD_DOWN) != 0) {
                key_down = one << p8.k_down.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_A) != 0 or sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_Y) != 0) {
                key_jump = one << p8.k_jump.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_B) != 0 or sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_X) != 0) {
                key_dash = one << p8.k_dash.to_int(u3);
            }
            if (sdl.SDL_GameControllerGetButton(controller, sdl.SDL_CONTROLLER_BUTTON_START) != 0) {
                key_menu = one << p8.k_menu.to_int(u3);
            }
        }

        button_state = key_left | key_right | key_up | key_down | key_up | key_jump | key_dash | key_menu;

        if (sdl.SDL_GetPerformanceCounter() >= nextFrame) {
            while (sdl.SDL_GetPerformanceCounter() >= nextFrame) {
                if (released_key(p8.k_menu)) {
                    pause_menu.toggle_pause();
                }
                // update
                if (should_init) {
                    SDLCeleste._init();
                    should_init = false;
                }
                if (pause_menu.pause) {
                    pause_menu.update();
                } else {
                    SDLCeleste._update();
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
                draw_view_port_borders();
            } else {
                SDLCeleste._draw();
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

fn p8_btn(button: P8API.num) bool {
    const one: u8 = 1;
    return (button_state & (one << button.to_int(u3)) != 0);
}
fn p8_sfx(id: P8API.num) void {
    const sfx_id: usize = id.to_int(usize);
    audio_engine.play_sfx(sfx_id);
}

fn p8_music(id: P8API.num, fade: P8API.num, mask: P8API.num) void {
    const music_id: isize = id.to_int(isize);
    audio_engine.play_music(music_id, fade.to_int(u32), mask.to_int(u32));
}
fn p8_pal_reset() void {
    var i: usize = 0;
    while (i < palette.len) : (i += 1) {
        palette[i] = base_palette[i];
        font_textures[i] = base_font_textures[i];
    }
    should_reload_gfx_texture = true;
}

fn p8_pal(x: P8API.num, y: P8API.num) void {
    const xi: usize = x.to_int(usize);
    palette[xi] = base_palette[y.to_int(usize)];
    font_textures[xi] = base_font_textures[y.to_int(usize)];
    should_reload_gfx_texture = true;
}

var camera_x: P8API.num = n(0);
var camera_y: P8API.num = n(0);
fn p8_camera(x: P8API.num, y: P8API.num) void {
    if (pause_menu.screen_shake) {
        camera_x = x;
        camera_y = y;
    }
}

fn p8_print(str: []const u8, x_arg: P8API.num, y_arg: P8API.num, col: P8API.num) void {
    const col_idx: usize = col.mod(n(16)).to_int(usize);
    var x: c_int = x_arg.sub(camera_x).to_int(c_int);
    const y: c_int = y_arg.sub(camera_y).to_int(c_int);

    for (str) |cconst| {
        var c = cconst;
        c = c & 0x7F;

        draw_symbol(c, x, y, col_idx);

        x = x + 4;
    }
}

fn screen_rect(x: P8API.num, y: P8API.num, w: c_int, h: c_int) sdl.SDL_Rect {
    const scale = @as(c_int, @intCast(view_port.scale));
    var rect: sdl.SDL_Rect = undefined;
    rect.x = x.sub(camera_x).to_int(c_int) * scale + view_port.x;
    rect.y = y.sub(camera_y).to_int(c_int) * scale + view_port.y;
    rect.w = w * scale;
    rect.h = h * scale;
    //std.log.debug("dest_rect({d:6.1}, {d:6.1}, {}, {}) -> {}", .{ x, y, w, h, rect });
    return rect;
}

fn p8_line(x1: P8API.num, y1: P8API.num, x2: P8API.num, y2: P8API.num, col: P8API.num) void {
    const c = palette[col.mod(n(palette.len)).to_int(usize)];
    _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);

    if (x1.ne(x2)) {
        std.log.err("only vertical lines are supported ({d:6.1},{d:6.1})({d:6.1},{d:6.1})", .{ x1.to_float(f32), y1.to_float(f32), x2.to_float(f32), y2.to_float(f32) });
        return;
    }

    _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x1, y1.min(y2), 1, y2.sub(y1).add(n(1)).to_int(c_int)));
}

fn p8_rectfill(x1: P8API.num, y1: P8API.num, x2: P8API.num, y2: P8API.num, col: P8API.num) void {
    const c = palette[col.mod(n(palette.len)).to_int(usize)];
    _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);

    const rect = screen_rect(x1, y1, x2.sub(x1).add(n(1)).to_int(c_int), y2.sub(y1).add(n(1)).to_int(c_int));
    _ = sdl.SDL_RenderFillRect(renderer, &rect);
}

fn p8_circfill(x: P8API.num, y: P8API.num, r: P8API.num, col: P8API.num) void {
    const c = palette[col.mod(n(palette.len)).to_int(usize)];
    _ = sdl.SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 0xff);
    if (r.le(n(1))) {
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(1)), y, 3, 1));
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x, y.sub(n(1)), 1, 3));
    } else if (r.le(n(2))) {
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(2)), y.sub(n(1)), 5, 3));
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(1)), y.sub(n(2)), 3, 5));
    } else if (r.le(n(3))) {
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(3)), y.sub(n(1)), 7, 3));
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(1)), y.sub(n(3)), 3, 7));
        _ = sdl.SDL_RenderFillRect(renderer, &screen_rect(x.sub(n(2)), y.sub(n(2)), 5, 5));
    }
}

fn p8_spr(sprite: P8API.num, x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, flip_x: bool, flip_y: bool) void {
    _ = w;
    _ = h;
    _ = flip_y;

    reload_textures(renderer);

    if (sprite.ge(n(0))) {
        var src_rect: sdl.SDL_Rect = undefined;
        src_rect.x = sprite.mod(n(16)).to_int(c_int) * 8;
        src_rect.y = sprite.divTrunc(n(16)).to_int(c_int) * 8;
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
fn p8_fget(tile: usize, flag: P8API.num) bool {
    const f: u5 = flag.to_int(u5);
    const one: u32 = 1;
    return tile < cart_data.gff.len and (cart_data.gff[tile] & (one << f)) != 0;
}

// map
fn p8_map(cel_x: P8API.num, cel_y: P8API.num, screen_x: P8API.num, screen_y: P8API.num, cel_w: P8API.num, cel_h: P8API.num, mask: P8API.num) void {
    reload_textures(renderer);

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
                    var src_rect: sdl.SDL_Rect = undefined;
                    src_rect.x = @intCast(8 * @mod(tile, 16));
                    src_rect.y = @intCast(8 * @divTrunc(tile, 16));
                    src_rect.w = @intCast(8);
                    src_rect.h = @intCast(8);

                    const dst_rect = screen_rect(screen_x.add(x.mul(n(8))), screen_y.add(y.mul(n(8))), 8, 8);

                    _ = sdl.SDL_RenderCopy(renderer, gfx_texture, &src_rect, &dst_rect);
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
