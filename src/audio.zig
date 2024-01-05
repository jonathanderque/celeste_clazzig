const std = @import("std");

pub const SAMPLE_RATE = 44100;

pub fn key_to_freq(note: f64) f64 {
    return 440.0 * std.math.pow(f64, 2, (note - 33) / 12);
}

const Waveform = struct {
    const period: f64 = 1;

    pub fn triangle(t: f64) f64 {
        return 0.5 * (@fabs(4.0 * t - 2.0) - 1.0);
    }

    pub fn square(t: f64) f64 {
        return if (triangle(t) >= 0) 1 else -1;
    }

    fn pulse(t: f64) f64 {
        return if (@mod(t, 1) < 0.33333) 1 else -1;
    }

    fn tilted_saw(t: f64) f64 {
        const tmod = @mod(t, 1);
        return ((if (tmod < 0.9) (tmod * 16 / 7) else ((1 - tmod) * 16)) - 1) * 0.9;
    }

    fn saw(t: f64) f64 {
        return 2 * (t - @floor(t + 0.5));
    }

    fn organ(t: f64) f64 {
        const t4 = t * 4;
        return (@fabs(@mod(t4, 2) - 1) - 0.5 + (@fabs(@mod(t4 * 0.5, 2) - 1) - 0.5) / 2.0 - 0.1);
    }

    fn phaser(t: f64) f64 {
        const t2 = t * 4;
        return (@fabs(@mod(t2, 2) - 1) - 0.5 + (@fabs(@mod((t2 * 127 / 128), 2) - 1) - 0.5) / 2) - 0.25;
    }

    var noise_seed_lo: i64 = 0;
    var noise_seed_hi: i64 = 1;
    fn noise_random() i64 { //decomp'd pico-8
        noise_seed_hi = @addWithOverflow(((noise_seed_hi << 16) | (noise_seed_hi >> 16)), noise_seed_lo)[0];
        noise_seed_lo = @addWithOverflow(noise_seed_lo, noise_seed_hi)[0];
        return noise_seed_hi;
    }

    fn white_noise() f64 {
        var r = @as(f64, @floatFromInt(noise_random())) / 100000.0;
        r = @mod(r, 2);
        return r - 1;
    }

    fn clamp(t: f64, low: f64, high: f64) f64 {
        if (t < low) {
            return low;
        }
        if (t > high) {
            return high;
        }
        return t;
    }

    var brown: f64 = 0;
    fn brown_noise() f64 {
        const white = white_noise();
        brown = (brown - (0.02 * white)) / 1.02;
        return clamp(10 * brown, -1, 1);
    }
};

// at speed 1, a "full" sfx with 32 notes takes .266s;  each "note" is thus 8.3125ms long
const note_duration: f64 = 0.266 / 32.0;
//const note_duration: f64 = 1.0 / 183.0;
const sample_duration: f64 = 1.0 / @as(f64, @floatFromInt(SAMPLE_RATE));

const AudioChannel = struct {
    playing: bool,
    sfx_id: usize = 0,
    sfx_data: []const u8,
    sfx_speed: f64 = 1,
    note_freq: f64 = 0,
    note_volume: f64 = 0,
    note_effect: u8 = 0,
    note_instrument: usize = 0,
    waveform_position: f64, // Where we are on the waveform, loops around [0; Waveform.period[
    current_note_duration: f64, // used to track when to go to the next note
    current_note_index: usize, // in [0;32]
    previous_note_freq: f64 = 0, // used for slide effect

    pub fn init() AudioChannel {
        return AudioChannel{
            .playing = false,
            .sfx_data = undefined,
            .waveform_position = 0,
            .current_note_duration = 0,
            .current_note_index = 0,
        };
    }

    pub fn play_sfx(self: *AudioChannel, sfx_id: usize, sfx_data: []const u8) void {
        self.sfx_id = sfx_id;
        self.sfx_data = sfx_data;
        self.playing = true;
        self.waveform_position = 0;
        self.current_note_duration = 0;
        self.extract_sfx_params();
        self.current_note_index = 0;
        self.extract_note_params();
    }

    pub fn extract_sfx_params(self: *AudioChannel) void {
        self.sfx_speed = @floatFromInt(self.sfx_data[65]);
    }

    pub fn assert_fx(effect: u8) void {
        switch (effect) {
            0, 1, 5 => {},
            else => {
                std.log.err("TODO: unknown effect {} not implemented", .{effect});
            },
        }
    }

    pub fn extract_note_params(self: *AudioChannel) void {
        self.previous_note_freq = self.note_freq;
        const b1 = self.sfx_data[2 * self.current_note_index];
        const b2 = self.sfx_data[2 * self.current_note_index + 1];
        const key: u8 = b1 & 0b0011_1111;
        self.note_freq = key_to_freq(@floatFromInt(key));
        self.note_volume = @floatFromInt((b2 >> 1) & 0b111);
        self.note_instrument = (b2 & 0b0000_0001) << 2 | (b1 >> 6);
        self.note_effect = ((b2 >> 4) & 0b111);
        assert_fx(self.note_effect);
    }

    pub fn sample(self: *AudioChannel) f64 {
        if (!self.playing) {
            return 0;
        }

        var s = switch (self.note_instrument) {
            0 => Waveform.triangle(self.waveform_position),
            1 => Waveform.tilted_saw(self.waveform_position),
            2 => Waveform.saw(self.waveform_position),
            3 => Waveform.square(self.waveform_position),
            4 => Waveform.pulse(self.waveform_position),
            5 => Waveform.organ(self.waveform_position),
            6 => Waveform.brown_noise(),
            7 => Waveform.phaser(self.waveform_position),
            else => unreachable,
        };

        var volume = self.note_volume / 7.0;
        var note_freq = self.note_freq;
        switch (self.note_effect) {
            1 => { // SLIDE
                note_freq = (self.note_freq - self.previous_note_freq) * self.current_note_duration + self.previous_note_freq;
            },
            5 => { // FADE OUT
                const nd = note_duration * self.sfx_speed;
                const fade_out = (nd - self.current_note_duration) / nd;
                volume = volume * fade_out;
            },
            0 => {},
            else => {},
        }

        s = s * volume;

        self.waveform_position += note_freq * Waveform.period / SAMPLE_RATE;
        if (self.waveform_position >= Waveform.period) {
            self.waveform_position -= Waveform.period;
        }

        self.current_note_duration += sample_duration;
        if (self.current_note_duration >= note_duration * self.sfx_speed) {
            self.current_note_duration -= note_duration * self.sfx_speed;
            self.current_note_index += 1;
            if (self.current_note_index >= 32) {
                self.playing = false;
            } else {
                self.extract_note_params();
            }
        }

        return s;
    }
};

pub const CHANNEL_COUNT: usize = 4;
pub const AudioEngine = struct {
    channels: [CHANNEL_COUNT]AudioChannel,

    pub fn init() AudioEngine {
        var channels: [CHANNEL_COUNT]AudioChannel = undefined;
        for (0..CHANNEL_COUNT) |i| {
            channels[i] = AudioChannel.init();
        }
        return AudioEngine{
            .channels = channels,
        };
    }

    pub fn sample(self: *AudioEngine) f64 {
        var playing_count: f64 = 0;
        for (0..CHANNEL_COUNT) |i| {
            if (self.channels[i].playing) {
                playing_count += 1;
            }
        }
        const channel_blend: f64 = if (playing_count == 0) 1.0 else 1.0 / playing_count;
        var result: f64 = 0.0;
        for (0..CHANNEL_COUNT) |i| {
            result += channel_blend * self.channels[i].sample();
        }
        return result;
    }

    pub fn play_sfx(self: *AudioEngine, sfx_id: usize, sfx_data: []const u8) void {
        var channel: usize = 0;
        for (0..CHANNEL_COUNT) |i| {
            if (self.channels[i].playing == false or self.channels[i].sfx_id == sfx_id) {
                channel = i;
                break;
            }
        }
        self.channels[channel].play_sfx(sfx_id, sfx_data);
    }
};
