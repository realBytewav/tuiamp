//! A radix-2 FFT, sized at comptime.
//!
//! Only ever used to drive a spectrum analyzer, so it is deliberately plain:
//! an iterative in-place Cooley-Tukey over separate real and imaginary
//! arrays, which avoids needing a complex type and keeps both halves
//! contiguous.

const std = @import("std");

/// `size` must be a power of two.
pub fn Fft(comptime size: usize) type {
    comptime std.debug.assert(size > 0 and std.math.isPowerOfTwo(size));

    return struct {
        const Self = @This();
        pub const n = size;
        const levels = std.math.log2_int(usize, size);

        re: [size]f32 = @splat(0),
        im: [size]f32 = @splat(0),

        /// Hann window, precomputed because it never changes and the
        /// analyzer runs every frame.
        const hann: [size]f32 = blk: {
            @setEvalBranchQuota(size * 32);
            var w: [size]f32 = undefined;
            for (&w, 0..) |*v, i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(size - 1));
                v.* = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t);
            }
            break :blk w;
        };

        /// Load `samples` (shorter input is zero-padded) and apply the window.
        pub fn loadWindowed(f: *Self, samples: []const f32) void {
            const count = @min(samples.len, size);
            for (0..count) |i| f.re[i] = samples[i] * hann[i];
            @memset(f.re[count..], 0);
            @memset(&f.im, 0);
        }

        pub fn run(f: *Self) void {
            bitReverse(&f.re, &f.im);

            var span: usize = 2;
            while (span <= size) : (span *= 2) {
                const half = span / 2;
                const step = -2.0 * std.math.pi / @as(f32, @floatFromInt(span));
                var start: usize = 0;
                while (start < size) : (start += span) {
                    for (0..half) |k| {
                        const angle = step * @as(f32, @floatFromInt(k));
                        const wr = @cos(angle);
                        const wi = @sin(angle);

                        const a = start + k;
                        const b = a + half;
                        const tr = f.re[b] * wr - f.im[b] * wi;
                        const ti = f.re[b] * wi + f.im[b] * wr;

                        f.re[b] = f.re[a] - tr;
                        f.im[b] = f.im[a] - ti;
                        f.re[a] += tr;
                        f.im[a] += ti;
                    }
                }
            }
        }

        /// Magnitude of bin `k`. Only the first `size / 2` bins are
        /// meaningful for real input; the rest mirror them.
        pub fn magnitude(f: *const Self, k: usize) f32 {
            return @sqrt(f.re[k] * f.re[k] + f.im[k] * f.im[k]);
        }

        /// Centre frequency of bin `k` at a given sample rate.
        pub fn binFrequency(k: usize, sample_rate: u32) f32 {
            return @as(f32, @floatFromInt(k)) * @as(f32, @floatFromInt(sample_rate)) /
                @as(f32, @floatFromInt(size));
        }

        fn bitReverse(re: *[size]f32, im: *[size]f32) void {
            if (size < 2) return;
            var i: usize = 1;
            var j: usize = 0;
            while (i < size) : (i += 1) {
                var bit = size >> 1;
                while (j & bit != 0) : (bit >>= 1) j ^= bit;
                j |= bit;
                if (i < j) {
                    std.mem.swap(f32, &re[i], &re[j]);
                    std.mem.swap(f32, &im[i], &im[j]);
                }
            }
        }

        comptime {
            std.debug.assert(levels > 0 or size == 1);
        }
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn fillSine(buf: []f32, cycles: f32, amplitude: f32) void {
    for (buf, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(buf.len));
        v.* = amplitude * @sin(2.0 * std.math.pi * cycles * t);
    }
}

/// Index of the largest magnitude in the usable half of the spectrum.
fn peakBin(f: anytype) usize {
    const half = @TypeOf(f.*).n / 2;
    var best: usize = 1;
    var best_mag: f32 = 0;
    for (1..half) |k| {
        const m = f.magnitude(k);
        if (m > best_mag) {
            best_mag = m;
            best = k;
        }
    }
    return best;
}

test "a pure sine peaks in its own bin" {
    const N = 256;
    var f: Fft(N) = .{};

    // A whole number of cycles over the window lands exactly on a bin.
    for ([_]usize{ 1, 4, 16, 64 }) |cycles| {
        var samples: [N]f32 = undefined;
        fillSine(&samples, @floatFromInt(cycles), 1.0);
        f.loadWindowed(&samples);
        f.run();
        try testing.expectEqual(cycles, peakBin(&f));
    }
}

test "silence produces no energy" {
    var f: Fft(64) = .{};
    const samples: [64]f32 = @splat(0);
    f.loadWindowed(&samples);
    f.run();
    for (0..32) |k| try testing.expectApproxEqAbs(@as(f32, 0), f.magnitude(k), 1e-6);
}

test "DC lands in bin zero and nowhere else" {
    const N = 128;
    var f: Fft(N) = .{};
    const samples: [N]f32 = @splat(1.0);
    f.loadWindowed(&samples);
    f.run();
    try testing.expect(f.magnitude(0) > 1.0);
    // The window has sidelobes, but nothing far from DC should ring.
    for (8..N / 2) |k| try testing.expect(f.magnitude(k) < 0.01 * f.magnitude(0));
}

test "magnitude scales with amplitude" {
    const N = 256;
    var quiet: Fft(N) = .{};
    var loud: Fft(N) = .{};
    var samples: [N]f32 = undefined;

    fillSine(&samples, 8, 0.25);
    quiet.loadWindowed(&samples);
    quiet.run();

    fillSine(&samples, 8, 1.0);
    loud.loadWindowed(&samples);
    loud.run();

    const ratio = loud.magnitude(8) / quiet.magnitude(8);
    try testing.expectApproxEqAbs(@as(f32, 4.0), ratio, 0.05);
}

test "two tones resolve as two peaks" {
    const N = 512;
    var f: Fft(N) = .{};
    var samples: [N]f32 = undefined;
    for (&samples, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        v.* = @sin(2.0 * std.math.pi * 10.0 * t) + 0.5 * @sin(2.0 * std.math.pi * 80.0 * t);
    }
    f.loadWindowed(&samples);
    f.run();

    try testing.expect(f.magnitude(10) > f.magnitude(45));
    try testing.expect(f.magnitude(80) > f.magnitude(45));
    // The louder tone is the taller peak.
    try testing.expect(f.magnitude(10) > f.magnitude(80));
}

test "short input is zero-padded rather than reading past the end" {
    var f: Fft(64) = .{};
    const samples = [_]f32{ 1, 2, 3 };
    f.loadWindowed(&samples);
    f.run();
    try testing.expect(f.magnitude(0) > 0);
    for (3..64) |i| try testing.expectEqual(@as(f32, 0), f.re[i] * 0); // no NaNs
    try testing.expect(!std.math.isNan(f.magnitude(5)));
}

test "oversized input is truncated to the window" {
    var f: Fft(32) = .{};
    const samples: [1000]f32 = @splat(0.5);
    f.loadWindowed(&samples);
    f.run();
    try testing.expect(!std.math.isNan(f.magnitude(0)));
}

test "binFrequency maps bins to hertz" {
    const F = Fft(1024);
    try testing.expectApproxEqAbs(@as(f32, 0), F.binFrequency(0, 44100), 0.01);
    // Bin 1 is one sample-rate/size step.
    try testing.expectApproxEqAbs(@as(f32, 43.066), F.binFrequency(1, 44100), 0.01);
    // Nyquist sits at the halfway bin.
    try testing.expectApproxEqAbs(@as(f32, 22050), F.binFrequency(512, 44100), 0.1);
}
