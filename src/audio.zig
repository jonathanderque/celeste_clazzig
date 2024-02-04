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
const semitone: f64 = std.math.pow(f64, 2.0, 1.0 / 12.0);

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

    pub fn stop(self: *AudioChannel) void {
        self.playing = false;
    }

    pub fn finished_playing(self: *AudioChannel) bool {
        return self.current_note_index >= 32;
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
        const loop_start = self.sfx_data[66];
        const loop_end = self.sfx_data[67];
        if (loop_start > 0 and loop_end > loop_start) {
            std.log.err("TODO: sfx loops are not implemented (sfx {}, loop: {} -> {})", .{ self.sfx_id, loop_start, loop_end });
        }
    }

    var assert_fx_displayed = [8]bool{
        false, // no effect
        false, // slide
        false, // vibrato
        false, // drop
        false, // fade_in
        false, // fade_out
        false, // arp_fast
        false, // arp_slow
    };

    pub fn assert_fx(effect: u8) void {
        switch (effect) {
            0, 1, 2, 4, 5 => {},
            else => {
                if (!assert_fx_displayed[effect]) {
                    std.log.err("TODO: unknown effect {} not implemented", .{effect});
                    assert_fx_displayed[effect] = true;
                }
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
            2 => { // VIBRATO
                const nd = note_duration * self.sfx_speed;

                const t = (@fabs(@mod(self.current_note_duration / nd, 1) * 2 - 1) * 2 - 1) * 0.7;
                const vibrato = note_freq * semitone;
                note_freq = (vibrato - self.note_freq) * t + self.note_freq;
            },
            4 => { // FADE IN
                const nd = note_duration * self.sfx_speed;
                const fade_in = self.current_note_duration / nd;
                volume = volume * fade_in;
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
            if (self.finished_playing()) {
                self.playing = false;
            } else {
                self.extract_note_params();
            }
        }

        return s;
    }
};

const MusicFrameFlags = struct {
    loop_start: bool,
    loop_end: bool,
    stop: bool,
};

pub const CHANNEL_COUNT: usize = 5;
pub const CHANNEL_MUSIC_START: usize = 0;
pub const CHANNEL_MUSIC_END: usize = 4;
pub const CHANNEL_SFX_START: usize = 4;
pub const CHANNEL_SFX_END: usize = 5;
pub const AudioEngine = struct {
    pause: bool,
    music_data: []const u8 = undefined,
    sfx_data: []const u8 = undefined,
    channels: [CHANNEL_COUNT]AudioChannel,

    // music attributes
    music_playing: bool = false,
    music_id: usize = 0,
    tracked_channel: usize = 0, // monitored channel used to determine when to go to the next music pattern

    pub fn init() AudioEngine {
        var channels: [CHANNEL_COUNT]AudioChannel = undefined;
        for (0..CHANNEL_COUNT) |i| {
            channels[i] = AudioChannel.init();
        }
        return AudioEngine{
            .pause = false,
            .channels = channels,
        };
    }

    pub fn toggle_pause(self: *AudioEngine) void {
        self.pause = !self.pause;
    }

    pub fn set_data(self: *AudioEngine, music_data: []const u8, sfx_data: []const u8) void {
        self.music_data = music_data;
        self.sfx_data = sfx_data;
    }

    fn extract_music_frame_flags(self: *AudioEngine, music_id: usize) MusicFrameFlags {
        const music_index = music_id * 4;
        const music_frame = self.music_data[music_index .. music_index + 4];

        const flag_mask = 0b1000_0000;
        const loop_start = (music_frame[0] & flag_mask) != 0;
        const loop_end = (music_frame[1] & flag_mask) != 0;
        const stop = (music_frame[2] & flag_mask) != 0;
        return MusicFrameFlags{
            .loop_start = loop_start,
            .loop_end = loop_end,
            .stop = stop,
        };
    }

    pub fn sample(self: *AudioEngine) f64 {
        if (self.pause) {
            return 0;
        }
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

        if (self.music_playing) {
            if (self.channels[self.tracked_channel].finished_playing()) {
                self.music_playing = false;
                var music_frame_flags = self.extract_music_frame_flags(self.music_id);
                if (!music_frame_flags.stop) {
                    if (music_frame_flags.loop_end) {
                        var m_id = self.music_id;

                        // "rewinding"
                        while (m_id >= 0 and music_frame_flags.loop_start == false) {
                            music_frame_flags = self.extract_music_frame_flags(m_id);
                            if (music_frame_flags.loop_start) {
                                self.play_music(@intCast(m_id), 0, 0); // TODO preserve mask?
                                break;
                            }
                            if (m_id == 0) {
                                break;
                            } else {
                                m_id -= 1;
                            }
                        }
                    } else {
                        self.play_music(@intCast(self.music_id + 1), 0, 0); // TODO preserve mask?
                    }
                }
            } else {
                for (CHANNEL_MUSIC_START..CHANNEL_MUSIC_END) |channel| {
                    if (channel != self.tracked_channel and self.channels[channel].finished_playing()) {
                        self.play_sfx_on_channel(self.channels[channel].sfx_id, channel);
                    }
                }
            }
        }
        return result;
    }

    fn play_sfx_on_channel(self: *AudioEngine, sfx_id: usize, channel_id: usize) void {
        const sfx_index = sfx_id * 68;
        const data = self.sfx_data[sfx_index .. sfx_index + 68];
        self.channels[channel_id].play_sfx(sfx_id, data);
    }

    pub fn play_sfx(self: *AudioEngine, sfx_id: usize) void {
        var channel: usize = CHANNEL_SFX_START;
        for (CHANNEL_SFX_START..CHANNEL_SFX_END) |i| {
            if (self.channels[i].playing == false or self.channels[i].sfx_id == sfx_id) {
                channel = i;
                break;
            }
        }
        self.play_sfx_on_channel(sfx_id, channel);
    }

    pub fn play_music(self: *AudioEngine, music_id: isize, fade: u32, mask: u32) void {
        _ = fade;
        _ = mask;
        for (CHANNEL_MUSIC_START..CHANNEL_MUSIC_END) |channel| {
            self.channels[channel].stop();
        }

        self.music_playing = false;

        if (music_id == -1) {
            return;
        }

        const music_index = @as(usize, @intCast(music_id)) * 4;
        const music_frame = self.music_data[music_index .. music_index + 4];

        for (CHANNEL_MUSIC_START..CHANNEL_MUSIC_END) |channel| {
            const sfx = music_frame[channel];

            // bit 6 == 0 is required to play music
            if (sfx & (1 << 6) == 0) {
                const sfx_id: usize = sfx & 0b111111;
                self.play_sfx_on_channel(sfx_id, channel);
                if (self.music_playing == false) { // this is here so that we can track the 1st active channel
                    self.music_id = @intCast(music_id);
                    self.music_playing = true;
                }
            }
        }
        self.tracked_channel = 0;
        var speed: f64 = 0;
        for (CHANNEL_MUSIC_START..CHANNEL_MUSIC_END) |channel| {
            if (self.channels[channel].sfx_speed > speed) {
                speed = self.channels[channel].sfx_speed;
                self.tracked_channel = channel;
            }
        }
    }
};
