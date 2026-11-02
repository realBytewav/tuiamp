//! A WAV fixture generator for the audio tests.
//!
//! The no-device engine is the only place the output path can be checked —
//! the visualizer taps upstream of the master volume, so it cannot tell
//! silence from sound — and checking it needs a file to decode. A full-scale
//! sine is the useful shape: its level is known exactly, so a drop anywhere
//! in the captured output is a defect rather than a property of the material.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tone = struct {
    /// Length in frames, at `rate`.
    frames: u32,
    rate: u32 = 48000,
    hz: f32 = 440,
    /// Out of 32767. Full scale by default, so the RMS a test asserts on is
    /// nowhere near the noise floor of a decoder.
    amplitude: i16 = 30000,
};

/// Write a stereo 16-bit WAV of `t` into `dir`.
pub fn writeWav(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    t: Tone,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const data_len: u32 = t.frames * 2 * 2; // stereo, 16-bit
    var u32buf: [4]u8 = undefined;
    var u16buf: [2]u8 = undefined;

    try out.appendSlice(gpa, "RIFF");
    std.mem.writeInt(u32, &u32buf, 36 + data_len, .little);
    try out.appendSlice(gpa, &u32buf);
    try out.appendSlice(gpa, "WAVEfmt ");
    std.mem.writeInt(u32, &u32buf, 16, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, 1, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, 2, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u32, &u32buf, t.rate, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u32, &u32buf, t.rate * 4, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, 4, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, 16, .little);
    try out.appendSlice(gpa, &u16buf);
    try out.appendSlice(gpa, "data");
    std.mem.writeInt(u32, &u32buf, data_len, .little);
    try out.appendSlice(gpa, &u32buf);

    const amp: f32 = @floatFromInt(t.amplitude);
    for (0..t.frames) |i| {
        const secs = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(t.rate));
        const v: i16 = @intFromFloat(@sin(2.0 * std.math.pi * t.hz * secs) * amp);
        std.mem.writeInt(i16, &u16buf, v, .little);
        try out.appendSlice(gpa, &u16buf);
        try out.appendSlice(gpa, &u16buf);
    }

    try dir.writeFile(io, .{ .sub_path = name, .data = out.items });
}

/// Root-mean-square of interleaved or planar samples; the measure every
/// capture assertion is written in.
pub fn rms(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var sum: f64 = 0;
    for (samples) |v| sum += @as(f64, v) * @as(f64, v);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(samples.len))));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a written tone is a RIFF file of the length asked for" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeWav(testing.allocator, testing.io, tmp.dir, "t.wav", .{ .frames = 100, .rate = 8000 });

    const bytes = try tmp.dir.readFileAlloc(testing.io, "t.wav", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    // 44-byte header, then stereo 16-bit frames.
    try testing.expectEqual(@as(usize, 44 + 100 * 4), bytes.len);
}

test "rms of silence is zero and of full scale is not" {
    try testing.expectEqual(@as(f32, 0), rms(&.{}));
    try testing.expectEqual(@as(f32, 0), rms(&[_]f32{ 0, 0, 0 }));
    try testing.expect(rms(&[_]f32{ 1, -1, 1, -1 }) > 0.9);
}
