//! Winamp's ten-band graphic equalizer.
//!
//! Implemented as a single miniaudio node holding a chain of peaking
//! biquads, rather than ten chained `ma_peak_node`s: one node means one
//! graph hop, and preamp and bypass become trivial.
//!
//! Gains are changed from the UI thread while the audio thread is running,
//! so the two sides communicate through a generation counter. The UI writes
//! the gains and bumps the counter; the audio callback notices the change
//! and reinitializes the affected filters at the top of its next block.
//! `ma_peak2_reinit` only recomputes coefficients — it does not allocate —
//! so it is safe to call there.

const std = @import("std");
const c = @import("../c.zig").c;

pub const band_count = 10;

/// Winamp's band centres, in hertz.
pub const band_frequencies = [band_count]f32{
    60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000,
};

/// Winamp's range: twelve decibels either way, for the bands and the preamp.
pub const gain_limit_db: f32 = 12;

/// Q for each band. Wide enough that ten bands cover the spectrum without
/// gaps, narrow enough that one band does not swamp its neighbours.
const band_q: f64 = 1.1;

pub const Error = error{ NodeInitFailed, FilterInitFailed, AttachFailed };

/// The user-visible settings. Plain data, so presets and the config file can
/// be expressed as values.
pub const Settings = struct {
    enabled: bool = false,
    preamp_db: f32 = 0,
    bands_db: [band_count]f32 = @splat(0),

    pub fn clampAll(s: *Settings) void {
        s.preamp_db = std.math.clamp(s.preamp_db, -gain_limit_db, gain_limit_db);
        for (&s.bands_db) |*g| g.* = std.math.clamp(g.*, -gain_limit_db, gain_limit_db);
    }

    pub fn reset(s: *Settings) void {
        s.preamp_db = 0;
        s.bands_db = @splat(0);
    }

    /// True when every control is centred, so the UI can show that the EQ is
    /// doing nothing even while it is switched on.
    pub fn isFlat(s: Settings) bool {
        if (@abs(s.preamp_db) > 0.01) return false;
        for (s.bands_db) |g| if (@abs(g) > 0.01) return false;
        return true;
    }
};

pub const Preset = struct {
    name: []const u8,
    bands_db: [band_count]f32,
};

/// Winamp's stock presets, in its own order.
pub const presets = [_]Preset{
    .{ .name = "Flat", .bands_db = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "Rock", .bands_db = .{ 8, 5, -5, -8, -3, 4, 8, 11, 11, 11 } },
    .{ .name = "Metal", .bands_db = .{ 7, 4, 0, -5, -3, 2, 7, 10, 10, 10 } },
    .{ .name = "Pop", .bands_db = .{ -2, 4, 7, 8, 5, 0, -2, -2, -1, -1 } },
    .{ .name = "Jazz", .bands_db = .{ 6, 4, 1, 2, -2, -2, 0, 1, 3, 5 } },
    .{ .name = "Classical", .bands_db = .{ 5, 4, 3, 2, -2, -2, 0, 2, 3, 4 } },
    .{ .name = "Dance", .bands_db = .{ 9, 7, 2, 0, 0, -5, -7, -7, 0, 0 } },
    .{ .name = "Bass", .bands_db = .{ 11, 10, 9, 6, 2, -2, -5, -7, -8, -8 } },
    .{ .name = "Treble", .bands_db = .{ -8, -8, -7, -4, 1, 6, 10, 11, 11, 11 } },
    .{ .name = "Vocal", .bands_db = .{ -5, -8, -5, 4, 7, 7, 4, 0, -3, -5 } },
};

/// True when `settings` still matches `preset`'s band shape. Once a slider
/// has been moved the display must stop claiming the preset's name, or the
/// window says "Flat" over a visibly jagged curve.
pub fn matchesPreset(settings: Settings, preset: Preset) bool {
    for (settings.bands_db, preset.bands_db) |a, b| {
        if (@abs(a - b) > 0.01) return false;
    }
    return true;
}

pub fn presetByName(name: []const u8) ?Preset {
    for (presets) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    }
    return null;
}

/// Amplitude multiplier for a decibel gain.
pub fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20);
}

/// The filter chain, independent of the node graph.
///
/// Kept separate from `Node` so the actual signal processing can be tested
/// without standing up a miniaudio engine: the tests below run noise through
/// it and check the spectrum really moves.
pub const Chain = extern struct {
    /// miniaudio's biquads are multi-channel, so one filter per band covers
    /// every channel.
    filters: [band_count]c.ma_peak2,
    channels: u32,
    sample_rate: u32,
    preamp_linear: f32,

    pub fn init(ch: *Chain, channels: u32, sample_rate: u32) Error!void {
        ch.channels = channels;
        ch.sample_rate = sample_rate;
        ch.preamp_linear = 1;
        for (&ch.filters, 0..) |*f, i| {
            const cfg = c.ma_peak2_config_init(
                c.ma_format_f32,
                channels,
                sample_rate,
                0,
                band_q,
                band_frequencies[i],
            );
            if (c.ma_peak2_init(&cfg, null, f) != c.MA_SUCCESS) return error.FilterInitFailed;
        }
    }

    pub fn deinit(ch: *Chain) void {
        for (&ch.filters) |*f| c.ma_peak2_uninit(f, null);
    }

    /// Recompute coefficients. `ma_peak2_reinit` does no allocation, so this
    /// is safe to call from the audio callback.
    pub fn apply(ch: *Chain, s: Settings) void {
        ch.preamp_linear = dbToLinear(std.math.clamp(
            s.preamp_db,
            -gain_limit_db,
            gain_limit_db,
        ));
        for (&ch.filters, 0..) |*f, i| {
            const cfg = c.ma_peak2_config_init(
                c.ma_format_f32,
                ch.channels,
                ch.sample_rate,
                std.math.clamp(s.bands_db[i], -gain_limit_db, gain_limit_db),
                band_q,
                band_frequencies[i],
            );
            _ = c.ma_peak2_reinit(&cfg, f);
        }
    }

    /// `out` and `in` are interleaved f32 and may be the same buffer.
    pub fn process(ch: *Chain, out: [*]f32, in: [*]const f32, frames: u32) void {
        const samples = frames * ch.channels;
        const gain = ch.preamp_linear;
        for (0..samples) |i| out[i] = in[i] * gain;
        for (&ch.filters) |*f| {
            _ = c.ma_peak2_process_pcm_frames(f, out, out, frames);
        }
    }
};

/// The audio node.
///
/// `base` must be first: miniaudio casts the node pointer to `ma_node_base*`.
/// Like every miniaudio node it registers its own address in the graph, so
/// it must never be copied or moved once initialized.
pub const Node = extern struct {
    base: c.ma_node_base,
    chain: Chain,
    /// Published by the UI thread, read by the audio thread.
    shared: *Shared,
    /// The generation the filters were last built for.
    applied_generation: u32,

    /// The cross-thread channel. The UI writes `settings` then bumps
    /// `generation`; the audio thread reads `generation` first and only
    /// re-reads the settings when it has changed.
    pub const Shared = struct {
        generation: std.atomic.Value(u32) = .init(1),
        enabled: std.atomic.Value(bool) = .init(false),
        /// Guarded by `generation`: only written between bumps.
        settings: Settings = .{},

        pub fn publish(s: *Shared, next: Settings) void {
            var copy = next;
            copy.clampAll();
            s.settings = copy;
            s.enabled.store(copy.enabled, .release);
            _ = s.generation.fetchAdd(1, .release);
        }
    };

    const vtable: c.ma_node_vtable = .{
        .onProcess = onProcess,
        .onGetRequiredInputFrameCount = null,
        .inputBusCount = 1,
        .outputBusCount = 1,
        .flags = 0,
    };

    /// Runs on the audio thread. Must not allocate, lock, or block.
    fn onProcess(
        node: ?*anyopaque,
        frames_in: [*c]const [*c]const f32,
        frame_count_in: [*c]c.ma_uint32,
        frames_out: [*c][*c]f32,
        frame_count_out: [*c]c.ma_uint32,
    ) callconv(.c) void {
        const self: *Node = @ptrCast(@alignCast(node orelse return));

        const n = @min(frame_count_in[0], frame_count_out[0]);
        frame_count_in[0] = n;
        frame_count_out[0] = n;
        if (n == 0) return;

        const in = frames_in[0] orelse return;
        const out = frames_out[0] orelse return;

        const samples_len = n * self.chain.channels;

        // Pick up any change the UI has published since the last block.
        const generation = self.shared.generation.load(.acquire);
        if (generation != self.applied_generation) {
            self.chain.apply(self.shared.settings);
            self.applied_generation = generation;
        }

        if (!self.shared.enabled.load(.acquire)) {
            @memcpy(out[0..samples_len], in[0..samples_len]);
            return;
        }
        self.chain.process(out, in, n);
    }

    /// Insert into the engine's graph, feeding `output`.
    pub fn init(
        self: *Node,
        node_graph: ?*c.ma_node_graph,
        output: ?*anyopaque,
        shared: *Shared,
        channels: u32,
        sample_rate: u32,
    ) Error!void {
        self.shared = shared;
        self.applied_generation = 0;
        try self.chain.init(channels, sample_rate);

        var cfg = c.ma_node_config_init();
        cfg.vtable = &vtable;
        cfg.pInputChannels = &[_]c.ma_uint32{channels};
        cfg.pOutputChannels = &[_]c.ma_uint32{channels};

        if (c.ma_node_init(node_graph, &cfg, null, &self.base) != c.MA_SUCCESS) {
            return error.NodeInitFailed;
        }
        if (c.ma_node_attach_output_bus(&self.base, 0, output, 0) != c.MA_SUCCESS) {
            return error.AttachFailed;
        }
    }

    pub fn deinit(self: *Node) void {
        c.ma_node_uninit(&self.base, null);
        self.chain.deinit();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "dbToLinear at the reference points" {
    try testing.expectApproxEqAbs(@as(f32, 1), dbToLinear(0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), dbToLinear(6.0206), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dbToLinear(-6.0206), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), dbToLinear(20), 0.001);
}

test "settings clamp to Winamp's range" {
    var s: Settings = .{ .preamp_db = 99, .bands_db = @splat(-99) };
    s.clampAll();
    try testing.expectEqual(gain_limit_db, s.preamp_db);
    for (s.bands_db) |g| try testing.expectEqual(-gain_limit_db, g);
}

test "isFlat and reset" {
    var s: Settings = .{};
    try testing.expect(s.isFlat());

    s.bands_db[4] = 0.5;
    try testing.expect(!s.isFlat());
    s.reset();
    try testing.expect(s.isFlat());

    s.preamp_db = -3;
    try testing.expect(!s.isFlat());

    // A value too small to hear does not count as a change.
    s.reset();
    s.bands_db[0] = 0.001;
    try testing.expect(s.isFlat());
}

test "band frequencies ascend and match Winamp's" {
    var prev: f32 = 0;
    for (band_frequencies) |f| {
        try testing.expect(f > prev);
        prev = f;
    }
    try testing.expectEqual(@as(f32, 60), band_frequencies[0]);
    try testing.expectEqual(@as(f32, 16000), band_frequencies[band_count - 1]);
}

test "presets are in range and lookup is case-insensitive" {
    for (presets) |p| {
        try testing.expect(p.name.len > 0);
        for (p.bands_db) |g| {
            try testing.expect(g >= -gain_limit_db and g <= gain_limit_db);
        }
    }
    try testing.expectEqualStrings("Rock", presetByName("rock").?.name);
    try testing.expectEqualStrings("Flat", presetByName("FLAT").?.name);
    try testing.expect(presetByName("nonsense") == null);

    // The Flat preset really is flat.
    for (presetByName("Flat").?.bands_db) |g| try testing.expectEqual(@as(f32, 0), g);
}

test "publishing clamps and bumps the generation" {
    var shared: Node.Shared = .{};
    const before = shared.generation.load(.monotonic);

    shared.publish(.{ .enabled = true, .preamp_db = 50, .bands_db = @splat(-50) });

    try testing.expect(shared.generation.load(.monotonic) > before);
    try testing.expect(shared.enabled.load(.monotonic));
    try testing.expectEqual(gain_limit_db, shared.settings.preamp_db);
    try testing.expectEqual(-gain_limit_db, shared.settings.bands_db[0]);
}

test "the node's base field sits at offset zero" {
    // miniaudio casts the node pointer straight to ma_node_base*, so this
    // has to hold or the audio thread walks garbage.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Node, "base"));
}

// --- DSP tests -------------------------------------------------------------
//
// These run the real filter chain, so they prove the equalizer actually
// equalizes rather than just that the UI plumbing compiles.

const fft_mod = @import("fft.zig");

const test_rate: u32 = 48000;
const test_n = 4096;
const TestFft = fft_mod.Fft(test_n);

/// Total magnitude in a frequency range, as the FFT sees it.
fn bandEnergy(f: *const TestFft, lo_hz: f32, hi_hz: f32) f64 {
    const per_hz = @as(f32, test_n) / @as(f32, @floatFromInt(test_rate));
    const lo: usize = @intFromFloat(@max(lo_hz * per_hz, 1));
    const hi: usize = @min(@as(usize, @intFromFloat(hi_hz * per_hz)), test_n / 2);
    var total: f64 = 0;
    for (lo..hi) |k| total += f.magnitude(k);
    return total;
}

/// Deterministic white noise: flat input, so any shape in the output is the
/// filter's doing.
fn fillNoise(buf: []f32) void {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    for (buf) |*v| v.* = rand.float(f32) * 2 - 1;
}

/// Run mono noise through a chain configured with `settings`.
fn runChain(gpa: std.mem.Allocator, settings: Settings, out: []f32) !void {
    var chain: Chain = undefined;
    try chain.init(1, test_rate);
    defer chain.deinit();
    chain.apply(settings);

    const in = try gpa.alloc(f32, out.len);
    defer gpa.free(in);
    fillNoise(in);

    // Discard a settling block so the biquad state does not colour the
    // window we measure.
    const warmup = try gpa.alloc(f32, out.len);
    defer gpa.free(warmup);
    chain.process(warmup.ptr, in.ptr, @intCast(out.len));
    chain.process(out.ptr, in.ptr, @intCast(out.len));
}

test "a flat chain leaves the spectrum alone" {
    const gpa = testing.allocator;
    const out = try gpa.alloc(f32, test_n);
    defer gpa.free(out);
    try runChain(gpa, .{}, out);

    const f = try gpa.create(TestFft);
    defer gpa.destroy(f);
    f.* = .{};
    f.loadWindowed(out);
    f.run();

    const low = bandEnergy(f, 40, 120);
    const high = bandEnergy(f, 10000, 16000);
    // Noise is flat, and a flat EQ keeps it that way: the high band is wider
    // so it holds more total energy, but neither should be near-silent.
    try testing.expect(low > 0);
    try testing.expect(high > 0);
}

test "boosting the low bands raises low-frequency energy and cutting lowers it" {
    const gpa = testing.allocator;
    const out = try gpa.alloc(f32, test_n);
    defer gpa.free(out);
    const f = try gpa.create(TestFft);
    defer gpa.destroy(f);

    try runChain(gpa, .{}, out);
    f.* = .{};
    f.loadWindowed(out);
    f.run();
    const flat_low = bandEnergy(f, 40, 120);

    // +12dB on the 60Hz band.
    var boosted: Settings = .{};
    boosted.bands_db[0] = gain_limit_db;
    try runChain(gpa, boosted, out);
    f.* = .{};
    f.loadWindowed(out);
    f.run();
    const boosted_low = bandEnergy(f, 40, 120);

    var cut: Settings = .{};
    cut.bands_db[0] = -gain_limit_db;
    try runChain(gpa, cut, out);
    f.* = .{};
    f.loadWindowed(out);
    f.run();
    const cut_low = bandEnergy(f, 40, 120);

    // +12dB is a factor of four in amplitude; allow plenty of slack for the
    // filter's shape, but the ordering and rough magnitude must hold.
    try testing.expect(boosted_low > flat_low * 2);
    try testing.expect(cut_low < flat_low * 0.6);
}

test "a band only moves its own part of the spectrum" {
    const gpa = testing.allocator;
    const out = try gpa.alloc(f32, test_n);
    defer gpa.free(out);
    const f = try gpa.create(TestFft);
    defer gpa.destroy(f);

    try runChain(gpa, .{}, out);
    f.* = .{};
    f.loadWindowed(out);
    f.run();
    const flat_low = bandEnergy(f, 40, 120);
    const flat_high = bandEnergy(f, 10000, 16000);

    // Boost only the 60Hz band.
    var low_boost: Settings = .{};
    low_boost.bands_db[0] = gain_limit_db;
    try runChain(gpa, low_boost, out);
    f.* = .{};
    f.loadWindowed(out);
    f.run();

    try testing.expect(bandEnergy(f, 40, 120) > flat_low * 2);
    // The top of the spectrum is essentially untouched.
    const high_ratio = bandEnergy(f, 10000, 16000) / flat_high;
    try testing.expect(high_ratio > 0.9 and high_ratio < 1.1);
}

test "the Bass and Treble presets tilt the spectrum in opposite directions" {
    const gpa = testing.allocator;
    const out = try gpa.alloc(f32, test_n);
    defer gpa.free(out);
    const f = try gpa.create(TestFft);
    defer gpa.destroy(f);

    var bass_ratio: f64 = 0;
    var treble_ratio: f64 = 0;

    for ([_][]const u8{ "Bass", "Treble" }, 0..) |name, i| {
        var s: Settings = .{ .bands_db = presetByName(name).?.bands_db };
        s.enabled = true;
        try runChain(gpa, s, out);
        f.* = .{};
        f.loadWindowed(out);
        f.run();

        const ratio = bandEnergy(f, 40, 200) / bandEnergy(f, 8000, 16000);
        if (i == 0) bass_ratio = ratio else treble_ratio = ratio;
    }

    // Bass puts far more energy low relative to high than Treble does.
    try testing.expect(bass_ratio > treble_ratio * 4);
}

test "the preamp scales everything without reshaping it" {
    const gpa = testing.allocator;
    const quiet = try gpa.alloc(f32, test_n);
    defer gpa.free(quiet);
    const loud = try gpa.alloc(f32, test_n);
    defer gpa.free(loud);

    try runChain(gpa, .{}, quiet);
    try runChain(gpa, .{ .preamp_db = 6.0206 }, loud);

    // Every sample is scaled by the same factor, so the waveform's shape is
    // unchanged: exactly what a preamp should do.
    for (quiet, loud) |q, l| {
        try testing.expectApproxEqAbs(q * 2, l, 0.001);
    }
}

test "processing in place matches processing into a separate buffer" {
    const gpa = testing.allocator;
    var settings: Settings = .{ .bands_db = presetByName("Rock").?.bands_db };
    settings.preamp_db = -3;

    const in = try gpa.alloc(f32, 1024);
    defer gpa.free(in);
    fillNoise(in);

    const separate = try gpa.alloc(f32, 1024);
    defer gpa.free(separate);
    const in_place = try gpa.alloc(f32, 1024);
    defer gpa.free(in_place);
    @memcpy(in_place, in);

    var a: Chain = undefined;
    try a.init(1, test_rate);
    defer a.deinit();
    a.apply(settings);
    a.process(separate.ptr, in.ptr, 1024);

    var b: Chain = undefined;
    try b.init(1, test_rate);
    defer b.deinit();
    b.apply(settings);
    b.process(in_place.ptr, in_place.ptr, 1024);

    for (separate, in_place) |x, y| try testing.expectApproxEqAbs(x, y, 1e-6);
}

test "stereo frames keep their channels independent" {
    const gpa = testing.allocator;
    var chain: Chain = undefined;
    try chain.init(2, test_rate);
    defer chain.deinit();

    var settings: Settings = .{};
    settings.bands_db[0] = gain_limit_db;
    chain.apply(settings);

    // Left carries noise, right is silent.
    const frames = 2048;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    const noise = try gpa.alloc(f32, frames);
    defer gpa.free(noise);
    fillNoise(noise);
    for (0..frames) |i| {
        buf[i * 2] = noise[i];
        buf[i * 2 + 1] = 0;
    }

    chain.process(buf.ptr, buf.ptr, frames);

    // A silent channel must stay silent no matter what the filters do.
    for (0..frames) |i| try testing.expectApproxEqAbs(@as(f32, 0), buf[i * 2 + 1], 1e-6);
    var any_left: bool = false;
    for (0..frames) |i| {
        if (@abs(buf[i * 2]) > 0.01) any_left = true;
    }
    try testing.expect(any_left);
}

test "matchesPreset notices a moved slider" {
    const flat = presetByName("Flat").?;
    var s: Settings = .{};
    try testing.expect(matchesPreset(s, flat));

    // A change too small to hear does not count.
    s.bands_db[0] = 0.001;
    try testing.expect(matchesPreset(s, flat));

    s.bands_db[0] = 3;
    try testing.expect(!matchesPreset(s, flat));

    // Loading a preset makes it match again.
    const rock = presetByName("Rock").?;
    s.bands_db = rock.bands_db;
    try testing.expect(matchesPreset(s, rock));
    try testing.expect(!matchesPreset(s, flat));

    // The preamp is not part of the band shape, so it does not break a match.
    s.preamp_db = 6;
    try testing.expect(matchesPreset(s, rock));
}
