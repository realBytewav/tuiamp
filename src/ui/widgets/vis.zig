//! The visualizer: Winamp's spectrum analyzer and oscilloscope.
//!
//! The analyzer owns its own smoothing state, because what makes Winamp's
//! display read as music rather than as noise is not the FFT — it is the
//! fast attack, slow decay, and the peak caps that hang above the bars and
//! sink at a constant rate.
//!
//! Bars are spaced logarithmically in frequency. Linear spacing would put
//! almost every bar above 5kHz, where there is nothing to see, and crush the
//! bass into the first column.

const std = @import("std");
const screen = @import("../../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("../theme.zig").Theme;
const fft_mod = @import("../../audio/fft.zig");

pub const Mode = enum {
    spectrum,
    oscilloscope,
    off,

    /// Clicking the analyzer cycles it, as Winamp does.
    pub fn next(m: Mode) Mode {
        return switch (m) {
            .spectrum => .oscilloscope,
            .oscilloscope => .off,
            .off => .spectrum,
        };
    }
};

/// Samples per FFT. At 48kHz this is ~21ms, which resolves down to ~47Hz —
/// enough to separate the low bars without smearing transients.
pub const window = 1024;
/// No terminal is going to give the analyzer more columns than this.
pub const max_bars = 256;

const Fft = fft_mod.Fft(window);

/// Display range. Below the floor is silence; at the ceiling a bar is full.
/// Wide enough that loud music does not simply peg every band.
const db_floor: f32 = -62;
const db_ceiling: f32 = -24;

/// Music has far more energy at the bottom of the spectrum than the top, so
/// an untilted analyzer is a wall of bass with a flat line beside it. Winamp
/// tilts its display upward; this is the same idea.
///
/// The tilt pivots around the middle of the displayed range — cutting the
/// bass as much as it lifts the treble — so that evening out the slope does
/// not also drive the whole display hot.
const tilt_db_per_octave: f32 = 3.0;

/// Bars jump to a new peak immediately and sink slowly, per frame at 25fps.
const bar_decay: f32 = 0.055;
/// Caps hang, then sink more slowly still.
const peak_decay: f32 = 0.018;
const peak_hang_frames: u8 = 12;

/// Frequency span of the display. The top is clamped to Nyquist.
const freq_lo: f32 = 45;
const freq_hi: f32 = 15000;

pub const Analyzer = struct {
    mode: Mode = .spectrum,
    fft: Fft = .{},
    /// Smoothed bar heights, 0..1.
    bars: [max_bars]f32 = @splat(0),
    peaks: [max_bars]f32 = @splat(0),
    peak_hold: [max_bars]u8 = @splat(0),
    /// Raw samples for the oscilloscope, newest last.
    scope: [max_bars]f32 = @splat(0),
    bar_count: usize = 0,
    /// Set when the tap had nothing to give, so the display decays to rest
    /// instead of freezing on the last frame.
    silent: bool = true,

    /// Feed one frame's worth of audio. `samples` is the newest window,
    /// oldest first; pass an empty slice when none is available.
    pub fn update(a: *Analyzer, samples: []const f32, sample_rate: u32, columns: usize) void {
        const n = @min(columns, max_bars);
        a.bar_count = n;
        a.silent = samples.len == 0;

        if (a.silent or sample_rate == 0 or n == 0) {
            a.decayAll();
            return;
        }

        switch (a.mode) {
            .off => {},
            .oscilloscope => a.updateScope(samples, n),
            .spectrum => a.updateSpectrum(samples, sample_rate, n),
        }
    }

    fn updateSpectrum(a: *Analyzer, samples: []const f32, sample_rate: u32, n: usize) void {
        a.fft.loadWindowed(samples);
        a.fft.run();

        const nyquist = @as(f32, @floatFromInt(sample_rate)) / 2;
        const hi = @min(freq_hi, nyquist * 0.95);
        const bins_per_hz = @as(f32, @floatFromInt(window)) / @as(f32, @floatFromInt(sample_rate));

        for (0..n) |i| {
            const lo_f = bandEdge(freq_lo, hi, i, n);
            const hi_f = bandEdge(freq_lo, hi, i + 1, n);

            // Always cover at least one bin, or the narrow low bands fall
            // between bins and read as silence.
            var lo_bin: usize = @intFromFloat(@max(lo_f * bins_per_hz, 1));
            var hi_bin: usize = @intFromFloat(@max(hi_f * bins_per_hz, 1));
            lo_bin = @min(lo_bin, window / 2 - 1);
            hi_bin = @min(@max(hi_bin, lo_bin + 1), window / 2);

            // RMS rather than peak across the band. A high band spans
            // hundreds of bins, and taking the single loudest one makes wide
            // bands read hot regardless of how much energy is really there.
            var energy: f32 = 0;
            for (lo_bin..hi_bin) |k| {
                const m = a.fft.magnitude(k);
                energy += m * m;
            }
            const rms = @sqrt(energy / @as(f32, @floatFromInt(hi_bin - lo_bin)));

            a.applyLevel(i, normalize(rms, tiltDb(lo_f, hi)));
        }
        a.decayFrom(n);
    }

    fn updateScope(a: *Analyzer, samples: []const f32, n: usize) void {
        // Spread the window across the available columns.
        for (0..n) |i| {
            const at = (i * (samples.len - 1)) / @max(n - 1, 1);
            a.scope[i] = samples[@min(at, samples.len - 1)];
        }
    }

    /// Fast attack, slow decay, with a hanging peak cap.
    fn applyLevel(a: *Analyzer, i: usize, level: f32) void {
        if (level >= a.bars[i]) {
            a.bars[i] = level;
        } else {
            a.bars[i] = @max(level, a.bars[i] - bar_decay);
        }

        if (a.bars[i] >= a.peaks[i]) {
            a.peaks[i] = a.bars[i];
            a.peak_hold[i] = peak_hang_frames;
        } else if (a.peak_hold[i] > 0) {
            a.peak_hold[i] -= 1;
        } else {
            a.peaks[i] = @max(a.bars[i], a.peaks[i] - peak_decay);
        }
    }

    fn decayAll(a: *Analyzer) void {
        a.decayFrom(0);
    }

    fn decayFrom(a: *Analyzer, start: usize) void {
        for (start..max_bars) |i| {
            a.bars[i] = @max(0, a.bars[i] - bar_decay);
            a.peaks[i] = @max(a.bars[i], a.peaks[i] - peak_decay);
            a.scope[i] *= 0.8;
        }
    }

    pub fn draw(a: *const Analyzer, p: Painter, th: Theme) void {
        const size = p.size();
        const w = @min(size.x, @as(u16, @intCast(@min(a.bar_count, max_bars))));
        const h = size.y;
        if (w == 0 or h == 0) return;

        p.fill(th.onLcd(th.lcd_fg));
        switch (a.mode) {
            .off => {},
            .spectrum => a.drawSpectrum(p, th, w, h),
            .oscilloscope => a.drawScope(p, th, w, h),
        }
    }

    fn drawSpectrum(a: *const Analyzer, p: Painter, th: Theme, w: u16, h: u16) void {
        const g = th.glyphs;
        const eighths_total: u32 = @as(u32, h) * 8;

        for (0..w) |col| {
            const x: u16 = @intCast(col);
            const level = std.math.clamp(a.bars[col], 0, 1);
            const filled: u32 = @intFromFloat(@round(level * @as(f32, @floatFromInt(eighths_total))));

            var row: u16 = 0;
            while (row < h) : (row += 1) {
                // Row 0 is the top of the box, so count from the bottom.
                const from_bottom = h - 1 - row;
                const remaining = filled -| (@as(u32, from_bottom) * 8);
                const level_in_cell: usize = @min(remaining, 8);
                if (level_in_cell == 0) continue;

                // Colour by absolute height in the box, so a bar's tip is
                // red whatever the terminal's size.
                const t = @as(f32, @floatFromInt(from_bottom)) /
                    @as(f32, @floatFromInt(@max(h - 1, 1)));
                p.set(x, row, .{
                    .cp = g.bars[level_in_cell],
                    .style = th.onLcd(th.visColor(t)),
                });
            }

            // The peak cap, drawn only where it is clear of the bar itself.
            const peak = std.math.clamp(a.peaks[col], 0, 1);
            if (peak > level + 0.02) {
                const peak_row = rowForLevel(peak, h);
                if (peak_row < h) {
                    p.set(x, peak_row, .{ .cp = g.peak, .style = th.onLcd(th.vis_peak) });
                }
            }
        }
    }

    /// Half-block glyphs give the trace two sub-rows per cell, which is the
    /// difference between a recognizable waveform and a row of dashes in a
    /// box only a few cells tall.
    fn drawScope(a: *const Analyzer, p: Painter, th: Theme, w: u16, h: u16) void {
        const g = th.glyphs;
        const sub_rows: u16 = h * 2;
        var prev_sub: ?u16 = null;

        for (0..w) |col| {
            const x: u16 = @intCast(col);
            const v = std.math.clamp(a.scope[col], -1, 1);
            const sub = subRow(v, sub_rows);
            const style = th.onLcd(th.visColor(@abs(v)));

            // Join to the previous column, so a steep slope reads as a line
            // rather than as two disconnected dots.
            const lo = if (prev_sub) |ps| @min(ps, sub) else sub;
            const hi = if (prev_sub) |ps| @max(ps, sub) else sub;

            var row: u16 = lo / 2;
            while (row <= hi / 2) : (row += 1) {
                const upper = row * 2;
                const lower = upper + 1;
                const has_upper = upper >= lo and upper <= hi;
                const has_lower = lower >= lo and lower <= hi;
                const cp: u21 = if (has_upper and has_lower)
                    g.scope
                else if (has_upper)
                    g.scope_hi
                else
                    g.scope_lo;
                p.set(x, row, .{ .cp = cp, .style = style });
            }
            prev_sub = sub;
        }
    }
};

/// Row index for a 0..1 level, measured from the top of an `h`-row box.
fn rowForLevel(level: f32, h: u16) u16 {
    const clamped = std.math.clamp(level, 0, 1);
    const from_bottom = clamped * @as(f32, @floatFromInt(h));
    const row = @as(f32, @floatFromInt(h)) - from_bottom;
    return @intFromFloat(std.math.clamp(row, 0, @as(f32, @floatFromInt(h - 1))));
}

/// Spectral tilt in dB for a band starting at `lo_f`, pivoting around the
/// geometric middle of the displayed range.
fn tiltDb(lo_f: f32, hi: f32) f32 {
    const total_octaves = std.math.log2(@max(hi, freq_lo * 2) / freq_lo);
    const octaves = std.math.log2(@max(lo_f, freq_lo) / freq_lo);
    return (octaves - total_octaves / 2) * tilt_db_per_octave;
}

/// Sub-row for an amplitude in -1..1, where 0 is the top of the box.
fn subRow(v: f32, sub_rows: u16) u16 {
    const t = (1.0 - std.math.clamp(v, -1, 1)) / 2.0;
    const last: f32 = @floatFromInt(sub_rows - 1);
    return @intFromFloat(std.math.clamp(@round(t * last), 0, last));
}

/// Logarithmic band edge: `i` of `n` between `lo` and `hi` hertz.
fn bandEdge(lo: f32, hi: f32, i: usize, n: usize) f32 {
    if (n == 0) return lo;
    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
    return lo * std.math.pow(f32, hi / lo, t);
}

/// FFT magnitude to a 0..1 display level, through decibels. `boost_db` is
/// the per-band spectral tilt.
fn normalize(magnitude: f32, boost_db: f32) f32 {
    // A full-scale sine through a Hann window of this size peaks near N/4.
    const full_scale = @as(f32, @floatFromInt(window)) / 4;
    const ratio = magnitude / full_scale;
    if (ratio <= 1e-7) return 0;
    const db = 20 * std.math.log10(ratio) + boost_db;
    return std.math.clamp((db - db_floor) / (db_ceiling - db_floor), 0, 1);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "Mode cycles back around" {
    try testing.expectEqual(Mode.oscilloscope, Mode.spectrum.next());
    try testing.expectEqual(Mode.off, Mode.oscilloscope.next());
    try testing.expectEqual(Mode.spectrum, Mode.off.next());
}

test "band edges rise monotonically and span the range" {
    const n = 20;
    var prev: f32 = 0;
    for (0..n + 1) |i| {
        const f = bandEdge(45, 15000, i, n);
        try testing.expect(f > prev);
        prev = f;
    }
    try testing.expectApproxEqRel(@as(f32, 45), bandEdge(45, 15000, 0, n), 0.001);
    try testing.expectApproxEqRel(@as(f32, 15000), bandEdge(45, 15000, n, n), 0.001);
    // Logarithmic, so the low bands are much narrower than the high ones.
    const low_span = bandEdge(45, 15000, 1, n) - bandEdge(45, 15000, 0, n);
    const high_span = bandEdge(45, 15000, n, n) - bandEdge(45, 15000, n - 1, n);
    try testing.expect(high_span > low_span * 10);
}

test "normalize maps silence to zero and full scale to one" {
    try testing.expectEqual(@as(f32, 0), normalize(0, 0));
    try testing.expectApproxEqAbs(@as(f32, 1), normalize(window / 4, 0), 0.001);
    // Monotonic in between.
    var prev: f32 = 0;
    var m: f32 = 1;
    while (m < window / 4) : (m *= 1.5) {
        const v = normalize(m, 0);
        try testing.expect(v >= prev);
        prev = v;
    }
}

test "the tilt cuts the bass as much as it lifts the treble" {
    const hi = freq_hi;
    const total = std.math.log2(hi / freq_lo);
    // Lowest band is cut, highest is lifted, by the same amount.
    const low = tiltDb(freq_lo, hi);
    const high = tiltDb(hi, hi);
    try testing.expect(low < 0);
    try testing.expect(high > 0);
    try testing.expectApproxEqAbs(low, -high, 0.01);
    // And the midpoint is untouched.
    const mid_f = freq_lo * std.math.pow(f32, 2, total / 2);
    try testing.expectApproxEqAbs(@as(f32, 0), tiltDb(mid_f, hi), 0.01);
}

test "the spectral tilt lifts quiet high bands without pegging loud ones" {
    const mid = @as(f32, window) / 400;
    // The same magnitude reads higher once tilted.
    try testing.expect(normalize(mid, 12) > normalize(mid, 0));
    // And the tilt cannot push anything past full scale.
    try testing.expectEqual(@as(f32, 1), normalize(window / 4, 40));
    try testing.expectEqual(@as(f32, 0), normalize(0, 40));
}

test "subRow spans the box and centres silence" {
    // 4 cells -> 8 sub-rows, 0 at the top.
    try testing.expectEqual(@as(u16, 0), subRow(1.0, 8));
    try testing.expectEqual(@as(u16, 7), subRow(-1.0, 8));
    try testing.expectEqual(@as(u16, 4), subRow(0.0, 8));
    // Out of range clamps.
    try testing.expectEqual(@as(u16, 0), subRow(9.0, 8));
    try testing.expectEqual(@as(u16, 7), subRow(-9.0, 8));
}

test "rowForLevel puts silence at the bottom and full scale at the top" {
    try testing.expectEqual(@as(u16, 3), rowForLevel(0, 4));
    try testing.expectEqual(@as(u16, 0), rowForLevel(1, 4));
    // Out of range clamps rather than drawing outside the box.
    try testing.expectEqual(@as(u16, 3), rowForLevel(-5, 4));
    try testing.expectEqual(@as(u16, 0), rowForLevel(5, 4));
}

/// A sine at `hz`, one analyzer window long.
fn tone(buf: []f32, hz: f32, rate: u32, amplitude: f32) void {
    for (buf, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        v.* = amplitude * @sin(2.0 * std.math.pi * hz * t);
    }
}

test "a tone lights the bar covering its frequency" {
    const rate = 48000;
    const bars = 20;
    var samples: [window]f32 = undefined;

    var a = try testing.allocator.create(Analyzer);
    defer testing.allocator.destroy(a);
    a.* = .{};

    tone(&samples, 3000, rate, 1.0);
    // Several frames, because attack is immediate but we want a settled view.
    for (0..5) |_| a.update(&samples, rate, bars);

    // Find the band containing 3kHz and check it is the loudest.
    var expected: usize = 0;
    for (0..bars) |i| {
        if (bandEdge(freq_lo, freq_hi, i, bars) <= 3000 and
            bandEdge(freq_lo, freq_hi, i + 1, bars) > 3000) expected = i;
    }

    var loudest: usize = 0;
    for (0..bars) |i| if (a.bars[i] > a.bars[loudest]) {
        loudest = i;
    };
    try testing.expectEqual(expected, loudest);
    try testing.expect(a.bars[expected] > 0.5);
}

test "bars decay toward silence and peaks lag behind them" {
    const rate = 48000;
    var samples: [window]f32 = undefined;

    var a = try testing.allocator.create(Analyzer);
    defer testing.allocator.destroy(a);
    a.* = .{};

    tone(&samples, 1000, rate, 1.0);
    a.update(&samples, rate, 16);
    const loud = a.bars;

    // Silence from here on.
    const quiet: [window]f32 = @splat(0);
    a.update(&quiet, rate, 16);
    for (0..16) |i| try testing.expect(a.bars[i] <= loud[i]);

    // The cap stays above the bar while it hangs.
    var hung = false;
    for (0..16) |i| {
        if (a.peaks[i] > a.bars[i] + 0.001) hung = true;
    }
    try testing.expect(hung);

    // Everything eventually settles at rest.
    for (0..400) |_| a.update(&quiet, rate, 16);
    for (0..16) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0), a.bars[i], 0.001);
        try testing.expectApproxEqAbs(@as(f32, 0), a.peaks[i], 0.001);
    }
}

test "no audio available still decays rather than freezing" {
    var a = try testing.allocator.create(Analyzer);
    defer testing.allocator.destroy(a);
    a.* = .{};
    a.bars[0] = 1.0;
    a.peaks[0] = 1.0;

    a.update(&.{}, 48000, 16);
    try testing.expect(a.bars[0] < 1.0);
    try testing.expect(a.silent);
}

test "degenerate inputs do not panic" {
    var a = try testing.allocator.create(Analyzer);
    defer testing.allocator.destroy(a);
    a.* = .{};
    const samples: [window]f32 = @splat(0.5);

    a.update(&samples, 0, 16); // no sample rate
    a.update(&samples, 48000, 0); // no columns
    a.update(&samples, 48000, max_bars * 4); // more columns than we hold
    try testing.expect(a.bar_count <= max_bars);

    var s = try screen.Screen.init(testing.allocator, 4, 2);
    defer s.deinit();
    s.clear(.plain);
    a.draw(s.painter(.{ .x = 0, .y = 0, .w = 0, .h = 0 }), .classic);
    a.draw(s.painter(s.bounds()), .classic);
}

test "spectrum draws bars from the bottom up, with a cap above" {
    const gpa = testing.allocator;
    var a = try gpa.create(Analyzer);
    defer gpa.destroy(a);
    a.* = .{};

    a.bar_count = 3;
    a.bars = @splat(0);
    a.peaks = @splat(0);
    a.bars[0] = 1.0; // full height
    a.bars[1] = 0.5; // half
    a.bars[2] = 0.0; // silent
    a.peaks[2] = 0.9; // a cap left hanging over silence

    var s = try screen.Screen.init(gpa, 3, 4);
    defer s.deinit();
    s.clear(.plain);
    a.draw(s.painter(s.bounds()), .classic);

    const th = Theme.classic;
    // Column 0 is full in every row.
    for (0..4) |y| try testing.expectEqual(th.glyphs.bars[8], s.get(0, @intCast(y)).?.cp);
    // Column 1 fills the bottom half only.
    try testing.expectEqual(@as(u21, ' '), s.get(1, 0).?.cp);
    try testing.expectEqual(th.glyphs.bars[8], s.get(1, 3).?.cp);
    // Column 2 has no bar but does have its cap.
    try testing.expectEqual(@as(u21, ' '), s.get(2, 3).?.cp);
    try testing.expectEqual(th.glyphs.peak, s.get(2, 0).?.cp);
}

test "oscilloscope centres silence and never leaves the box" {
    const gpa = testing.allocator;
    var a = try gpa.create(Analyzer);
    defer gpa.destroy(a);
    a.* = .{ .mode = .oscilloscope };

    const rate = 48000;
    var samples: [window]f32 = undefined;

    // Silence sits on the centre row.
    @memset(&samples, 0);
    a.update(&samples, rate, 8);
    var s = try screen.Screen.init(gpa, 8, 5);
    defer s.deinit();
    s.clear(.plain);
    a.draw(s.painter(s.bounds()), .classic);
    // 5 rows is 10 sub-rows; the midpoint rounds to sub-row 5, which is the
    // lower half of cell row 2.
    try testing.expectEqual(Theme.classic.glyphs.scope_lo, s.get(0, 2).?.cp);

    // A loud tone stays inside the box on every column.
    tone(&samples, 400, rate, 1.0);
    a.update(&samples, rate, 8);
    s.clear(.plain);
    a.draw(s.painter(s.bounds()), .classic);
    const g = Theme.classic.glyphs;
    for (0..8) |x| {
        var drawn = false;
        for (0..5) |y| {
            const cp = s.get(@intCast(x), @intCast(y)).?.cp;
            if (cp == g.scope or cp == g.scope_hi or cp == g.scope_lo) drawn = true;
        }
        try testing.expect(drawn);
    }

    // Clipping input beyond full scale must not escape either.
    @memset(&samples, 9.0);
    a.update(&samples, rate, 8);
    s.clear(.plain);
    a.draw(s.painter(s.bounds()), .classic);
}

test "off mode draws an empty box" {
    const gpa = testing.allocator;
    var a = try gpa.create(Analyzer);
    defer gpa.destroy(a);
    a.* = .{ .mode = .off };
    a.bar_count = 4;
    a.bars = @splat(1.0);

    var s = try screen.Screen.init(gpa, 4, 3);
    defer s.deinit();
    s.clear(.plain);
    a.draw(s.painter(s.bounds()), .classic);
    for (0..4) |x| for (0..3) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(@intCast(x), @intCast(y)).?.cp);
    };
}
