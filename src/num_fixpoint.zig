const std = @import("std");

// fixed point as Q16.16

//const fp_one: i32 = 0x0001_0000;
const fp_one: i32 = 1 << 16;
var rnd_seed_lo: i64 = 0;
var rnd_seed_hi: i64 = 1;
fn gen_random(max: i64) i64 {
    if (max == 0) {
        return 0;
    }
    rnd_seed_hi = @addWithOverflow(((rnd_seed_hi << 16) | (rnd_seed_hi >> 16)), rnd_seed_lo)[0];
    rnd_seed_lo = @addWithOverflow(rnd_seed_lo, rnd_seed_hi)[0];
    return @mod(rnd_seed_hi, max);
}

pub const t = struct {
    n: i32,

    pub fn from_fixpoint(fpv: i32) t {
        return t{
            .n = fpv,
        };
    }

    pub fn from_float(f: f32) t {
        return t{
            .n = @intFromFloat(f * @as(f32, @floatFromInt(fp_one))),
        };
    }

    pub fn to_float(self: *const t, comptime T: type) T {
        return @as(f32, @floatFromInt(self.n)) / @as(f32, @floatFromInt(fp_one));
    }

    pub fn from_int(integer: anytype) t {
        return t{
            .n = @as(i32, @intCast(integer)) * fp_one,
        };
    }

    pub fn to_int(self: *const t, comptime T: type) T {
        return @as(T, @intCast(self.n >> 16));
    }

    pub fn random(m: t) t {
        const i = gen_random(@intCast(m.n));
        return t{
            // do not scale this value so that the fractional part is randomized as well
            .n = @intCast(i),
        };
    }

    pub fn divTrunc(self: *const t, x: t) t {
        return self.div(x).floor();
    }

    pub fn neg(self: *const t) t {
        return t{
            .n = -self.n,
        };
    }

    pub fn mod(self: *const t, x: t) t {
        return t{
            .n = @mod(self.n, x.n),
        };
    }

    pub fn abs(self: *const t) t {
        return t{
            .n = @intCast(@abs(self.n)),
        };
    }

    pub fn floor(self: *const t) t {
        return t{
            .n = @bitCast((@as(u32, @bitCast(self.n)) & 0xffff_0000)),
        };
    }

    pub fn add(self: *const t, o: t) t {
        return t{
            .n = self.n + o.n,
        };
    }

    pub fn sub(self: *const t, o: t) t {
        return t{
            .n = self.n - o.n,
        };
    }

    pub fn mul(self: *const t, o: t) t {
        const self64: i64 = @as(i64, @intCast(self.n));
        const o64: i64 = @as(i64, @intCast(o.n));
        const one64: i64 = @as(i64, @intCast(fp_one));
        const m: i64 = @divTrunc(self64 * o64, one64);
        return t{
            .n = @as(i32, @intCast(m)),
        };
    }

    pub fn div(self: *const t, o: t) t {
        const self64: i64 = @as(i64, @intCast(self.n));
        const o64: i64 = @as(i64, @intCast(o.n));
        const one64: i64 = @as(i64, @intCast(fp_one));
        const d: i64 = @divTrunc(one64 * self64, o64);
        return t{
            .n = @as(i32, @intCast(d)),
        };
    }

    pub fn eq(self: *const t, o: t) bool {
        return self.n == o.n;
    }

    pub fn ne(self: *const t, o: t) bool {
        return self.n != o.n;
    }

    pub fn lt(self: *const t, o: t) bool {
        return self.n < o.n;
    }

    pub fn gt(self: *const t, o: t) bool {
        return self.n > o.n;
    }

    pub fn le(self: *const t, o: t) bool {
        return self.n <= o.n;
    }

    pub fn ge(self: *const t, o: t) bool {
        return self.n >= o.n;
    }

    pub fn min(self: *const t, o: t) t {
        return t{
            .n = if (self.n > o.n) o.n else self.n,
        };
    }

    pub fn max(self: *const t, o: t) t {
        return t{
            .n = if (self.n > o.n) self.n else o.n,
        };
    }

    pub fn sin(self: *const t) t {
        return from_float(std.math.sin(self.to_float(f32)));
    }
};

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectApprox = testing.expectApproxEqRel;

fn expectFixed(expected: f32, actual: t) !void {
    try expectEqual(expected, actual.to_float(f32));
}

fn expectFixedApprox(expected: f32, actual: t, tolerance: f32) !void {
    try expectApprox(expected, actual.to_float(f32), tolerance);
}

test "positive float conversion" {
    inline for ([_]f32{ 0.0, 1.0, 2.0, 0.1, 0.2, 3.14 }) |f| {
        const converted: f32 = t.from_float(f).to_float(f32);
        try expectApprox(f, converted, 0.1);
    }
}

test "negative float conversion" {
    inline for ([_]f32{ -0.0, -1.0, -2.0, -0.1, -0.2, -3.14 }) |f| {
        const converted: f32 = t.from_float(f).to_float(f32);
        try expectApprox(f, converted, 0.1);
    }
}

test "add" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const one_one: t = t.from_float(1.1);
    try expectFixedApprox(1.0, zero.add(one), 0.1);
    try expectFixedApprox(1.0, one.add(zero), 0.1);
    try expectFixedApprox(-1.0, zero.add(minus_one), 0.1);
    try expectFixedApprox(-1.0, minus_one.add(zero), 0.1);
    try expectFixedApprox(2.1, one.add(one_one), 0.1);
    try expectFixedApprox(2.1, one_one.add(one), 0.1);
}

test "sub" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const one_one: t = t.from_float(1.1);
    try expectFixedApprox(-1.0, zero.sub(one), 0.1);
    try expectFixedApprox(1.0, one.sub(zero), 0.1);
    try expectFixedApprox(1.0, zero.sub(minus_one), 0.1);
    try expectFixedApprox(-1.0, minus_one.sub(zero), 0.1);
    try expectFixedApprox(-0.1, one.sub(one_one), 0.1);
    try expectFixedApprox(0.1, one_one.sub(one), 0.1);
}

test "mul" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const five: t = t.from_float(5.0);
    const minus_one: t = t.from_float(-1.0);
    const one_one: t = t.from_float(1.1);
    try expectFixedApprox(0.0, zero.mul(one), 0.1);
    try expectFixedApprox(0.0, one.mul(zero), 0.1);
    try expectFixedApprox(0.0, zero.mul(minus_one), 0.1);
    try expectFixedApprox(-1.0, minus_one.mul(one), 0.1);
    try expectFixedApprox(1.1, one.mul(one_one), 0.1);
    try expectFixedApprox(1.1, one_one.mul(one), 0.1);
    try expectFixedApprox(25.0, five.mul(five), 0.1);
}

test "div" {
    const one: t = t.from_float(1.0);
    const five: t = t.from_float(5.0);
    const minus_one: t = t.from_float(-1.0);
    const twenty_five: t = t.from_float(25.0);
    try expectFixedApprox(5.0, five.div(one), 0.1);
    try expectFixedApprox(-5.0, five.div(minus_one), 0.1);
    try expectFixedApprox(5.0, twenty_five.div(five), 0.1);
}

test "neg" {
    try expectFixedApprox(0.0, t.from_float(0.0).neg(), 0.1);
    try expectFixedApprox(0.0, t.from_float(-0.0).neg(), 0.1);
    try expectFixedApprox(1.0, t.from_float(-1.0).neg(), 0.1);
    try expectFixedApprox(-1.0, t.from_float(1.0).neg(), 0.1);
    try expectFixedApprox(0.1, t.from_float(-0.1).neg(), 0.1);
    try expectFixedApprox(-0.1, t.from_float(0.1).neg(), 0.1);
}

test "mod" {
    const five: t = t.from_float(5.0);
    const minus_five: t = t.from_float(-5.0);
    const three: t = t.from_float(3.0);
    try expectFixedApprox(2.0, five.mod(three), 0.1);
    try expectFixedApprox(1.0, minus_five.mod(three), 0.1);
}

test "abs" {
    const zero: t = t.from_float(0.0);
    const five: t = t.from_float(5.0);
    const minus_five: t = t.from_float(-5.0);
    try expectFixedApprox(5.0, five.abs(), 0.1);
    try expectFixedApprox(5.0, minus_five.abs(), 0.1);
    try expectFixedApprox(0.0, zero.abs(), 0.1);
}

test "floor" {
    const zero: t = t.from_float(0.0);
    const five: t = t.from_float(5.0);
    const five_one: t = t.from_float(5.1);
    try expectFixedApprox(0.0, zero.floor(), 0.1);
    try expectFixedApprox(5.0, five.floor(), 0.1);
    try expectFixedApprox(5.0, five_one.floor(), 0.1);
    try expectFixedApprox(-5.0, five.neg().floor(), 0.1);
    try expectFixedApprox(-6.0, five_one.neg().floor(), 0.1);
}

test "divtrunc" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const eight: t = t.from_float(8.0);
    const sixteen: t = t.from_float(16.0);
    const one_sixteen: t = t.from_float(116.0);
    try expectFixedApprox(0.0, zero.divTrunc(one), 0.1);
    try expectFixedApprox(0.0, one.divTrunc(sixteen), 0.1);
    try expectFixedApprox(14.0, one_sixteen.divTrunc(eight), 0.1);
}

test "max" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const one_one: t = t.from_float(1.1);
    try expectFixedApprox(1.0, zero.max(one), 0.1);
    try expectFixedApprox(1.0, one.max(zero), 0.1);
    try expectFixedApprox(0.0, zero.max(minus_one), 0.1);
    try expectFixedApprox(0.0, minus_one.max(zero), 0.1);
    try expectFixedApprox(1.1, one.max(one_one), 0.1);
    try expectFixedApprox(1.1, one_one.max(one), 0.1);
}

test "min" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const one_one: t = t.from_float(1.1);
    try expectFixedApprox(0.0, zero.min(one), 0.1);
    try expectFixedApprox(0.0, one.min(zero), 0.1);
    try expectFixedApprox(-1.0, zero.min(minus_one), 0.1);
    try expectFixedApprox(-1.0, minus_one.min(zero), 0.1);
    try expectFixedApprox(1.0, one.min(one_one), 0.1);
    try expectFixedApprox(1.0, one_one.min(one), 0.1);
}

test "eq" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const zero_one: t = t.from_float(0.1);
    try expectEqual(true, zero.eq(zero));
    try expectEqual(false, zero.eq(one));
    try expectEqual(false, zero.eq(minus_one));
    try expectEqual(false, zero.eq(zero_one));
    try expectEqual(true, zero_one.eq(zero_one));
}

test "ne" {
    const zero: t = t.from_float(0.0);
    const one: t = t.from_float(1.0);
    const minus_one: t = t.from_float(-1.0);
    const zero_one: t = t.from_float(0.1);
    try expectEqual(false, zero.ne(zero));
    try expectEqual(true, zero.ne(one));
    try expectEqual(true, zero.ne(minus_one));
    try expectEqual(true, zero.ne(zero_one));
    try expectEqual(false, zero_one.ne(zero_one));
}
