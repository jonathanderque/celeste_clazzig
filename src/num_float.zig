const std = @import("std");

var rnd_seed_lo: i64 = 0;
var rnd_seed_hi: i64 = 1;
fn pico8_random(max: i64) i64 { //decomp'd pico-8
    if (max == 0) {
        return 0;
    }
    rnd_seed_hi = @addWithOverflow(((rnd_seed_hi << 16) | (rnd_seed_hi >> 16)), rnd_seed_lo)[0];
    rnd_seed_lo = @addWithOverflow(rnd_seed_lo, rnd_seed_hi)[0];
    return @mod(rnd_seed_hi, max);
}

pub const t = struct {
    f: f32,

    pub fn init(x: f32) t {
        return t{
            .f = x,
        };
    }

    pub fn from_float(f: f32) t {
        return init(f);
    }

    pub fn from_int(integer: anytype) t {
        return t{
            .f = @floatFromInt(integer),
        };
    }

    pub fn to_int(self: *const t, comptime T: type) T {
        return @intFromFloat(self.f);
    }

    pub fn random(rnd_max: t) t {
        const mul_factor = from_int(10000);
        const x: i64 = pico8_random(mul_factor.mul(rnd_max).to_int(i64));
        return from_int(x).div(mul_factor);
    }

    pub fn divTrunc(self: *const t, x: t) t {
        return init(@divTrunc(self.f, x.f));
    }

    pub fn neg(self: *const t) t {
        return init(-self.f);
    }

    pub fn mod(self: *const t, x: t) t {
        return init(@mod(self.f, x.f));
    }

    pub fn abs(self: *const t) t {
        return init(@abs(self.f));
    }

    pub fn floor(self: *const t) t {
        return init(@floor(self.f));
    }

    pub fn add(self: *const t, o: t) t {
        return init(self.f + o.f);
    }

    pub fn sub(self: *const t, o: t) t {
        return init(self.f - o.f);
    }

    pub fn mul(self: *const t, o: t) t {
        return init(self.f * o.f);
    }

    pub fn div(self: *const t, o: t) t {
        return init(self.f / o.f);
    }

    pub fn eq(self: *const t, o: t) bool {
        return self.f == o.f;
    }

    pub fn ne(self: *const t, o: t) bool {
        return self.f != o.f;
    }

    pub fn lt(self: *const t, o: t) bool {
        return self.f < o.f;
    }

    pub fn gt(self: *const t, o: t) bool {
        return self.f > o.f;
    }

    pub fn le(self: *const t, o: t) bool {
        return self.f <= o.f;
    }

    pub fn ge(self: *const t, o: t) bool {
        return self.f >= o.f;
    }

    pub fn min(self: *const t, o: t) t {
        if (self.f <= o.f) {
            return init(self.f);
        } else {
            return init(o.f);
        }
    }

    pub fn max(self: *const t, o: t) t {
        if (self.f >= o.f) {
            return init(self.f);
        } else {
            return init(o.f);
        }
    }

    pub fn sin(self: *const t) t {
        return from_float(std.math.sin(self.f));
    }
};
