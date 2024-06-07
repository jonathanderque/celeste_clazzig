const std = @import("std");
const p8 = @import("p8.zig");
const P8API = p8.API;
const P8Point = p8.P8Point;
const P8Rect = p8.P8Rect;

const FRUIT_COUNT: usize = 30;

pub fn celeste(comptime p8_api: P8API) type {
    return struct {

        // globals //
        /////////////
        var new_bg: bool = false;
        var frames: P8API.num = 0;
        var deaths: P8API.num = 0;
        var max_djump: P8API.num = 0;
        var start_game: bool = false;
        var start_game_flash: P8API.num = 0;
        var seconds: P8API.num = 0;
        var minutes: P8API.num = 0;

        var room: P8Point = P8Point{ .x = 0, .y = 0 };
        var objects: [30]Object = undefined;
        // types = {}
        var freeze: P8API.num = 0;
        var shake: P8API.num = 0;
        var will_restart: bool = false;
        var delay_restart: P8API.num = 0;
        var got_fruit: [30]bool = undefined;
        var has_dashed: bool = false;
        var sfx_timer: P8API.num = 0;
        var has_key: bool = false;
        var pause_player: bool = false;
        var flash_bg: bool = false;
        var music_timer: P8API.num = 0;

        // entry point //
        /////////////////

        pub fn _init() void {
            for (&objects) |*obj| {
                obj.common.active = false;
            }
            for (&clouds) |*c| {
                c.x = p8_api.rnd(128);
                c.y = p8_api.rnd(128);
                c.spd = 1 + p8_api.rnd(4);
                c.w = 32 + p8_api.rnd(32);
            }
            for (&dead_particles) |*particle| {
                particle.active = false;
            }
            for (&particles) |*p| {
                p.active = true;
                p.x = p8_api.rnd(128);
                p.y = p8_api.rnd(128);
                p.s = 0 + p8_api.flr(p8_api.rnd(5) / 4);
                p.spd = P8Point{ .x = 0.25 + p8_api.rnd(5), .y = 0 };
                p.off = p8_api.rnd(1);
                p.c = 6 + p8_api.flr(0.5 + p8_api.rnd(1));
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
            p8_api.music(40, 0, 7);
            load_room(7, 3);
            //load_room(5, 2);
        }

        fn begin_game() void {
            frames = 0;
            seconds = 0;
            minutes = 0;
            music_timer = 0;
            start_game = false;
            p8_api.music(0, 0, 7);
            load_room(0, 0);
        }

        fn level_index() P8API.num {
            return @mod(room.x, 8) + room.y * 8;
        }

        fn is_title() bool {
            return level_index() == 31;
        }

        // effects //
        /////////////

        const Cloud = struct {
            x: P8API.num,
            y: P8API.num,
            w: P8API.num,
            spd: P8API.num,
        };

        var clouds: [17]Cloud = undefined;

        const Particle = struct {
            active: bool,
            x: P8API.num,
            y: P8API.num,
            t: P8API.num = 0,
            h: P8API.num = 0,
            s: P8API.num = 0,
            off: P8API.num = 0,
            c: P8API.num = 0,
            spd: P8Point,
        };

        var particles: [25]Particle = undefined;
        var dead_particles: [8]Particle = undefined;

        // player entity //
        ///////////////////

        const Player = struct {
            p_jump: bool,
            p_dash: bool,
            grace: P8API.num,
            jbuffer: P8API.num,
            djump: P8API.num,
            dash_time: P8API.num,
            dash_effect_time: P8API.num,
            dash_target: P8Point,
            dash_accel: P8Point,
            spr_off: P8API.num,
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

                var input: P8API.num = 0;
                if (p8_api.btn(p8.k_left)) {
                    input = -1;
                } else if (p8_api.btn(p8.k_right)) {
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

                const jump = p8_api.btn(p8.k_jump) and !self.p_jump;
                self.p_jump = p8_api.btn(p8.k_jump);
                if (jump) {
                    self.jbuffer = 4;
                } else if (self.jbuffer > 0) {
                    self.jbuffer -= 1;
                }

                const dash = p8_api.btn(p8.k_dash) and !self.p_dash;
                self.p_dash = p8_api.btn(p8.k_dash);

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
                    const maxrun: P8API.num = 1;
                    var accel: P8API.num = 0.6;
                    const deccel: P8API.num = 0.15;

                    if (!on_ground) {
                        accel = 0.4;
                    } else if (on_ice) {
                        accel = 0.05;
                        const input_facing: P8API.num = if (common.flip_x) -1 else 1;
                        if (input == input_facing) {
                            accel = 0.05;
                        }
                    }

                    if (p8_api.abs(common.spd.x) > maxrun) {
                        common.spd.x = appr(common.spd.x, sign(common.spd.x) * maxrun, deccel);
                    } else {
                        common.spd.x = appr(common.spd.x, input * maxrun, accel);
                    }

                    //facing
                    if (common.spd.x != 0) {
                        common.flip_x = (common.spd.x < 0);
                    }

                    // gravity
                    var maxfall: P8API.num = 2;
                    var gravity: P8API.num = 0.21;

                    if (p8_api.abs(common.spd.y) <= 0.15) {
                        gravity *= 0.5;
                    }

                    // wall slide
                    if (input != 0 and common.is_solid(input, 0) and !common.is_ice(input, 0)) {
                        maxfall = 0.4;
                        if (p8_api.rnd(10) < 2) {
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
                            var wall_dir: P8API.num = if (common.is_solid(3, 0)) 1 else 0;
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
                    const d_full: P8API.num = 5;
                    const d_half: P8API.num = d_full * 0.70710678118;

                    if (self.djump > 0 and dash) {
                        init_object(EntityType.smoke, common.x, common.y);
                        self.djump -= 1;
                        self.dash_time = 4;
                        has_dashed = true;
                        self.dash_effect_time = 10;
                        var v_input: P8API.num = if (p8_api.btn(p8.k_down)) 1 else 0;
                        v_input = if (p8_api.btn(p8.k_up)) -1 else v_input;
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
                    } else if (p8_api.btn(p8.k_down)) {
                        common.spr = 6;
                    } else if (p8_api.btn(p8.k_up)) {
                        common.spr = 7;
                    } else if ((common.spd.x == 0) or (!p8_api.btn(p8.k_left) and !p8_api.btn(p8.k_right))) {
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
                p8_api.spr(common.spr, common.x, common.y, 1, 1, common.flip_x, common.flip_y);
                unset_hair_color();
            }
        };

        fn psfx(x: P8API.num) void {
            if (sfx_timer <= 0) {
                p8_api.sfx(x);
            }
        }

        const Hair = struct {
            x: P8API.num,
            y: P8API.num,
            size: P8API.num,
            isLast: bool,
        };

        fn create_hair(hair: []Hair, common: *ObjectCommon) void {
            var i: P8API.num = 0;
            while (i <= 4) : (i += 1) {
                hair[@intFromFloat(i)] = Hair{
                    .x = common.x,
                    .y = common.y,
                    .size = p8_api.max(1, p8_api.min(2, 3 - i)),
                    .isLast = (i == 4),
                };
            }
        }

        fn set_hair_color(djump: P8API.num) void {
            const col =
                if (djump == 1)
                8
            else
                (if (djump == 2)
                    (7 + p8_api.flr(@mod(frames / 3, 2)) * 4)
                else
                    12);
            p8_api.pal(8, col);
        }

        fn draw_hair(hair: []Hair, common: *ObjectCommon, facing: P8API.num) void {
            var last_x: P8API.num = common.x + 4 - facing * 2;
            var last_y: P8API.num = common.y;
            if (p8_api.btn(p8.k_down)) {
                last_y += 4;
            } else {
                last_y += 3;
            }
            for (hair) |*h| {
                h.x += (last_x - h.x) / 1.5;
                h.y += (last_y + 0.5 - h.y) / 1.5;
                p8_api.circfill(h.x, h.y, h.size, 8);
                last_x = h.x;
                last_y = h.y;
            }
        }

        fn unset_hair_color() void {
            p8_api.pal(8, 8);
        }

        const PlayerSpawn = struct {
            target: P8Point,
            state: P8API.num,
            delay: P8API.num,
            hair: [5]Hair,

            fn init(self: *PlayerSpawn, common: *ObjectCommon) void {
                p8_api.sfx(4);
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
                        p8_api.sfx(5);
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
                p8_api.spr(common.spr, common.x, common.y, 1, 1, common.flip_x, common.flip_y);
                unset_hair_color();
            }
        };

        const Spring = struct {
            hide_in: P8API.num,
            hide_for: P8API.num,
            delay: P8API.num,

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
                    const hit_opt = common.collide(EntityType.player, 0, 0);
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
                            const below_opt = common.collide(EntityType.fall_floor, 0, 1);
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
            timer: P8API.num,
            offset: P8API.num,
            start: P8API.num,

            //tile=22,
            fn init(self: *Balloon, common: *ObjectCommon) void {
                self.offset = p8_api.rnd(1);
                self.start = common.y;
                self.timer = 0;
                common.hitbox = P8Rect{ .x = -1, .y = -1, .w = 10, .h = 10 };
            }
            fn update(self: *Balloon, common: *ObjectCommon) void {
                if (common.spr == 22) {
                    self.offset += 0.01;
                    common.y = self.start + p8_api.sin(self.offset) * 2;
                    const hit_opt = common.collide(EntityType.player, 0, 0);
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
                    p8_api.spr(13 + @mod(self.offset * 8, 3), common.x, common.y + 6, 1, 1, false, false);
                    p8_api.spr(common.spr, common.x, common.y, 1, 1, false, false);
                }
            }
        };

        const FallFloor = struct {
            state: P8API.num,
            delay: P8API.num,

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
                        p8_api.spr(23, common.x, common.y, 1, 1, false, false);
                    } else {
                        p8_api.spr(23 + (15 - self.delay) / 5, common.x, common.y, 1, 1, false, false);
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
                const hit_opt = common.collide(EntityType.spring, 0, -1);
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
                common.spd.x = 0.3 + p8_api.rnd(0.2);
                common.x += -1 + p8_api.rnd(2);
                common.y += -1 + p8_api.rnd(2);
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
            start: P8API.num,
            off: P8API.num,
            //tile=26,
            //if_not_fruit=true,
            fn init(self: *Fruit, common: *ObjectCommon) void {
                self.start = common.y;
                self.off = 0;
            }

            fn update(self: *Fruit, common: *ObjectCommon) void {
                const hit_opt = common.collide(EntityType.player, 0, 0);
                if (hit_opt) |hit| {
                    hit.specific.player.djump = max_djump;
                    sfx_timer = 20;
                    p8_api.sfx(13);
                    got_fruit[@intFromFloat(level_index())] = true;
                    init_object(EntityType.life_up, common.x, common.y);
                    destroy_object(common);
                    return;
                }
                self.off += 1;
                common.y = self.start + p8_api.sin(self.off / 40) * 2.5;
            }
        };

        const FlyFruit = struct {
            fly: bool,
            step: P8API.num,
            sfx_delay: P8API.num,
            start: P8API.num,

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
                            p8_api.sfx(14);
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
                    common.spd.y = p8_api.sin(self.step) * 0.5;
                }
                // collect
                const hit_opt = common.collide(EntityType.player, 0, 0);
                if (hit_opt) |hit| {
                    hit.specific.player.djump = max_djump;
                    sfx_timer = 20;
                    p8_api.sfx(13);
                    got_fruit[@intFromFloat(level_index())] = true;
                    init_object(EntityType.life_up, common.x, common.y);
                    do_destroy = true;
                }
                if (do_destroy) {
                    destroy_object(common);
                }
            }

            fn draw(self: *FlyFruit, common: *ObjectCommon) void {
                var off: P8API.num = 0;
                if (!self.fly) {
                    const dir = p8_api.sin(self.step);
                    if (dir < 0) {
                        off = 1 + p8_api.max(0, sign(common.y - self.start));
                    }
                } else {
                    off = @mod(off + 0.25, 3);
                }
                p8_api.spr(45 + off, common.x - 6, common.y - 2, 1, 1, true, false);
                p8_api.spr(common.spr, common.x, common.y, 1, 1, false, false);
                p8_api.spr(45 + off, common.x + 6, common.y - 2, 1, 1, false, false);
            }
        };

        const LifeUp = struct {
            duration: P8API.num,
            flash: P8API.num,

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
                p8_api.print("1000", common.x - 2, common.y, 7 + @mod(self.flash, 2));
            }
        };

        const FakeWall = struct {
            fn update(self: *FakeWall, common: *ObjectCommon) void {
                _ = self;
                common.hitbox = P8Rect{ .x = -1, .y = -1, .w = 18, .h = 18 };
                const hit_opt = common.collide(EntityType.player, 0, 0);
                if (hit_opt) |hit| {
                    if (hit.specific.player.dash_effect_time > 0) {
                        hit.common.spd.x = -sign(hit.common.spd.x) * 1.5;
                        hit.common.spd.y = -1.5;
                        hit.specific.player.dash_time = -1;
                        sfx_timer = 20;
                        p8_api.sfx(16);
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
                p8_api.spr(64, common.x, common.y, 1, 1, false, false);
                p8_api.spr(65, common.x + 8, common.y, 1, 1, false, false);
                p8_api.spr(80, common.x, common.y + 8, 1, 1, false, false);
                p8_api.spr(81, common.x + 8, common.y + 8, 1, 1, false, false);
            }
        };

        const Key = struct {
            // tile=8,
            // if_not_fruit=true,
            fn update(self: *Key, common: *ObjectCommon) void {
                _ = self;
                const was = common.spr;
                common.spr = 9 + (p8_api.sin(frames / 30) + 0.5) * 1;
                const is = common.spr;
                if (is == 10 and is != was) {
                    common.flip_x = !common.flip_x;
                }
                if (common.check(EntityType.player, 0, 0)) {
                    p8_api.sfx(23);
                    sfx_timer = 10;
                    destroy_object(common);
                    has_key = true;
                }
            }
        };

        const Chest = struct {
            timer: P8API.num,
            start: P8API.num,

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
                    common.x = self.start - 1 + p8_api.rnd(3);
                    if (self.timer <= 0) {
                        sfx_timer = 20;
                        p8_api.sfx(16);
                        init_object(EntityType.fruit, common.x, common.y - 4);
                        destroy_object(common);
                    }
                }
            }
        };

        const Platform = struct {
            last: P8API.num,
            dir: P8API.num,

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
                    const hit_opt = common.collide(EntityType.player, 0, -1);
                    if (hit_opt) |hit| {
                        hit.common.move_x(common.x - self.last, 1);
                    }
                }
                self.last = common.x;
            }

            fn draw(self: *Platform, common: *ObjectCommon) void {
                _ = self;
                p8_api.spr(11, common.x, common.y - 1, 1, 1, false, false);
                p8_api.spr(12, common.x + 8, common.y - 1, 1, 1, false, false);
            }
        };

        const Message = struct {
            text: []const u8,
            index: P8API.num,
            last: P8API.num,
            off: P8Point,

            fn draw(self: *Message, common: *ObjectCommon) void {
                self.text = "-- celeste mountain --#this memorial to those# perished on the climb";
                if (common.check(EntityType.player, 4, 0)) {
                    if (self.index < @as(P8API.num, @floatFromInt(self.text.len))) {
                        self.index += 0.5;
                        if (self.index >= self.last + 1) {
                            self.last += 1;
                            p8_api.sfx(35);
                        }
                    }
                    self.off = P8Point{ .x = 8, .y = 96 };
                    var i: P8API.num = 0;
                    while (i < self.index) : (i += 1) {
                        if (self.text[@intFromFloat(i)] != '#') {
                            p8_api.rectfill(self.off.x - 2, self.off.y - 2, self.off.x + 7, self.off.y + 6, 7);
                            p8_api.print(self.text[@intFromFloat(i)..@intFromFloat(1 + i)], self.off.x, self.off.y, 0);
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
            state: P8API.num,
            timer: P8API.num,
            particle_count: P8API.num,
            particles: [50]Particle,

            fn init(self: *BigChest, common: *ObjectCommon) void {
                self.state = 0;
                common.hitbox.w = 16;
            }

            fn draw(self: *BigChest, common: *ObjectCommon) void {
                if (self.state == 0) {
                    const hit_opt = common.collide(EntityType.player, 0, 8);
                    if (hit_opt) |hit| {
                        if (hit.common.is_solid(0, 1)) {
                            p8_api.music(-1, 500, 7);
                            p8_api.sfx(37);
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
                    p8_api.spr(96, common.x, common.y, 1, 1, false, false);
                    p8_api.spr(97, common.x + 8, common.y, 1, 1, false, false);
                } else if (self.state == 1) {
                    self.timer -= 1;
                    shake = 5;
                    flash_bg = true;
                    if (self.timer <= 45 and self.particle_count < 50) {
                        self.particles[@intFromFloat(self.particle_count)] = Particle{
                            .active = true,
                            .x = 1 + p8_api.rnd(14),
                            .y = 0,
                            .h = 32 + p8_api.rnd(32),
                            .spd = P8Point{
                                .x = 0,
                                .y = 8 + p8_api.rnd(8),
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
                        p8_api.line(common.x + p.x, common.y + 8 - p.y, common.x + p.x, p8_api.min(common.y + 8 - p.y + p.h, common.y + 8), 7);
                    }
                }
                p8_api.spr(112, common.x, common.y + 8, 1, 1, false, false);
                p8_api.spr(113, common.x + 8, common.y + 8, 1, 1, false, false);
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
                const hit_opt = common.collide(EntityType.player, 0, 0);
                if (hit_opt) |hit| {
                    if (common.spd.y == 0) {
                        music_timer = 45;
                        p8_api.sfx(51);
                        freeze = 10;
                        shake = 10;
                        destroy_object(common);
                        max_djump = 2;
                        hit.specific.player.djump = 2;
                        return;
                    }
                }

                p8_api.spr(102, common.x, common.y, 1, 1, false, false);
                const off: P8API.num = frames / 30;
                var i: P8API.num = 0;
                while (i <= 7) : (i += 1) {
                    p8_api.circfill(common.x + 4 + p8_api.cos(off + i / 8) * 8, common.y + 4 + p8_api.sin(off + i / 8) * 8, 1, 7);
                }
            }
        };

        const Flag = struct {
            show: bool,
            score: P8API.num,

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
                p8_api.spr(common.spr, common.x, common.y, 1, 1, false, false);
                if (self.show) {
                    var str: [20]u8 = undefined;
                    @memset(&str, 0);
                    p8_api.rectfill(32, 2, 96, 31, 0);
                    p8_api.spr(26, 55, 6, 1, 1, false, false);
                    _ = std.fmt.bufPrint(&str, "x {} ", .{@as(usize, @intFromFloat(self.score))}) catch {
                        return;
                    };
                    p8_api.print(&str, 64, 9, 7);
                    draw_time(49, 16);
                    _ = std.fmt.bufPrint(&str, "deaths {} ", .{@as(usize, @intFromFloat(deaths))}) catch {
                        return;
                    };
                    p8_api.print(&str, 48, 24, 7);
                } else if (common.check(EntityType.player, 0, 0)) {
                    p8_api.sfx(55);
                    sfx_timer = 30;
                    self.show = true;
                }
            }
        };

        const RoomTitle = struct {
            delay: P8API.num,

            fn init(self: *RoomTitle) void {
                self.delay = 5;
            }
            fn draw(self: *RoomTitle, common: *ObjectCommon) void {
                self.delay -= 1;
                if (self.delay < -30) {
                    destroy_object(common);
                } else if (self.delay < 0) {
                    p8_api.rectfill(24, 58, 104, 70, 0);
                    if (room.x == 3 and room.y == 1) {
                        p8_api.print("old site", 48, 62, 7);
                    } else if (level_index() == 30) {
                        p8_api.print("summit", 52, 62, 7);
                    } else {
                        const level = (1 + level_index()) * 100;
                        var str: [16]u8 = undefined;
                        @memset(&str, 0);
                        _ = std.fmt.bufPrint(&str, "{} m", .{@as(i32, @intFromFloat(level))}) catch {
                            return;
                        };
                        const offset: P8API.num = if (level < 1000) 2 else 0;
                        p8_api.print(&str, 52 + offset, 62, 7);
                    }
                    //print("//-",86,64-2,13)

                    draw_time(4, 4);
                }
            }
        };

        const EntityType = enum(P8API.tile) {
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
            x: P8API.num,
            y: P8API.num,
            hitbox: P8Rect,
            spd: P8Point,
            rem: P8Point,
            spr: P8API.num,
            flip_x: bool,
            flip_y: bool,
            solids: bool,
            collideable: bool,

            fn init(self: *ObjectCommon, x: P8API.num, y: P8API.num, entity_type: EntityType) void {
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

            fn collide(self: *ObjectCommon, entity_type: EntityType, ox: P8API.num, oy: P8API.num) ?*Object {
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

            fn check(self: *ObjectCommon, entity_type: EntityType, ox: P8API.num, oy: P8API.num) bool {
                return self.collide(entity_type, ox, oy) != null;
            }

            fn is_ice(self: *ObjectCommon, ox: P8API.num, oy: P8API.num) bool {
                return ice_at(self.x + self.hitbox.x + ox, self.y + self.hitbox.y + oy, self.hitbox.w, self.hitbox.h);
            }

            fn move(self: *ObjectCommon, ox: P8API.num, oy: P8API.num) void {
                var amount: P8API.num = 0;

                self.rem.x += ox;
                amount = p8_api.flr(self.rem.x + 0.5);
                self.rem.x -= amount;
                self.move_x(amount, 0);

                self.rem.y += oy;
                amount = p8_api.flr(self.rem.y + 0.5);
                self.rem.y -= amount;
                self.move_y(amount);
            }

            fn move_x(self: *ObjectCommon, amount: P8API.num, start: P8API.num) void {
                if (self.solids) {
                    const step = sign(amount);
                    var i: P8API.num = start;
                    while (i <= p8_api.abs(amount)) : (i += 1) { // i <= amount
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

            fn move_y(self: *ObjectCommon, amount: P8API.num) void {
                if (self.solids) {
                    const step = sign(amount);
                    var i: P8API.num = 0;
                    while (i <= p8_api.abs(amount)) : (i += 1) {
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

            fn is_solid(self: *ObjectCommon, ox: P8API.num, oy: P8API.num) bool {
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

        fn init_object(etype: EntityType, x: P8API.num, y: P8API.num) void {
            _ = create_object(etype, x, y);
        }

        fn create_object(etype: EntityType, x: P8API.num, y: P8API.num) *Object {
            if (etype.if_not_fruit() and got_fruit[@intFromFloat(level_index())]) {
                return undefined;
            }

            var common: ObjectCommon = undefined;
            common.init(x, y, etype);
            const specific: ObjectSpecific =
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
                    const f: FakeWall = FakeWall{};
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
                    const k: Key = Key{};
                    break :blk ObjectSpecific{ .key = k };
                },
                EntityType.life_up => blk: {
                    var s: LifeUp = undefined;
                    s.init(&common);
                    break :blk ObjectSpecific{ .life_up = s };
                },
                EntityType.message => blk: {
                    const m: Message = undefined;
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
                p8_api.music(30, 500, 7);
            } else if (room.x == 3 and room.y == 1) {
                p8_api.music(20, 500, 7);
            } else if (room.x == 4 and room.y == 2) {
                p8_api.music(30, 500, 7);
            } else if (room.x == 5 and room.y == 3) {
                p8_api.music(30, 500, 7);
            }

            if (room.x == 7) {
                load_room(0, room.y + 1);
            } else {
                load_room(room.x + 1, room.y);
            }
        }

        fn load_room(x: P8API.num, y: P8API.num) void {
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
            var tx: P8API.num = 0;
            while (tx <= 15) : (tx += 1) {
                var ty: P8API.num = 0;
                while (ty <= 15) : (ty += 1) {
                    const tile = p8_api.mget(room.x * 16 + tx, room.y * 16 + ty);
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

        pub fn _update() void {
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
                    p8_api.music(10, 0, 7);
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
                p8_api.camera(0, 0);
                if (shake > 0) {
                    p8_api.camera(-2 + p8_api.rnd(5), -2 + p8_api.rnd(5));
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
                if (!start_game and (p8_api.btn(p8.k_jump) or p8_api.btn(p8.k_dash))) {
                    p8_api.music(-1, 0, 0);
                    start_game_flash = 50;
                    start_game = true;
                    p8_api.sfx(38);
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

        pub fn _draw() void {
            if (freeze > 0) {
                return;
            }

            // reset all palette values
            p8_api.pal_reset();

            // start game flash
            if (start_game) {
                var c: P8API.num = 10;
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
                    p8_api.pal(6, c);
                    p8_api.pal(12, c);
                    p8_api.pal(13, c);
                    p8_api.pal(5, c);
                    p8_api.pal(1, c);
                    p8_api.pal(7, c);
                }
            }

            // clear screen
            var bg_col: P8API.num = 0;
            if (flash_bg) {
                bg_col = frames / 5;
            } else if (new_bg) {
                bg_col = 2;
            }
            p8_api.rectfill(0, 0, 128, 128, bg_col);

            // clouds
            if (!is_title()) {
                for (&clouds) |*c| {
                    c.x += c.spd;
                    p8_api.rectfill(c.x, c.y, c.x + c.w, c.y + 4 + (1 - c.w / 64) * 12, if (new_bg) 14 else 1);
                    if (c.x > 128) {
                        c.x = -c.w;
                        c.y = p8_api.rnd(128 - 8);
                    }
                }
            }

            // draw bg terrain
            p8_api.map(room.x * 16, room.y * 16, 0, 0, 16, 16, 4);

            // -- platforms/big chest
            for (&objects) |*o| {
                if (o.common.entity_type == EntityType.platform or o.common.entity_type == EntityType.big_chest) {
                    draw_object(o);
                }
            }

            // draw terrain
            const off: P8API.num = if (is_title()) -4 else 0;
            p8_api.map(room.x * 16, room.y * 16, off, 0, 16, 16, 2);

            // draw objects
            for (&objects) |*o| {
                if (o.common.entity_type != EntityType.platform and o.common.entity_type != EntityType.big_chest) {
                    draw_object(o);
                }
            }

            // draw fg terrain
            p8_api.map(room.x * 16, room.y * 16, 0, 0, 16, 16, 8);

            // -- particles
            for (&particles) |*p| {
                p.x += p.spd.x;
                p.y += p8_api.sin(p.off);
                p.off += p8_api.min(0.05, p.spd.x / 32);
                p8_api.rectfill(p.x, p.y, p.x + p.s, p.y + p.s, p.c);
                if (p.x > 128 + 4) {
                    p.x = -4;
                    p.y = p8_api.rnd(128);
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
                    p8_api.rectfill(p.x - p.t / 5, p.y - p.t / 5, p.x + p.t / 5, p.y + p.t / 5, 14 + @mod(p.t, 2));
                }
            }

            // draw outside of the screen for screenshake
            p8_api.rectfill(-5, -5, -1, 133, 0);
            p8_api.rectfill(-5, -5, 133, -1, 0);
            p8_api.rectfill(-5, 128, 133, 133, 0);
            p8_api.rectfill(128, -5, 133, 133, 0);

            // credits
            if (is_title()) {
                p8_api.print("x+c", 58, 80, 5);
                p8_api.print("matt thorson", 42, 96, 5);
                p8_api.print("noel berry", 46, 102, 5);
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
                    const diff = p8_api.min(24, 40 - p8_api.abs(player.common.x + 4 - 64));
                    p8_api.rectfill(0, 0, diff, 128, 0);
                    p8_api.rectfill(128 - diff, 0, 128, 128, 0);
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
                            p8_api.spr(object.common.spr, object.common.x, object.common.y, 1, 1, object.common.flip_x, object.common.flip_y);
                        }
                    },
                }
            }
        }

        fn draw_time(x: P8API.num, y: P8API.num) void {
            const s: u32 = @intFromFloat(seconds);
            const m: u32 = @intFromFloat(@mod(minutes, 60));
            const h: u32 = @intFromFloat(@divTrunc(minutes, 60));

            p8_api.rectfill(x, y, x + 32, y + 6, 0);
            //	print((h<10 and "0"..h or h)..":"..(m<10 and "0"..m or m)..":"..(s<10 and "0"..s or s),x+1,y+1,7)
            var str: [20]u8 = undefined;
            @memset(&str, 0);
            _ = std.fmt.bufPrint(&str, "{:0>2}:{:0>2}:{:0>2} ", .{ h, m, s }) catch {
                return;
            };
            p8_api.print(&str, x + 1, y + 1, 7);
        }

        //// TODO: to be reintegrated at the proper place
        /////////////////////////////////////////////////

        fn kill_player(player: *Player, common: *ObjectCommon) void {
            _ = player;
            sfx_timer = 12;
            p8_api.sfx(0);
            deaths += 1;
            shake = 10;
            destroy_object(common);
            var dir: P8API.num = 0;
            for (&dead_particles) |*p| {
                const angle = (dir / 8);
                p.active = true;
                p.x = common.x + 4;
                p.y = common.y + 4;
                p.t = 10;
                p.spd = P8Point{
                    .x = p8_api.sin(angle) * 3,
                    .y = p8_api.cos(angle) * 3,
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

        fn tile_at(x: P8API.num, y: P8API.num) P8API.tile {
            return p8_api.mget(room.x * 16 + x, room.y * 16 + y);
        }

        fn spikes_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, xspd: P8API.num, yspd: P8API.num) bool {
            var i: P8API.num = p8_api.max(0, p8_api.flr(x / 8));
            while (i <= p8_api.min(15, (x + w - 1) / 8)) : (i += 1) {
                var j: P8API.num = p8_api.max(0, p8_api.flr(y / 8));
                while (j <= p8_api.min(15, (y + h - 1) / 8)) : (j += 1) {
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

        fn tile_flag_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, flag: P8API.num) bool {
            var i: P8API.num = p8_api.max(0, @divTrunc(x, 8));
            while (i <= p8_api.min(15, (x + w - 1) / 8)) : (i += 1) {
                var j = p8_api.max(0, @divTrunc(y, 8));
                while (j <= p8_api.min(15, (y + h - 1) / 8)) : (j += 1) {
                    if (p8_api.fget(@intCast(tile_at(i, j)), flag)) {
                        return true;
                    }
                }
            }
            return false;
        }

        fn maybe() bool {
            return p8_api.rnd(1) < 0.5;
        }

        fn solid_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num) bool {
            return tile_flag_at(x, y, w, h, 0);
        }

        fn ice_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num) bool {
            return tile_flag_at(x, y, w, h, 4);
        }

        fn clamp(x: P8API.num, a: P8API.num, b: P8API.num) P8API.num {
            return p8_api.max(a, p8_api.min(b, x));
        }

        fn appr(val: P8API.num, target: P8API.num, amount: P8API.num) P8API.num {
            return if (val > target) p8_api.max(val - amount, target) else p8_api.min(val + amount, target);
        }

        fn sign(v: P8API.num) P8API.num {
            return if (v > 0) 1 else (if (v < 0) -1 else 0);
        }
    };
}
