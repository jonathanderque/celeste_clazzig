pub const P8Point = struct {
    x: API.num,
    y: API.num,
};
pub const P8Rect = struct {
    x: API.num,
    y: API.num,
    w: API.num,
    h: API.num,
};

pub const k_left: API.num = 0;
pub const k_right: API.num = 1;
pub const k_up: API.num = 2;
pub const k_down: API.num = 3;
pub const k_jump: API.num = 4;
pub const k_dash: API.num = 5;
pub const k_menu: API.num = 6;

pub const API = struct {
    pub const num = f32;
    pub const tile = i8;

    // input
    btn: *const fn (button: num) bool,

    // sound
    sfx: *const fn (id: num) void,
    music: *const fn (id: num, fade: num, mask: num) void,

    // colors / palette
    pal_reset: *const fn () void,
    pal: *const fn (x: num, y: num) void,

    // camera / viewport
    camera: *const fn (x: num, y: num) void,

    // text printing
    print: *const fn (str: []const u8, x_arg: num, y_arg: num, col: num) void,

    // shapes
    line: *const fn (x1: num, y1: num, x2: num, y2: num, col: num) void,
    rectfill: *const fn (x1: num, y1: num, x2: num, y2: num, col: num) void,
    circfill: *const fn (x: num, y: num, r: num, col: num) void,

    // sprites
    spr: *const fn (sprite: num, x: num, y: num, w: num, h: num, flip_x: bool, flip_y: bool) void,
    fget: *const fn (tile: usize, flag: num) bool,
    map: *const fn (cel_x: num, cel_y: num, screen_x: num, screen_y: num, cel_w: num, cel_h: num, mask: num) void,
    mget: *const fn (tx: num, ty: num) tile,

    // math
    abs: *const fn (n: num) num,
    flr: *const fn (n: num) num,
    min: *const fn (n1: num, n2: num) num,
    max: *const fn (n1: num, n2: num) num,
    rnd: *const fn (rnd_max: num) num,
    sin: *const fn (x: num) num,
    cos: *const fn (x: num) num,
};
