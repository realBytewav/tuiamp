//! A lock-free window onto the audio that is currently playing.
//!
//! The audio callback must never block, so it cannot take a lock the UI
//! thread might hold. Instead it writes mono-summed samples into a circular
//! buffer and publishes a monotonically increasing count; the UI thread reads
//! the newest window out of that buffer.
//!
//! The reader can in principle be lapped by the writer mid-copy. Rather than
//! pretend that cannot happen, `readLatest` detects it and says so, and the
//! buffer is sized far larger than the window the analyzer asks for, so in
//! practice it does not. A dropped frame of a spectrum display is invisible;
//! a stuttering audio thread is not.
//!
//! Element accesses are atomic with `.unordered`, which costs nothing in
//! codegen but keeps the concurrent access well-defined rather than a race.

const std = @import("std");

/// `capacity` must be a power of two and comfortably larger than the biggest
/// window a reader will request.
pub fn Tap(comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0 and std.math.isPowerOfTwo(capacity));

    return struct {
        const Self = @This();
        pub const size = capacity;
        const mask = capacity - 1;

        buf: [capacity]f32 = @splat(0),
        /// Total samples ever written. Written only by the audio thread.
        written: std.atomic.Value(u64) = .init(0),

        /// Audio thread. Push already-mono samples.
        pub fn push(t: *Self, samples: []const f32) void {
            var w = t.written.load(.monotonic);
            for (samples) |s| {
                @atomicStore(f32, &t.buf[@intCast(w & mask)], s, .unordered);
                w += 1;
            }
            // Release: everything stored above is visible before the count.
            t.written.store(w, .release);
        }

        /// Audio thread. Push interleaved frames, averaging the channels.
        /// Winamp's analyzer is mono and so is this.
        pub fn pushInterleaved(t: *Self, frames: []const f32, channels: u32) void {
            if (channels == 0) return;
            if (channels == 1) return t.push(frames);

            const ch: usize = channels;
            const frame_count = frames.len / ch;
            const inv: f32 = 1.0 / @as(f32, @floatFromInt(ch));

            var w = t.written.load(.monotonic);
            for (0..frame_count) |i| {
                var sum: f32 = 0;
                for (0..ch) |c| sum += frames[i * ch + c];
                @atomicStore(f32, &t.buf[@intCast(w & mask)], sum * inv, .unordered);
                w += 1;
            }
            t.written.store(w, .release);
        }

        /// UI thread. Fill `out` with the newest samples, oldest first.
        ///
        /// Returns false when there is not enough audio yet, or when the
        /// writer lapped the region being copied, in which case `out` holds
        /// torn data the caller should discard.
        pub fn readLatest(t: *const Self, out: []f32) bool {
            if (out.len == 0) return true;
            if (out.len > capacity) return false;

            const end = t.written.load(.acquire);
            if (end < out.len) return false;

            const start = end - out.len;
            for (out, 0..) |*v, i| {
                v.* = @atomicLoad(f32, &t.buf[@intCast((start + i) & mask)], .unordered);
            }

            // If the writer has advanced far enough to have overwritten the
            // oldest sample we just read, the window is torn.
            const now = t.written.load(.acquire);
            return now - start <= capacity;
        }

        /// Total samples written so far. Useful for noticing that playback
        /// has stopped producing audio.
        pub fn count(t: *const Self) u64 {
            return t.written.load(.acquire);
        }

        pub fn reset(t: *Self) void {
            @memset(&t.buf, 0);
            t.written.store(0, .release);
        }
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "reads back the newest window" {
    var tap: Tap(64) = .{};
    var in: [16]f32 = undefined;
    for (&in, 0..) |*v, i| v.* = @floatFromInt(i);
    tap.push(&in);

    var out: [8]f32 = undefined;
    try testing.expect(tap.readLatest(&out));
    // The newest 8 of the 16 written, oldest first.
    for (out, 0..) |v, i| try testing.expectEqual(@as(f32, @floatFromInt(i + 8)), v);
}

test "not enough audio yet" {
    var tap: Tap(64) = .{};
    var out: [8]f32 = undefined;
    try testing.expect(!tap.readLatest(&out));

    tap.push(&[_]f32{ 1, 2, 3 });
    try testing.expect(!tap.readLatest(&out));

    tap.push(&[_]f32{ 4, 5, 6, 7, 8 });
    try testing.expect(tap.readLatest(&out));
    try testing.expectEqual(@as(f32, 1), out[0]);
    try testing.expectEqual(@as(f32, 8), out[7]);
}

test "a window larger than the buffer is refused rather than wrapping" {
    var tap: Tap(16) = .{};
    const in: [16]f32 = @splat(1);
    tap.push(&in);
    var out: [32]f32 = undefined;
    try testing.expect(!tap.readLatest(&out));
}

test "writing past the end wraps correctly" {
    var tap: Tap(8) = .{};
    // Three full laps plus a bit.
    for (0..26) |i| tap.push(&[_]f32{@floatFromInt(i)});

    var out: [4]f32 = undefined;
    try testing.expect(tap.readLatest(&out));
    try testing.expectEqual(@as(f32, 22), out[0]);
    try testing.expectEqual(@as(f32, 25), out[3]);
    try testing.expectEqual(@as(u64, 26), tap.count());
}

test "interleaved stereo is averaged to mono" {
    var tap: Tap(16) = .{};
    // Left 1.0, right 0.0 -> 0.5 mono.
    tap.pushInterleaved(&[_]f32{ 1, 0, 1, 0, 1, 0 }, 2);

    var out: [3]f32 = undefined;
    try testing.expect(tap.readLatest(&out));
    for (out) |v| try testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-6);
    try testing.expectEqual(@as(u64, 3), tap.count());
}

test "mono and multichannel interleave" {
    var tap: Tap(16) = .{};
    tap.pushInterleaved(&[_]f32{ 0.25, 0.75 }, 1);
    var out: [2]f32 = undefined;
    try testing.expect(tap.readLatest(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6);

    tap.reset();
    // 4 channels: 1 + 2 + 3 + 4 = 10, / 4 = 2.5
    tap.pushInterleaved(&[_]f32{ 1, 2, 3, 4 }, 4);
    var one: [1]f32 = undefined;
    try testing.expect(tap.readLatest(&one));
    try testing.expectApproxEqAbs(@as(f32, 2.5), one[0], 1e-6);

    // Zero channels must not divide by zero or write anything.
    tap.pushInterleaved(&[_]f32{ 1, 2 }, 0);
    try testing.expectEqual(@as(u64, 1), tap.count());
}

test "reset clears the window" {
    var tap: Tap(16) = .{};
    const in: [16]f32 = @splat(3);
    tap.push(&in);
    tap.reset();
    try testing.expectEqual(@as(u64, 0), tap.count());
    var out: [4]f32 = undefined;
    try testing.expect(!tap.readLatest(&out));
}

test "a successful read is never torn, even against an adversarial writer" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Shared = struct {
        tap: Tap(8192) = .{},
        stop: std.atomic.Value(bool) = .init(false),
        /// Microseconds to idle between blocks. Zero means flat out, which
        /// is far faster than any sound card and laps the buffer constantly.
        pace_us: u64,
        io: std.Io,

        /// Stand-in for the audio callback: a ramp whose values are a known
        /// function of their position, so a reader can check what it got.
        fn produce(s: *@This()) void {
            var n: u64 = 0;
            var block: [256]f32 = undefined;
            while (!s.stop.load(.monotonic)) {
                for (&block) |*v| {
                    v.* = @floatFromInt(n % 1000);
                    n += 1;
                }
                s.tap.push(&block);
                if (s.pace_us > 0) {
                    s.io.sleep(.fromMicroseconds(@intCast(s.pace_us)), .awake) catch return;
                }
            }
        }
    };

    var shared = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(shared);
    shared.* = .{ .pace_us = 0, .io = testing.io };

    const writer = try std.Thread.spawn(.{}, Shared.produce, .{shared});
    defer {
        shared.stop.store(true, .monotonic);
        writer.join();
    }

    // The writer laps the buffer constantly, so most reads are expected to
    // be refused. What must never happen is a read reporting success while
    // handing back a window the writer has partly overwritten.
    var window: [1024]f32 = undefined;
    var torn_but_reported_ok: usize = 0;
    for (0..2000) |_| {
        if (!shared.tap.readLatest(&window)) continue;
        for (window, 0..) |v, i| {
            if (i > 0 and v != @mod(window[i - 1] + 1, 1000)) {
                torn_but_reported_ok += 1;
                break;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), torn_but_reported_ok);
}

test "a realistically paced writer yields usable windows" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Shared = struct {
        tap: Tap(8192) = .{},
        stop: std.atomic.Value(bool) = .init(false),
        io: std.Io,

        fn produce(s: *@This()) void {
            var n: u64 = 0;
            var block: [256]f32 = undefined;
            while (!s.stop.load(.monotonic)) {
                for (&block) |*v| {
                    v.* = @floatFromInt(n % 1000);
                    n += 1;
                }
                s.tap.push(&block);
                // 256 frames at roughly 48kHz is about 5ms of audio.
                s.io.sleep(.fromMilliseconds(2), .awake) catch return;
            }
        }
    };

    var shared = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(shared);
    shared.* = .{ .io = testing.io };

    const writer = try std.Thread.spawn(.{}, Shared.produce, .{shared});
    defer {
        shared.stop.store(true, .monotonic);
        writer.join();
    }

    var window: [1024]f32 = undefined;
    var ok: usize = 0;
    var bad: usize = 0;
    for (0..200) |_| {
        if (!shared.tap.readLatest(&window)) {
            try testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }
        for (window, 0..) |v, i| {
            if (i > 0 and v != @mod(window[i - 1] + 1, 1000)) {
                bad += 1;
                break;
            }
        } else ok += 1;
    }

    // At a real audio rate the reader keeps up comfortably.
    try testing.expect(ok > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}
