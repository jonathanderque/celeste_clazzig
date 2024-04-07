const std = @import("std");
const p8 = @import("p8.zig");
const P8API = p8.API;
const P8Point = p8.P8Point;
const P8Rect = p8.P8Rect;

const FRUIT_COUNT: usize = 30;

pub fn n(x: anytype) P8API.num {
    return P8API.num.from_int(x);
}

pub fn nf(_n: f32) P8API.num {
    return P8API.num.from_float(_n);
}

pub fn celeste(comptime p8_api: P8API) type {
    return struct {

        // globals //
        /////////////
        var new_bg: bool = false;
        var frames: P8API.num = n(0);
        var deaths: P8API.num = n(0);
        var max_djump: P8API.num = n(0);
        var start_game: bool = false;
        var start_game_flash: P8API.num = n(0);
        var seconds: P8API.num = n(0);
        var minutes: P8API.num = n(0);

        var room: P8Point = P8Point{ .x = n(0), .y = n(0) };
        var objects: [30]Object = undefined;
        // types = {}
        var freeze: P8API.num = n(0);
        var shake: P8API.num = n(0);
        var will_restart: bool = false;
        var delay_restart: P8API.num = n(0);
        var got_fruit: [30]bool = undefined;
        var has_dashed: bool = false;
        var sfx_timer: P8API.num = n(0);
        var has_key: bool = false;
        var pause_player: bool = false;
        var flash_bg: bool = false;
        var music_timer: P8API.num = n(0);

        // entry point //
        /////////////////

        pub fn _init() void {
            for (&objects) |*obj| {
                obj.common.active = false;
            }
            for (&clouds) |*c| {
                c.x = p8_api.rnd(n(128));
                c.y = p8_api.rnd(n(128));
                c.spd = p8_api.rnd(n(4)).add(n(1));
                c.w = p8_api.rnd(n(32)).add(n(32));
            }
            for (&dead_particles) |*particle| {
                particle.active = false;
            }
            for (&particles) |*p| {
                p.active = true;
                p.x = p8_api.rnd(n(128));
                p.y = p8_api.rnd(n(128));
                p.s = p8_api.flr(p8_api.rnd(n(5)).div(n(4)));
                p.spd = P8Point{ .x = nf(0.25).add(p8_api.rnd(n(5))), .y = n(0) };
                p.off = p8_api.rnd(n(1));
                p.c = n(6).add(p8_api.flr(nf(0.5).add(p8_api.rnd(n(1)))));
            }
            title_screen();
        }

        fn title_screen() void {
            // std.debug.print("title screen\n", .{});
            for (0..30) |i| { // 0 <= i <= 29
                got_fruit[i] = false;
            }
            frames = n(0);
            deaths = n(0);
            max_djump = n(1);
            start_game = false;
            start_game_flash = n(0);
            p8_api.music(n(40), n(0), n(7));
            load_room(n(7), n(3));
            //load_room(n(5), n(2));
        }

        fn begin_game() void {
            frames = n(0);
            seconds = n(0);
            minutes = n(0);
            music_timer = n(0);
            start_game = false;
            p8_api.music(n(0), n(0), n(7));
            load_room(n(0), n(0));
        }

        fn level_index() P8API.num {
            return room.x.mod(n(8)).add(room.y.mul(n(8)));
        }

        fn is_title() bool {
            return level_index().eq(n(31));
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
            t: P8API.num = n(0),
            h: P8API.num = n(0),
            s: P8API.num = n(0),
            off: P8API.num = n(0),
            c: P8API.num = n(0),
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
                self.grace = n(0);
                self.jbuffer = n(0);
                self.djump = max_djump;
                self.dash_time = n(0);
                self.dash_effect_time = n(0);
                self.dash_target = P8Point{ .x = n(0), .y = n(0) };
                self.dash_accel = P8Point{ .x = n(0), .y = n(0) };
                common.hitbox = P8Rect{ .x = n(1), .y = n(3), .w = n(6), .h = n(5) };
                self.spr_off = n(0);
                self.was_on_ground = false;
                common.spr = n(5);
                create_hair(&self.hair, common);
            }

            fn update(self: *Player, common: *ObjectCommon) void {
                if (pause_player) return;

                var input: P8API.num = n(0);
                if (p8_api.btn(p8.k_left)) {
                    input = n(-1);
                } else if (p8_api.btn(p8.k_right)) {
                    input = n(1);
                }

                // spikes collide
                if (spikes_at(common.x.add(common.hitbox.x), common.y.add(common.hitbox.y), common.hitbox.w, common.hitbox.h, common.spd.x, common.spd.y)) {
                    kill_player(self, common);
                    return;
                }

                // bottom death
                if (common.y.gt(n(128))) {
                    kill_player(self, common);
                    return;
                }

                const on_ground = common.is_solid(n(0), n(1));
                const on_ice = common.is_ice(n(0), n(1));

                // smoke particles
                if (on_ground and !self.was_on_ground) {
                    init_object(EntityType.smoke, common.x, common.y.add(n(4)));
                }

                const jump = p8_api.btn(p8.k_jump) and !self.p_jump;
                self.p_jump = p8_api.btn(p8.k_jump);
                if (jump) {
                    self.jbuffer = n(4);
                } else if (self.jbuffer.gt(n(0))) {
                    self.jbuffer = self.jbuffer.sub(n(1));
                }

                const dash = p8_api.btn(p8.k_dash) and !self.p_dash;
                self.p_dash = p8_api.btn(p8.k_dash);

                if (on_ground) {
                    self.grace = n(6);
                    if (self.djump.lt(max_djump)) {
                        psfx(n(54));
                        self.djump = max_djump;
                    }
                } else if (self.grace.gt(n(0))) {
                    self.grace = self.grace.sub(n(1));
                }

                self.dash_effect_time = self.dash_effect_time.sub(n(1));
                if (self.dash_time.gt(n(0))) {
                    init_object(EntityType.smoke, common.x, common.y);
                    self.dash_time = self.dash_time.sub(n(1));
                    common.spd.x = appr(common.spd.x, self.dash_target.x, self.dash_accel.x);
                    common.spd.y = appr(common.spd.y, self.dash_target.y, self.dash_accel.y);
                } else {

                    // move
                    var maxrun: P8API.num = n(1);
                    var accel: P8API.num = nf(0.6);
                    const deccel: P8API.num = nf(0.15);

                    if (!on_ground) {
                        accel = nf(0.4);
                    } else if (on_ice) {
                        accel = nf(0.05);
                        const input_facing: P8API.num = if (common.flip_x) n(-1) else n(1);
                        if (input.eq(input_facing)) {
                            accel = nf(0.05);
                        }
                    }

                    if (p8_api.abs(common.spd.x).gt(maxrun)) {
                        common.spd.x = appr(common.spd.x, sign(common.spd.x).mul(maxrun), deccel);
                    } else {
                        common.spd.x = appr(common.spd.x, input.mul(maxrun), accel);
                    }

                    //facing
                    if (common.spd.x.ne(n(0))) {
                        common.flip_x = common.spd.x.lt(n(0));
                    }

                    // gravity
                    var maxfall: P8API.num = n(2);
                    var gravity: P8API.num = nf(0.21);

                    if (p8_api.abs(common.spd.y).le(nf(0.15))) {
                        gravity = gravity.mul(nf(0.5));
                    }

                    // wall slide
                    if (input.ne(n(0)) and common.is_solid(input, n(0)) and !common.is_ice(input, n(0))) {
                        maxfall = nf(0.4);
                        if (p8_api.rnd(n(10)).lt(n(2))) {
                            init_object(EntityType.smoke, common.x.add(input.mul(n(6))), common.y);
                        }
                    }

                    if (!on_ground) {
                        common.spd.y = appr(common.spd.y, maxfall, gravity);
                    }

                    // jump
                    if (self.jbuffer.gt(n(0))) {
                        if (self.grace.gt(n(0))) {
                            // normal jump
                            psfx(n(1));
                            self.jbuffer = n(0);
                            self.grace = n(0);
                            common.spd.y = n(-2);
                            init_object(EntityType.smoke, common.x, common.y.add(n(4)));
                        } else {
                            // wall jump
                            var wall_dir: P8API.num = if (common.is_solid(n(3), n(0))) n(1) else n(0);
                            wall_dir = if (common.is_solid(n(-3), n(0))) n(-1) else wall_dir;
                            if (wall_dir.ne(n(0))) {
                                psfx(n(2));
                                self.jbuffer = n(0);
                                common.spd.y = n(-2);
                                common.spd.x = wall_dir.neg().mul(maxrun.add(n(1)));
                                if (!common.is_ice(wall_dir.mul(n(3)), n(0))) {
                                    init_object(EntityType.smoke, common.x.add(wall_dir.mul(n(6))), common.y);
                                }
                            }
                        }
                    }

                    // dash
                    const d_full: P8API.num = n(5);
                    const d_half: P8API.num = d_full.mul(nf(0.70710678118));

                    if (self.djump.gt(n(0)) and dash) {
                        init_object(EntityType.smoke, common.x, common.y);
                        self.djump = self.djump.sub(n(1));
                        self.dash_time = n(4);
                        has_dashed = true;
                        self.dash_effect_time = n(10);
                        var v_input: P8API.num = if (p8_api.btn(p8.k_down)) n(1) else n(0);
                        v_input = if (p8_api.btn(p8.k_up)) n(-1) else v_input;
                        if (input.ne(n(0))) {
                            if (v_input.ne(n(0))) {
                                common.spd.x = input.mul(d_half);
                                common.spd.y = v_input.mul(d_half);
                            } else {
                                common.spd.x = input.mul(d_full);
                                common.spd.y = n(0);
                            }
                        } else if (v_input.ne(n(0))) {
                            common.spd.x = n(0);
                            common.spd.y = v_input.mul(d_full);
                        } else {
                            common.spd.x = if (common.flip_x) n(-1) else n(1);
                            common.spd.y = n(0);
                        }

                        psfx(n(3));
                        freeze = n(2);
                        shake = n(6);
                        self.dash_target.x = n(2).mul(sign(common.spd.x));
                        self.dash_target.y = n(2).mul(sign(common.spd.y));
                        self.dash_accel.x = nf(1.5);
                        self.dash_accel.y = nf(1.5);

                        if (common.spd.y.lt(n(0))) {
                            self.dash_target.y = self.dash_target.y.mul(nf(0.75));
                        }

                        if (common.spd.y.ne(n(0))) {
                            self.dash_accel.x = self.dash_accel.x.mul(nf(0.70710678118));
                        }
                        if (common.spd.x.ne(n(0))) {
                            self.dash_accel.y = self.dash_accel.y.mul(nf(0.70710678118));
                        }
                    } else if (dash and self.djump.le(n(0))) {
                        psfx(n(9));
                        init_object(EntityType.smoke, common.x, common.y);
                    }
                    self.spr_off = self.spr_off.add(nf(0.25));
                    if (!on_ground) {
                        if (common.is_solid(input, n(0))) {
                            common.spr = n(5);
                        } else {
                            common.spr = n(3);
                        }
                    } else if (p8_api.btn(p8.k_down)) {
                        common.spr = n(6);
                    } else if (p8_api.btn(p8.k_up)) {
                        common.spr = n(7);
                    } else if (common.spd.x.eq(n(0)) or (!p8_api.btn(p8.k_left) and !p8_api.btn(p8.k_right))) {
                        common.spr = n(1);
                    } else {
                        common.spr = n(1).add(self.spr_off.mod(n(4)));
                    }

                    // next level
                    if (common.y.lt(n(-4)) and level_index().lt(n(30))) {
                        next_room();
                    }

                    // was on the ground
                    self.was_on_ground = on_ground;
                }
            }

            fn draw(self: *Player, common: *ObjectCommon) void {
                // clamp in screen
                if (common.x.lt(n(-1)) or common.x.gt(n(121))) {
                    common.x = clamp(common.x, n(-1), n(121));
                    common.spd.x = n(0);
                }

                set_hair_color(self.djump);
                draw_hair(&self.hair, common, if (common.flip_x) n(-1) else n(1));
                p8_api.spr(common.spr, common.x, common.y, n(1), n(1), common.flip_x, common.flip_y);
                unset_hair_color();
            }
        };

        fn psfx(x: P8API.num) void {
            if (sfx_timer.le(n(0))) {
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
            var i: P8API.num = n(0);
            while (i.le(n(4))) : (i = i.add(n(1))) {
                hair[i.to_int(usize)] = Hair{
                    .x = common.x,
                    .y = common.y,
                    .size = p8_api.max(n(1), p8_api.min(n(2), n(3).sub(i))),
                    .isLast = (i.eq(n(4))),
                };
            }
        }

        fn set_hair_color(djump: P8API.num) void {
            const col =
                if (djump.eq(n(1)))
                n(8)
            else
                (if (djump.eq(n(2)))
                    n(7).add(p8_api.flr(frames.div(n(3)).mod(n(2))).mul(n(4)))
                else
                    n(12));
            p8_api.pal(n(8), col);
        }

        fn draw_hair(hair: []Hair, common: *ObjectCommon, facing: P8API.num) void {
            var last_x: P8API.num = common.x.add(n(4)).sub(facing.mul(n(2)));
            var last_y: P8API.num = common.y;
            if (p8_api.btn(p8.k_down)) {
                last_y = last_y.add(n(4));
            } else {
                last_y = last_y.add(n(3));
            }
            for (hair) |*h| {
                h.x = h.x.add(last_x.sub(h.x).div(nf(1.5)));
                h.y = h.y.add(last_y.add(nf(0.5)).sub(h.y).div(nf(1.5)));
                p8_api.circfill(h.x, h.y, h.size, n(8));
                last_x = h.x;
                last_y = h.y;
            }
        }

        fn unset_hair_color() void {
            p8_api.pal(n(8), n(8));
        }

        const PlayerSpawn = struct {
            target: P8Point,
            state: P8API.num,
            delay: P8API.num,
            hair: [5]Hair,

            fn init(self: *PlayerSpawn, common: *ObjectCommon) void {
                p8_api.sfx(n(4));
                common.spr = n(3);
                self.target.x = common.x;
                self.target.y = common.y;
                common.y = n(128);
                common.spd.y = n(-4);
                self.state = n(0);
                self.delay = n(0);
                common.solids = false;
                create_hair(&self.hair, common);
            }

            fn update(self: *PlayerSpawn, common: *ObjectCommon) void {
                if (self.state.eq(n(0))) { // jumping up
                    if (common.y.lt(self.target.y.add(n(16)))) {
                        self.state = n(1);
                        self.delay = n(3);
                    }
                } else if (self.state.eq(n(1))) { // falling
                    common.spd.y = common.spd.y.add(nf(0.5));
                    if (common.spd.y.gt(n(0)) and self.delay.gt(n(0))) {
                        common.spd.y = n(0);
                        self.delay = self.delay.sub(n(1));
                    }
                    if (common.spd.y.gt(n(0)) and common.y.gt(self.target.y)) {
                        common.y = self.target.y;
                        common.spd = P8Point{ .x = n(0), .y = n(0) };
                        self.state = n(2);
                        self.delay = n(5);
                        shake = n(5);
                        init_object(EntityType.smoke, common.x, common.y.add(n(4)));
                        p8_api.sfx(n(5));
                    }
                } else if (self.state.eq(n(2))) { // landing
                    self.delay = self.delay.sub(n(1));
                    common.spr = n(6);
                    if (self.delay.lt(n(0))) {
                        destroy_object(common);
                        init_object(EntityType.player, common.x, common.y);
                    }
                }
            }

            fn draw(self: *PlayerSpawn, common: *ObjectCommon) void {
                set_hair_color(max_djump);
                draw_hair(&self.hair, common, n(1));
                p8_api.spr(common.spr, common.x, common.y, n(1), n(1), common.flip_x, common.flip_y);
                unset_hair_color();
            }
        };

        const Spring = struct {
            hide_in: P8API.num,
            hide_for: P8API.num,
            delay: P8API.num,

            fn init(self: *Spring, common: *ObjectCommon) void {
                _ = common;
                self.hide_in = n(0);
                self.hide_for = n(0);
            }

            fn update(self: *Spring, common: *ObjectCommon) void {
                if (self.hide_for.gt(n(0))) {
                    self.hide_for = self.hide_for.sub(n(1));
                    if (self.hide_for.le(n(0))) {
                        common.spr = n(18);
                        self.delay = n(0);
                    }
                } else if (common.spr.eq(n(18))) {
                    const hit_opt = common.collide(EntityType.player, n(0), n(0));
                    if (hit_opt) |hit| {
                        if (hit.common.spd.y.ge(n(0))) {
                            common.spr = n(19);
                            hit.common.y = common.y.sub(n(4));
                            hit.common.spd.x = hit.common.spd.x.mul(nf(0.2));
                            hit.common.spd.y = n(-3);
                            hit.specific.player.djump = max_djump;
                            self.delay = n(10);
                            init_object(EntityType.smoke, common.x, common.y);

                            // breakable below us
                            const below_opt = common.collide(EntityType.fall_floor, n(0), n(1));
                            if (below_opt) |below| {
                                break_fall_floor(&below.specific.fall_floor, &below.common);
                            }

                            psfx(n(8));
                        }
                    }
                } else if (self.delay.gt(n(0))) {
                    self.delay = self.delay.sub(n(1));
                    if (self.delay.le(n(0))) {
                        common.spr = n(18);
                    }
                }
                // begin hiding
                if (self.hide_in.gt(n(0))) {
                    self.hide_in = self.hide_in.sub(n(1));
                    if (self.hide_in.le(n(0))) {
                        self.hide_for = n(60);
                        common.spr = n(0);
                    }
                }
            }
        };

        fn break_spring(self: *Spring) void {
            self.hide_in = n(15);
        }

        const Balloon = struct {
            timer: P8API.num,
            offset: P8API.num,
            start: P8API.num,

            //tile=22,
            fn init(self: *Balloon, common: *ObjectCommon) void {
                self.offset = p8_api.rnd(n(1));
                self.start = common.y;
                self.timer = n(0);
                common.hitbox = P8Rect{ .x = n(-1), .y = n(-1), .w = n(10), .h = n(10) };
            }
            fn update(self: *Balloon, common: *ObjectCommon) void {
                if (common.spr.eq(n(22))) {
                    self.offset = self.offset.add(nf(0.01));
                    common.y = self.start.add(p8_api.sin(self.offset).mul(n(2)));
                    const hit_opt = common.collide(EntityType.player, n(0), n(0));
                    if (hit_opt) |hit| {
                        if (hit.specific.player.djump.lt(max_djump)) {
                            psfx(n(6));
                            init_object(EntityType.smoke, common.x, common.y);
                            hit.specific.player.djump = max_djump;
                            common.spr = n(0);
                            self.timer = n(60);
                        }
                    }
                } else if (self.timer.gt(n(0))) {
                    self.timer = self.timer.sub(n(1));
                } else {
                    psfx(n(7));
                    init_object(EntityType.smoke, common.x, common.y);
                    common.spr = n(22);
                }
            }
            fn draw(self: *Balloon, common: *ObjectCommon) void {
                if (common.spr.eq(n(22))) {
                    p8_api.spr(n(13).add(self.offset.mul(n(8)).mod(n(3))), common.x, common.y.add(n(6)), n(1), n(1), false, false);
                    p8_api.spr(common.spr, common.x, common.y, n(1), n(1), false, false);
                }
            }
        };

        const FallFloor = struct {
            state: P8API.num,
            delay: P8API.num,

            fn init(self: *FallFloor, common: *ObjectCommon) void {
                self.state = n(0);
                _ = common;
                // common.solid = true; // Typo in the original game
            }

            fn update(self: *FallFloor, common: *ObjectCommon) void {
                if (self.state.eq(n(0))) { // idling
                    if (common.check(EntityType.player, n(0), n(-1)) or common.check(EntityType.player, n(-1), n(0)) or common.check(EntityType.player, n(1), n(0))) {
                        break_fall_floor(self, common);
                    }
                } else if (self.state.eq(n(1))) { // shaking
                    self.delay = self.delay.sub(n(1));
                    if (self.delay.le(n(0))) {
                        self.state = n(2);
                        self.delay = n(60); // how long it hides for
                        common.collideable = false;
                    }
                } else if (self.state.eq(n(2))) { // invisible, waiting to reset
                    self.delay = self.delay.sub(n(1));
                    if (self.delay.le(n(0)) and !common.check(EntityType.player, n(0), n(0))) {
                        psfx(n(7));
                        self.state = n(0);
                        common.collideable = true;
                        init_object(EntityType.smoke, common.x, common.y);
                    }
                }
            }

            fn draw(self: *FallFloor, common: *ObjectCommon) void {
                if (self.state.ne(n(2))) {
                    if (self.state.ne(n(1))) {
                        p8_api.spr(n(23), common.x, common.y, n(1), n(1), false, false);
                    } else {
                        p8_api.spr(n(23).add(n(15).sub(self.delay).div(n(5))), common.x, common.y, n(1), n(1), false, false);
                    }
                }
            }
        };

        fn break_fall_floor(self: *FallFloor, common: *ObjectCommon) void {
            if (self.state.eq(n(0))) {
                psfx(n(15));
                self.state = n(1);
                self.delay = n(15); // how long until it falls
                init_object(EntityType.smoke, common.x, common.y);
                const hit_opt = common.collide(EntityType.spring, n(0), n(-1));
                if (hit_opt) |hit| {
                    break_spring(&hit.specific.spring);
                }
            }
        }

        const Smoke = struct {
            fn init(self: *Smoke, common: *ObjectCommon) void {
                _ = self;
                common.spr = n(29);
                common.spd.y = nf(-0.1);
                common.spd.x = nf(0.3).add(p8_api.rnd(nf(0.2)));
                common.x = common.x.add(n(-1).add(p8_api.rnd(n(2))));
                common.y = common.y.add(n(-1).add(p8_api.rnd(n(2))));
                common.flip_x = maybe();
                common.flip_y = maybe();
                common.solids = false;
            }
            fn update(self: *Smoke, common: *ObjectCommon) void {
                _ = self;
                common.spr = common.spr.add(nf(0.2));
                if (common.spr.ge(n(32))) {
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
                self.off = n(0);
            }

            fn update(self: *Fruit, common: *ObjectCommon) void {
                const hit_opt = common.collide(EntityType.player, n(0), n(0));
                if (hit_opt) |hit| {
                    hit.specific.player.djump = max_djump;
                    sfx_timer = n(20);
                    p8_api.sfx(n(13));
                    got_fruit[level_index().to_int(usize)] = true;
                    init_object(EntityType.life_up, common.x, common.y);
                    destroy_object(common);
                    return;
                }
                self.off = self.off.add(n(1));
                common.y = self.start.add(p8_api.sin(self.off.div(n(40))).mul(nf(2.5)));
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
                self.step = nf(0.5);
                common.solids = false;
                self.sfx_delay = n(8);
            }

            fn update(self: *FlyFruit, common: *ObjectCommon) void {
                var do_destroy = false;
                //fly away
                if (self.fly) {
                    if (self.sfx_delay.gt(n(0))) {
                        self.sfx_delay = self.sfx_delay.sub(n(1));
                        if (self.sfx_delay.le(n(0))) {
                            sfx_timer = n(20);
                            p8_api.sfx(n(14));
                        }
                    }
                    common.spd.y = appr(common.spd.y, nf(-3.5), nf(0.25));
                    if (common.y.lt(n(-16))) {
                        do_destroy = true;
                    }
                } else {
                    if (has_dashed) {
                        self.fly = true;
                    }
                    self.step = self.step.add(nf(0.05));
                    common.spd.y = p8_api.sin(self.step).mul(nf(0.5));
                }
                // collect
                const hit_opt = common.collide(EntityType.player, n(0), n(0));
                if (hit_opt) |hit| {
                    hit.specific.player.djump = max_djump;
                    sfx_timer = n(20);
                    p8_api.sfx(n(13));
                    got_fruit[level_index().to_int(usize)] = true;
                    init_object(EntityType.life_up, common.x, common.y);
                    do_destroy = true;
                }
                if (do_destroy) {
                    destroy_object(common);
                }
            }

            fn draw(self: *FlyFruit, common: *ObjectCommon) void {
                var off: P8API.num = n(0);
                if (!self.fly) {
                    var dir = p8_api.sin(self.step);
                    if (dir.lt(n(0))) {
                        off = n(1).add(p8_api.max(n(0), sign(common.y.sub(self.start))));
                    }
                } else {
                    off = off.add(nf(0.25)).mod(n(3));
                }
                p8_api.spr(n(45).add(off), common.x.sub(n(6)), common.y.sub(n(2)), n(1), n(1), true, false);
                p8_api.spr(common.spr, common.x, common.y, n(1), n(1), false, false);
                p8_api.spr(n(45).add(off), common.x.add(n(6)), common.y.sub(n(2)), n(1), n(1), false, false);
            }
        };

        const LifeUp = struct {
            duration: P8API.num,
            flash: P8API.num,

            fn init(self: *LifeUp, common: *ObjectCommon) void {
                common.spd.y = nf(-0.25);
                self.duration = n(30);
                common.x = common.x.sub(n(2));
                common.y = common.y.sub(n(4));
                self.flash = n(0);
                common.solids = false;
            }

            fn update(self: *LifeUp, common: *ObjectCommon) void {
                self.duration = self.duration.sub(n(1));
                if (self.duration.le(n(0))) {
                    destroy_object(common);
                }
            }
            fn draw(self: *LifeUp, common: *ObjectCommon) void {
                self.flash = self.flash.add(nf(0.5));
                p8_api.print("1000", common.x.sub(n(2)), common.y, n(7).add(self.flash.mod(n(2))));
            }
        };

        const FakeWall = struct {
            fn update(self: *FakeWall, common: *ObjectCommon) void {
                _ = self;
                common.hitbox = P8Rect{ .x = n(-1), .y = n(-1), .w = n(18), .h = n(18) };
                const hit_opt = common.collide(EntityType.player, n(0), n(0));
                if (hit_opt) |hit| {
                    if (hit.specific.player.dash_effect_time.gt(n(0))) {
                        hit.common.spd.x = sign(hit.common.spd.x).neg().mul(nf(1.5));
                        hit.common.spd.y = nf(-1.5);
                        hit.specific.player.dash_time = n(-1);
                        sfx_timer = n(20);
                        p8_api.sfx(n(16));
                        destroy_object(common);
                        init_object(EntityType.smoke, common.x, common.y);
                        init_object(EntityType.smoke, common.x.add(n(8)), common.y);
                        init_object(EntityType.smoke, common.x, common.y.add(n(8)));
                        init_object(EntityType.smoke, common.x.add(n(8)), common.y.add(n(8)));
                        init_object(EntityType.fruit, common.x.add(n(4)), common.y.add(n(4)));
                        return; //
                    }
                }
                common.hitbox = P8Rect{ .x = n(0), .y = n(0), .w = n(16), .h = n(16) };
            }

            fn draw(self: *FakeWall, common: *ObjectCommon) void {
                _ = self;
                p8_api.spr(n(64), common.x, common.y, n(1), n(1), false, false);
                p8_api.spr(n(65), common.x.add(n(8)), common.y, n(1), n(1), false, false);
                p8_api.spr(n(80), common.x, common.y.add(n(8)), n(1), n(1), false, false);
                p8_api.spr(n(81), common.x.add(n(8)), common.y.add(n(8)), n(1), n(1), false, false);
            }
        };

        const Key = struct {
            // tile=8,
            // if_not_fruit=true,
            fn update(self: *Key, common: *ObjectCommon) void {
                _ = self;
                const was = common.spr;
                common.spr = n(9).add(p8_api.sin(frames.div(n(30))).add(nf(0.5)));
                const is = common.spr;
                if (is.eq(n(10)) and is.ne(was)) {
                    common.flip_x = !common.flip_x;
                }
                if (common.check(EntityType.player, n(0), n(0))) {
                    p8_api.sfx(n(23));
                    sfx_timer = n(10);
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
                common.x = common.x.sub(n(4));
                self.start = common.x;
                self.timer = n(20);
            }
            fn update(self: *Chest, common: *ObjectCommon) void {
                if (has_key) {
                    self.timer = self.timer.sub(n(1));
                    common.x = self.start.sub(n(1)).add(p8_api.rnd(n(3)));
                    if (self.timer.le(n(0))) {
                        sfx_timer = n(20);
                        p8_api.sfx(n(16));
                        init_object(EntityType.fruit, common.x, common.y.sub(n(4)));
                        destroy_object(common);
                    }
                }
            }
        };

        const Platform = struct {
            last: P8API.num,
            dir: P8API.num,

            fn init(self: *Platform, common: *ObjectCommon) void {
                common.x = common.x.sub(n(4));
                common.solids = false;
                common.hitbox.w = n(16);
                self.last = common.x;
            }

            fn update(self: *Platform, common: *ObjectCommon) void {
                common.spd.x = self.dir.mul(nf(0.65));
                if (common.x.lt(n(-16))) {
                    common.x = n(128);
                }
                if (common.x.gt(n(128))) {
                    common.x = n(-16);
                }
                if (!common.check(EntityType.player, n(0), n(0))) {
                    const hit_opt = common.collide(EntityType.player, n(0), n(-1));
                    if (hit_opt) |hit| {
                        hit.common.move_x(common.x.sub(self.last), n(1));
                    }
                }
                self.last = common.x;
            }

            fn draw(self: *Platform, common: *ObjectCommon) void {
                _ = self;
                p8_api.spr(n(11), common.x, common.y.sub(n(1)), n(1), n(1), false, false);
                p8_api.spr(n(12), common.x.add(n(8)), common.y.sub(n(1)), n(1), n(1), false, false);
            }
        };

        const Message = struct {
            text: []const u8,
            index: P8API.num,
            last: P8API.num,
            off: P8Point,

            fn draw(self: *Message, common: *ObjectCommon) void {
                self.text = "-- celeste mountain --#this memorial to those# perished on the climb";
                if (common.check(EntityType.player, n(4), n(0))) {
                    if (self.index.lt(n(self.text.len))) {
                        self.index = self.index.add(nf(0.5));
                        if (self.index.ge(self.last.add(n(1)))) {
                            self.last = self.last.add(n(1));
                            p8_api.sfx(n(35));
                        }
                    }
                    self.off = P8Point{ .x = n(8), .y = n(96) };
                    var i: P8API.num = n(0);
                    while (i.lt(self.index)) : (i = i.add(n(1))) {
                        if (self.text[i.to_int(usize)] != '#') {
                            p8_api.rectfill(self.off.x.sub(n(2)), self.off.y.sub(n(2)), self.off.x.add(n(7)), self.off.y.add(n(6)), n(7));
                            p8_api.print(self.text[i.to_int(usize)..i.add(n(1)).to_int(usize)], self.off.x, self.off.y, n(0));
                            self.off.x = self.off.x.add(n(5));
                        } else {
                            self.off.x = n(8);
                            self.off.y = self.off.y.add(n(7));
                        }
                    }
                } else {
                    self.index = n(0);
                    self.last = n(0);
                }
            }
        };

        const BigChest = struct {
            state: P8API.num,
            timer: P8API.num,
            particle_count: P8API.num,
            particles: [50]Particle,

            fn init(self: *BigChest, common: *ObjectCommon) void {
                self.state = n(0);
                common.hitbox.w = n(16);
            }

            fn draw(self: *BigChest, common: *ObjectCommon) void {
                if (self.state.eq(n(0))) {
                    const hit_opt = common.collide(EntityType.player, n(0), n(8));
                    if (hit_opt) |hit| {
                        if (hit.common.is_solid(n(0), n(1))) {
                            p8_api.music(n(-1), n(500), n(7));
                            p8_api.sfx(n(37));
                            pause_player = true;
                            hit.common.spd.x = n(0);
                            hit.common.spd.y = n(0);
                            self.state = n(1);
                            init_object(EntityType.smoke, common.x, common.y);
                            init_object(EntityType.smoke, common.x.add(n(8)), common.y);
                            self.timer = n(60);
                            self.particle_count = n(0);
                            for (&self.particles) |*p| {
                                p.active = false;
                            }
                        }
                    }
                    p8_api.spr(n(96), common.x, common.y, n(1), n(1), false, false);
                    p8_api.spr(n(97), common.x.add(n(8)), common.y, n(1), n(1), false, false);
                } else if (self.state.eq(n(1))) {
                    self.timer = self.timer.sub(n(1));
                    shake = n(5);
                    flash_bg = true;
                    if (self.timer.le(n(45)) and self.particle_count.lt(n(50))) {
                        self.particles[self.particle_count.to_int(usize)] = Particle{
                            .active = true,
                            .x = n(1).add(p8_api.rnd(n(14))),
                            .y = n(0),
                            .h = n(32).add(p8_api.rnd(n(32))),
                            .spd = P8Point{
                                .x = n(0),
                                .y = n(8).add(p8_api.rnd(n(8))),
                            },
                        };
                        self.particle_count = self.particle_count.add(n(1));
                    }
                    if (self.timer.lt(n(0))) {
                        self.state = n(2);
                        self.particle_count = n(0);
                        flash_bg = false;
                        new_bg = true;
                        init_object(EntityType.orb, common.x.add(n(4)), common.y.add(n(4)));
                        pause_player = false;
                    }
                    for (&self.particles) |*p| {
                        if (p.active) {
                            p.y = p.y.add(p.spd.y);
                            p8_api.line(common.x.add(p.x), common.y.add(n(8)).sub(p.y), common.x.add(p.x), p8_api.min(common.y.add(n(8)).sub(p.y).add(p.h), common.y.add(n(8))), n(7));
                        }
                    }
                }
                p8_api.spr(n(112), common.x, common.y.add(n(8)), n(1), n(1), false, false);
                p8_api.spr(n(113), common.x.add(n(8)), common.y.add(n(8)), n(1), n(1), false, false);
            }
        };

        const Orb = struct {
            fn init(self: *Orb, common: *ObjectCommon) void {
                _ = self;
                common.spd.y = n(-4);
                common.solids = false;
                // unused this.particles={}
            }
            fn draw(self: *Orb, common: *ObjectCommon) void {
                _ = self;
                common.spd.y = appr(common.spd.y, n(0), nf(0.5));
                const hit_opt = common.collide(EntityType.player, n(0), n(0));
                if (hit_opt) |hit| {
                    if (common.spd.y.eq(n(0))) {
                        music_timer = n(45);
                        p8_api.sfx(n(51));
                        freeze = n(10);
                        shake = n(10);
                        destroy_object(common);
                        max_djump = n(2);
                        hit.specific.player.djump = n(2);
                        return;
                    }
                }

                p8_api.spr(n(102), common.x, common.y, n(1), n(1), false, false);
                const off: P8API.num = frames.div(n(30));
                var i: P8API.num = n(0);
                while (i.le(n(7))) : (i = i.add(n(1))) {
                    p8_api.circfill(common.x.add(n(4)).add(p8_api.cos(off.add(i.div(n(8)))).mul(n(8))), common.y.add(n(4)).add(p8_api.sin(off.add(i.div(n(8)))).mul(n(8))), n(1), n(7));
                }
            }
        };

        const Flag = struct {
            show: bool,
            score: P8API.num,

            fn init(self: *Flag, common: *ObjectCommon) void {
                common.x = common.x.add(n(5));
                self.score = n(0);
                self.show = false;
                var i: usize = 0;
                while (i < FRUIT_COUNT) : (i += 1) {
                    if (got_fruit[i]) {
                        self.score = self.score.add(n(1));
                    }
                }
            }
            fn draw(self: *Flag, common: *ObjectCommon) void {
                common.spr = n(118).add(frames.div(n(5)).mod(n(3)));
                p8_api.spr(common.spr, common.x, common.y, n(1), n(1), false, false);
                if (self.show) {
                    var str: [20]u8 = undefined;
                    @memset(&str, 0);
                    p8_api.rectfill(n(32), n(2), n(96), n(31), n(0));
                    p8_api.spr(n(26), n(55), n(6), n(1), n(1), false, false);
                    _ = std.fmt.bufPrint(&str, "x {} ", .{self.score.to_int(usize)}) catch {
                        return;
                    };
                    p8_api.print(&str, n(64), n(9), n(7));
                    draw_time(n(49), n(16));
                    _ = std.fmt.bufPrint(&str, "deaths {} ", .{deaths.to_int(usize)}) catch {
                        return;
                    };
                    p8_api.print(&str, n(48), n(24), n(7));
                } else if (common.check(EntityType.player, n(0), n(0))) {
                    p8_api.sfx(n(55));
                    sfx_timer = n(30);
                    self.show = true;
                }
            }
        };

        const RoomTitle = struct {
            delay: P8API.num,

            fn init(self: *RoomTitle) void {
                self.delay = n(5);
            }
            fn draw(self: *RoomTitle, common: *ObjectCommon) void {
                self.delay = self.delay.sub(n(1));
                if (self.delay.lt(n(-30))) {
                    destroy_object(common);
                } else if (self.delay.lt(n(0))) {
                    p8_api.rectfill(n(24), n(58), n(104), n(70), n(0));
                    if (room.x.eq(n(3)) and room.y.eq(n(1))) {
                        p8_api.print("old site", n(48), n(62), n(7));
                    } else if (level_index().eq(n(30))) {
                        p8_api.print("summit", n(52), n(62), n(7));
                    } else {
                        const level = level_index().add(n(1)).mul(n(100));
                        var str: [16]u8 = undefined;
                        @memset(&str, 0);
                        _ = std.fmt.bufPrint(&str, "{} m", .{level.to_int(i32)}) catch {
                            return;
                        };
                        const offset: P8API.num = if (level.lt(n(1000))) n(2) else n(0);
                        p8_api.print(&str, n(52).add(offset), n(62), n(7));
                    }
                    //print("//-",86,64-2,13)

                    draw_time(n(4), n(4));
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
                self.hitbox = P8Rect{ .x = n(0), .y = n(0), .w = n(8), .h = n(8) };
                self.rem.x = n(0);
                self.rem.y = n(0);
                self.spd.x = n(0);
                self.spd.y = n(0);
                self.spr = n(@intFromEnum(entity_type));
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
                        other.common.x.add(other.common.hitbox.x).add(other.common.hitbox.w).gt(self.x.add(self.hitbox.x).add(ox)) and
                        other.common.y.add(other.common.hitbox.y).add(other.common.hitbox.h).gt(self.y.add(self.hitbox.y).add(oy)) and
                        other.common.x.add(other.common.hitbox.x).lt(self.x.add(self.hitbox.x).add(self.hitbox.w).add(ox)) and
                        other.common.y.add(other.common.hitbox.y).lt(self.y.add(self.hitbox.y).add(self.hitbox.h).add(oy)))
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
                return ice_at(self.x.add(self.hitbox.x).add(ox), self.y.add(self.hitbox.y).add(oy), self.hitbox.w, self.hitbox.h);
            }

            fn move(self: *ObjectCommon, ox: P8API.num, oy: P8API.num) void {
                var amount: P8API.num = n(0);

                self.rem.x = self.rem.x.add(ox);
                amount = p8_api.flr(self.rem.x.add(nf(0.5)));
                self.rem.x = self.rem.x.sub(amount);
                self.move_x(amount, n(0));

                self.rem.y = self.rem.y.add(oy);
                amount = p8_api.flr(self.rem.y.add(nf(0.5)));
                self.rem.y = self.rem.y.sub(amount);
                self.move_y(amount);
            }

            fn move_x(self: *ObjectCommon, amount: P8API.num, start: P8API.num) void {
                if (self.solids) {
                    const step = sign(amount);
                    var i: P8API.num = start;
                    while (i.le(p8_api.abs(amount))) : (i = i.add(n(1))) { // i <= amount
                        if (!self.is_solid(step, n(0))) {
                            self.x = self.x.add(step);
                        } else {
                            self.spd.x = n(0);
                            self.rem.x = n(0);
                            break;
                        }
                    }
                } else {
                    self.x = self.x.add(amount);
                }
            }

            fn move_y(self: *ObjectCommon, amount: P8API.num) void {
                if (self.solids) {
                    const step = sign(amount);
                    var i: P8API.num = n(0);
                    while (i.le(p8_api.abs(amount))) : (i = i.add(n(1))) {
                        if (!self.is_solid(n(0), step)) {
                            self.y = self.y.add(step);
                        } else {
                            self.spd.y = n(0);
                            self.rem.y = n(0);
                            break;
                        }
                    }
                } else {
                    self.y = self.y.add(amount);
                }
            }

            fn is_solid(self: *ObjectCommon, ox: P8API.num, oy: P8API.num) bool {
                if (oy.gt(n(0)) and !self.check(EntityType.platform, ox, n(0)) and self.check(EntityType.platform, ox, oy)) {
                    return true;
                }
                return solid_at(self.x.add(self.hitbox.x).add(ox), self.y.add(self.hitbox.y).add(oy), self.hitbox.w, self.hitbox.h) or self.check(EntityType.fall_floor, ox, oy) or self.check(EntityType.fake_wall, ox, oy);
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
            if (etype.if_not_fruit() and got_fruit[level_index().to_int(usize)]) {
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
            delay_restart = n(15);
        }

        fn next_room() void {
            if (room.x.eq(n(2)) and room.y.eq(n(1))) {
                p8_api.music(n(30), n(500), n(7));
            } else if (room.x.eq(n(3)) and room.y.eq(n(1))) {
                p8_api.music(n(20), n(500), n(7));
            } else if (room.x.eq(n(4)) and room.y.eq(n(2))) {
                p8_api.music(n(30), n(500), n(7));
            } else if (room.x.eq(n(5)) and room.y.eq(n(3))) {
                p8_api.music(n(30), n(500), n(7));
            }

            if (room.x.eq(n(7))) {
                load_room(n(0), room.y.add(n(1)));
            } else {
                load_room(room.x.add(n(1)), room.y);
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
            var tx: P8API.num = n(0);
            while (tx.le(n(15))) : (tx = tx.add(n(1))) {
                var ty: P8API.num = n(0);
                while (ty.le(n(15))) : (ty = ty.add(n(1))) {
                    const tile = p8_api.mget(room.x.mul(n(16)).add(tx), room.y.mul(n(16)).add(ty));
                    if (tile == 11) {
                        var p = create_object(EntityType.platform, tx.mul(n(8)), ty.mul(n(8)));
                        p.specific.platform.dir = n(-1);
                    } else if (tile == 12) {
                        var p = create_object(EntityType.platform, tx.mul(n(8)), ty.mul(n(8)));
                        p.specific.platform.dir = n(1);
                    } else if (tile > 0) {
                        for (all_entity_types) |et| {
                            if (tile == @intFromEnum(et)) {
                                init_object(et, tx.mul(n(8)), ty.mul(n(8)));
                            }
                        }
                    }
                }
            }

            if (!is_title()) {
                init_object(EntityType.room_title, n(0), n(0));
            }
        }

        // update function //
        /////////////////////

        pub fn _update() void {
            frames = frames.add(n(1)).mod(n(30));
            if (frames.eq(n(0)) and level_index().lt(n(30))) {
                seconds = seconds.add(n(1)).mod(n(60));
                if (seconds.eq(n(0))) {
                    minutes = minutes.add(n(1));
                }
            }

            if (music_timer.gt(n(0))) {
                music_timer = music_timer.sub(n(1));
                if (music_timer.le(n(0))) {
                    p8_api.music(n(10), n(0), n(7));
                }
            }

            if (sfx_timer.gt(n(0))) {
                sfx_timer = sfx_timer.sub(n(1));
            }

            // cancel if freeze
            if (freeze.gt(n(0))) {
                freeze = freeze.sub(n(1));
                return;
            }

            // screenshake
            if (shake.gt(n(0))) {
                shake = shake.sub(n(1));
                p8_api.camera(n(0), n(0));
                if (shake.gt(n(0))) {
                    p8_api.camera(n(-2).add(p8_api.rnd(n(5))), n(-2).add(p8_api.rnd(n(5))));
                }
            }

            // restart (soon)
            if (will_restart and delay_restart.gt(n(0))) {
                delay_restart = delay_restart.sub(n(1));
                if (delay_restart.le(n(0))) {
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
                    p8_api.music(n(-1), n(0), n(0));
                    start_game_flash = n(50);
                    start_game = true;
                    p8_api.sfx(n(38));
                }
                if (start_game) {
                    start_game_flash = start_game_flash.sub(n(1));
                    if (start_game_flash.le(n(-30))) {
                        begin_game();
                    }
                }
            }
        }

        // drawing functions //
        ///////////////////////

        pub fn _draw() void {
            if (freeze.gt(n(0))) {
                return;
            }

            // reset all palette values
            p8_api.pal_reset();

            // start game flash
            if (start_game) {
                var c: P8API.num = n(10);
                if (start_game_flash.gt(n(10))) {
                    if (frames.mod(n(10)).lt(n(5))) {
                        c = n(7);
                    }
                } else if (start_game_flash.gt(n(5))) {
                    c = n(2);
                } else if (start_game_flash.gt(n(0))) {
                    c = n(1);
                } else {
                    c = n(0);
                }
                if (c.lt(n(10))) {
                    p8_api.pal(n(6), c);
                    p8_api.pal(n(12), c);
                    p8_api.pal(n(13), c);
                    p8_api.pal(n(5), c);
                    p8_api.pal(n(1), c);
                    p8_api.pal(n(7), c);
                }
            }

            // clear screen
            var bg_col: P8API.num = n(0);
            if (flash_bg) {
                bg_col = frames.div(n(5));
            } else if (new_bg) {
                bg_col = n(2);
            }
            p8_api.rectfill(n(0), n(0), n(128), n(128), bg_col);

            // clouds
            if (!is_title()) {
                for (&clouds) |*c| {
                    c.x = c.x.add(c.spd);
                    p8_api.rectfill(c.x, c.y, c.x.add(c.w), c.y.add(n(4)).add(n(1).sub(c.w.div(n(64))).mul(n(12))), if (new_bg) n(14) else n(1));
                    if (c.x.gt(n(128))) {
                        c.x = c.w.neg();
                        c.y = p8_api.rnd(n(128).sub(n(8)));
                    }
                }
            }

            // draw bg terrain
            p8_api.map(room.x.mul(n(16)), room.y.mul(n(16)), n(0), n(0), n(16), n(16), n(4));

            // -- platforms/big chest
            for (&objects) |*o| {
                if (o.common.entity_type == EntityType.platform or o.common.entity_type == EntityType.big_chest) {
                    draw_object(o);
                }
            }

            // draw terrain
            const off: P8API.num = if (is_title()) n(-4) else n(0);
            p8_api.map(room.x.mul(n(16)), room.y.mul(n(16)), off, n(0), n(16), n(16), n(2));

            // draw objects
            for (&objects) |*o| {
                if (o.common.entity_type != EntityType.platform and o.common.entity_type != EntityType.big_chest) {
                    draw_object(o);
                }
            }

            // draw fg terrain
            p8_api.map(room.x.mul(n(16)), room.y.mul(n(16)), n(0), n(0), n(16), n(16), n(8));

            // -- particles
            for (&particles) |*p| {
                p.x = p.x.add(p.spd.x);
                p.y = p.y.add(p8_api.sin(p.off));
                p.off = p.off.add(p8_api.min(nf(0.05), p.spd.x.div(n(32))));
                p8_api.rectfill(p.x, p.y, p.x.add(p.s), p.y.add(p.s), p.c);
                if (p.x.gt(n(128 + 4))) {
                    p.x = n(-4);
                    p.y = p8_api.rnd(n(128));
                }
            }

            for (&dead_particles) |*p| {
                if (p.active) {
                    p.x = p.x.add(p.spd.x);
                    p.y = p.y.add(p.spd.y);
                    p.t = p.t.sub(n(1));
                    if (p.t.le(n(0))) {
                        p.active = false;
                    }
                    p8_api.rectfill(p.x.sub(p.t.div(n(5))), p.y.sub(p.t.div(n(5))), p.x.add(p.t.div(n(5))), p.y.add(p.t.div(n(5))), n(14).add(p.t.mod(n(2))));
                }
            }

            // draw outside of the screen for screenshake
            p8_api.rectfill(n(-5), n(-5), n(-1), n(133), n(0));
            p8_api.rectfill(n(-5), n(-5), n(133), n(-1), n(0));
            p8_api.rectfill(n(-5), n(128), n(133), n(133), n(0));
            p8_api.rectfill(n(128), n(-5), n(133), n(133), n(0));

            // credits
            if (is_title()) {
                p8_api.print("x+c", n(58), n(80), n(5));
                p8_api.print("matt thorson", n(42), n(96), n(5));
                p8_api.print("noel berry", n(46), n(102), n(5));
            }

            if (level_index().eq(n(30))) {
                var p: ?*Object = null;
                for (&objects) |*obj| {
                    if (obj.common.entity_type == EntityType.player) {
                        p = obj;
                        break;
                    }
                }
                if (p) |player| {
                    const diff = p8_api.min(n(24), n(40).sub(p8_api.abs(player.common.x.add(n(4)).sub(n(64)))));
                    p8_api.rectfill(n(0), n(0), diff, n(128), n(0));
                    p8_api.rectfill(n(128).sub(diff), n(0), n(128), n(128), n(0));
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
                        if (object.common.spr.gt(n(0))) {
                            p8_api.spr(object.common.spr, object.common.x, object.common.y, n(1), n(1), object.common.flip_x, object.common.flip_y);
                        }
                    },
                }
            }
        }

        fn draw_time(x: P8API.num, y: P8API.num) void {
            const s: u32 = seconds.to_int(u32);
            const m: u32 = minutes.mod(n(60)).to_int(u32);
            const h: u32 = minutes.divTrunc(n(60)).to_int(u32);

            p8_api.rectfill(x, y, x.add(n(32)), y.add(n(6)), n(0));
            //	print((h<10 and "0"..h or h)..":"..(m<10 and "0"..m or m)..":"..(s<10 and "0"..s or s),x+1,y+1,7)
            var str: [20]u8 = undefined;
            @memset(&str, 0);
            _ = std.fmt.bufPrint(&str, "{:0>2}:{:0>2}:{:0>2} ", .{ h, m, s }) catch {
                return;
            };
            p8_api.print(&str, x.add(n(1)), y.add(n(1)), n(7));
        }

        //// TODO: to be reintegrated at the proper place
        /////////////////////////////////////////////////

        fn kill_player(player: *Player, common: *ObjectCommon) void {
            _ = player;
            sfx_timer = n(12);
            p8_api.sfx(n(0));
            deaths = deaths.add(n(1));
            shake = n(10);
            destroy_object(common);
            var dir: P8API.num = n(0);
            for (&dead_particles) |*p| {
                const angle = dir.div(n(8));
                p.active = true;
                p.x = common.x.add(n(4));
                p.y = common.y.add(n(4));
                p.t = n(10);
                p.spd = P8Point{
                    .x = p8_api.sin(angle).mul(n(3)),
                    .y = p8_api.cos(angle).mul(n(3)),
                };
                dir = dir.add(n(1));
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
            return p8_api.mget(room.x.mul(n(16)).add(x), room.y.mul(n(16)).add(y));
        }

        fn spikes_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, xspd: P8API.num, yspd: P8API.num) bool {
            var i: P8API.num = p8_api.max(n(0), p8_api.flr(x.div(n(8))));
            while (i.le(p8_api.min(n(15), (x.add(w).sub(n(1)).div(n(8)))))) : (i = i.add(n(1))) {
                var j: P8API.num = p8_api.max(n(0), p8_api.flr(y.div(n(8))));
                while (j.le(p8_api.min(n(15), (y.add(h).sub(n(1)).div(n(8)))))) : (j = j.add(n(1))) {
                    const tile = tile_at(i, j);
                    if (tile == 17 and (y.add(h).sub(n(1)).mod(n(8)).ge(n(6)) or y.add(h).eq(j.mul(n(8)).add(n(8)))) and yspd.ge(n(0))) {
                        return true;
                    } else if (tile == 27 and y.mod(n(8)).le(n(2)) and yspd.le(n(0))) {
                        return true;
                    } else if (tile == 43 and x.mod(n(8)).le(n(2)) and xspd.le(n(0))) {
                        return true;
                    } else if (tile == 59 and (x.add(w).sub(n(1)).mod(n(8)).ge(n(6)) or x.add(w).eq(i.mul(n(8)).add(n(8)))) and xspd.ge(n(0))) {
                        return true;
                    }
                }
            }
            return false;
        }

        fn tile_flag_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num, flag: P8API.num) bool {
            var i: P8API.num = p8_api.max(n(0), x.divTrunc(n(8)));
            while (i.le(p8_api.min(n(15), x.add(w).sub(n(1)).div(n(8))))) : (i = i.add(n(1))) {
                var j = p8_api.max(n(0), y.divTrunc(n(8)));
                while (j.le(p8_api.min(n(15), y.add(h).sub(n(1)).div(n(8))))) : (j = j.add(n(1))) {
                    if (p8_api.fget(@intCast(tile_at(i, j)), flag)) {
                        return true;
                    }
                }
            }
            return false;
        }

        fn maybe() bool {
            return p8_api.rnd(n(1)).lt(nf(0.5));
        }

        fn solid_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num) bool {
            return tile_flag_at(x, y, w, h, n(0));
        }

        fn ice_at(x: P8API.num, y: P8API.num, w: P8API.num, h: P8API.num) bool {
            return tile_flag_at(x, y, w, h, n(4));
        }

        fn clamp(x: P8API.num, a: P8API.num, b: P8API.num) P8API.num {
            return p8_api.max(a, p8_api.min(b, x));
        }

        fn appr(val: P8API.num, target: P8API.num, amount: P8API.num) P8API.num {
            return if (val.gt(target)) p8_api.max(val.sub(amount), target) else p8_api.min(val.add(amount), target);
        }

        fn sign(v: P8API.num) P8API.num {
            return if (v.gt(n(0))) n(1) else (if (v.lt(n(0))) n(-1) else n(0));
        }
    };
}
