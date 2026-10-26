//! Enough RIFF/WAVE parsing to report a WAV file's format and length.
//!
//! WAV carries no tags worth reading in the common case, so this only looks
//! for `fmt ` and the size of `data`.

const std = @import("std");

pub const Info = struct {
    sample_rate: u32 = 0,
    channels: u32 = 0,
    bits_per_sample: u32 = 0,
    byte_rate: u32 = 0,
    data_bytes: u64 = 0,

    pub fn duration(i: Info) f32 {
        if (i.byte_rate == 0 or i.data_bytes == 0) return -1;
        return @as(f32, @floatFromInt(i.data_bytes)) / @as(f32, @floatFromInt(i.byte_rate));
    }

    pub fn bitrateKbps(i: Info) u32 {
        return i.byte_rate * 8 / 1000;
    }
};

pub fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// `bytes` may be only a prefix of the file; `file_size` lets a `data` chunk
/// whose declared size runs past the prefix still yield a duration.
pub fn parse(bytes: []const u8, file_size: u64) Info {
    var info: Info = .{};
    if (!isWav(bytes)) return info;

    var i: usize = 12;
    while (i + 8 <= bytes.len) {
        const id = bytes[i..][0..4];
        const size = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        const body = i + 8;

        if (std.mem.eql(u8, id, "fmt ") and body + 16 <= bytes.len) {
            info.channels = std.mem.readInt(u16, bytes[body + 2 ..][0..2], .little);
            info.sample_rate = std.mem.readInt(u32, bytes[body + 4 ..][0..4], .little);
            info.byte_rate = std.mem.readInt(u32, bytes[body + 8 ..][0..4], .little);
            info.bits_per_sample = std.mem.readInt(u16, bytes[body + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            // A streamed WAV may declare 0 or 0xFFFFFFFF; fall back to what
            // is actually left in the file.
            const declared: u64 = size;
            const remaining = if (file_size > body) file_size - body else 0;
            info.data_bytes = if (declared == 0 or declared == 0xffff_ffff or declared > remaining)
                remaining
            else
                declared;
            break;
        }

        // Chunks are padded to an even length.
        const advance = @as(usize, size) + (size & 1);
        if (advance == 0) break;
        i = body + advance;
    }
    return info;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildWav(gpa: std.mem.Allocator, rate: u32, channels: u16, bits: u16, data_len: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const byte_rate = rate * channels * bits / 8;

    try out.appendSlice(gpa, "RIFF");
    try out.appendNTimes(gpa, 0, 4);
    try out.appendSlice(gpa, "WAVE");

    try out.appendSlice(gpa, "fmt ");
    var u32buf: [4]u8 = undefined;
    var u16buf: [2]u8 = undefined;
    std.mem.writeInt(u32, &u32buf, 16, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, 1, .little); // PCM
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, channels, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u32, &u32buf, rate, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u32, &u32buf, byte_rate, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, @intCast(channels * bits / 8), .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, bits, .little);
    try out.appendSlice(gpa, &u16buf);

    try out.appendSlice(gpa, "data");
    std.mem.writeInt(u32, &u32buf, data_len, .little);
    try out.appendSlice(gpa, &u32buf);
    return out.toOwnedSlice(gpa);
}

test "fmt and data give format and duration" {
    const gpa = testing.allocator;
    // 2 seconds of 44100Hz stereo 16-bit.
    const data_len = 44100 * 2 * 2 * 2;
    const w = try buildWav(gpa, 44100, 2, 16, data_len);
    defer gpa.free(w);

    const info = parse(w, w.len + data_len);
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits_per_sample);
    try testing.expectApproxEqAbs(@as(f32, 2), info.duration(), 0.001);
    try testing.expectEqual(@as(u32, 1411), info.bitrateKbps());
}

test "chunks before fmt are skipped, including odd-length ones" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.appendSlice(gpa, "RIFF\x00\x00\x00\x00WAVE");
    // A 3-byte LIST chunk, padded to 4.
    try out.appendSlice(gpa, "LIST");
    try out.appendSlice(gpa, &[_]u8{ 3, 0, 0, 0 });
    try out.appendSlice(gpa, &[_]u8{ 1, 2, 3, 0 });

    const rest = try buildWav(gpa, 48000, 1, 16, 96000);
    defer gpa.free(rest);
    try out.appendSlice(gpa, rest[12..]);

    const info = parse(out.items, out.items.len + 96000);
    try testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectApproxEqAbs(@as(f32, 1), info.duration(), 0.001);
}

test "a streamed data size falls back to what the file actually holds" {
    const gpa = testing.allocator;
    const w = try buildWav(gpa, 44100, 2, 16, 0xffff_ffff);
    defer gpa.free(w);
    const info = parse(w, w.len + 176400);
    try testing.expectApproxEqAbs(@as(f32, 1), info.duration(), 0.001);
}

test "non-WAV input is rejected" {
    try testing.expect(!isWav("fLaC"));
    try testing.expect(!isWav("RIFF1234AVI "));
    try testing.expect(!isWav(""));
    const info = parse("not a wav at all", 16);
    try testing.expectEqual(@as(f32, -1), info.duration());
}

test "a truncated header does not read past the end" {
    const gpa = testing.allocator;
    const w = try buildWav(gpa, 44100, 2, 16, 1000);
    defer gpa.free(w);
    for (0..w.len) |n| {
        const info = parse(w[0..n], w.len);
        _ = info.duration();
    }
}
