//! MPEG audio frame headers, and the VBR headers that make an accurate
//! duration possible without decoding the file.
//!
//! For a constant-bitrate file the duration is just file size over bitrate.
//! For a variable-bitrate file that estimate can be wildly wrong, which is
//! why encoders write a Xing, Info or VBRI header into the first frame
//! carrying the real frame count. Reading it costs one small read; decoding
//! the whole file to count frames would cost seconds per track.

const std = @import("std");

pub const Version = enum { mpeg1, mpeg2, mpeg25 };
pub const Layer = enum { layer1, layer2, layer3 };

pub const FrameHeader = struct {
    version: Version,
    layer: Layer,
    bitrate_kbps: u32,
    sample_rate: u32,
    channels: u32,
    padding: bool,

    /// PCM frames produced per MPEG frame.
    pub fn samplesPerFrame(h: FrameHeader) u32 {
        return switch (h.layer) {
            .layer1 => 384,
            .layer2 => 1152,
            .layer3 => switch (h.version) {
                .mpeg1 => 1152,
                .mpeg2, .mpeg25 => 576,
            },
        };
    }

    /// Size of this frame on disk, in bytes.
    pub fn frameBytes(h: FrameHeader) u32 {
        if (h.bitrate_kbps == 0 or h.sample_rate == 0) return 0;
        const bits = h.bitrate_kbps * 1000;
        const pad: u32 = if (h.padding) 1 else 0;
        return switch (h.layer) {
            .layer1 => (12 * bits / h.sample_rate + pad) * 4,
            else => h.samplesPerFrame() / 8 * bits / h.sample_rate + pad,
        };
    }

    /// Parse a 4-byte header. Returns null unless every field is plausible,
    /// which is what keeps a random 0xFF in the audio from being mistaken
    /// for the start of a frame.
    pub fn parse(b: *const [4]u8) ?FrameHeader {
        if (b[0] != 0xff or (b[1] & 0xe0) != 0xe0) return null;

        const version: Version = switch ((b[1] >> 3) & 0x03) {
            0 => .mpeg25,
            1 => return null, // reserved
            2 => .mpeg2,
            else => .mpeg1,
        };
        const layer: Layer = switch ((b[1] >> 1) & 0x03) {
            0 => return null, // reserved
            1 => .layer3,
            2 => .layer2,
            else => .layer1,
        };

        const bitrate_index = (b[2] >> 4) & 0x0f;
        if (bitrate_index == 0 or bitrate_index == 0x0f) return null; // free/bad
        const rate_index = (b[2] >> 2) & 0x03;
        if (rate_index == 3) return null; // reserved

        const mode = (b[3] >> 6) & 0x03;

        return .{
            .version = version,
            .layer = layer,
            .bitrate_kbps = bitrateTable(version, layer)[bitrate_index],
            .sample_rate = sampleRateTable(version)[rate_index],
            .channels = if (mode == 3) 1 else 2,
            .padding = (b[2] >> 1) & 1 == 1,
        };
    }
};

pub const Info = struct {
    duration: f32 = -1,
    bitrate_kbps: u32 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    /// True when the duration came from a VBR header rather than from
    /// dividing the file size by a bitrate.
    exact: bool = false,
};

/// Work out duration and bitrate from the first frame.
///
/// `head` is a prefix of the file starting at the first audio byte (after
/// any ID3v2 tag); `audio_bytes` is how many bytes of audio the file holds
/// in total, which is needed for the constant-bitrate estimate.
pub fn probe(head: []const u8, audio_bytes: u64) Info {
    const offset = findSync(head) orelse return .{};
    const h = FrameHeader.parse(head[offset..][0..4]).?;

    var info: Info = .{
        .bitrate_kbps = h.bitrate_kbps,
        .sample_rate = h.sample_rate,
        .channels = h.channels,
    };
    if (h.sample_rate == 0) return info;

    const spf: f32 = @floatFromInt(h.samplesPerFrame());
    const rate: f32 = @floatFromInt(h.sample_rate);

    if (vbrFrameCount(head[offset..], h)) |vbr| {
        info.duration = @as(f32, @floatFromInt(vbr.frames)) * spf / rate;
        info.exact = true;
        if (vbr.bytes > 0 and info.duration > 0) {
            const bits = @as(f64, @floatFromInt(vbr.bytes)) * 8;
            info.bitrate_kbps = @intFromFloat(@round(bits / @as(f64, info.duration) / 1000));
        }
        return info;
    }

    // Constant bitrate: size over rate.
    if (h.bitrate_kbps > 0 and audio_bytes > 0) {
        const bits = @as(f64, @floatFromInt(audio_bytes)) * 8;
        info.duration = @floatCast(bits / (@as(f64, @floatFromInt(h.bitrate_kbps)) * 1000));
    }
    return info;
}

const Vbr = struct { frames: u64, bytes: u64 };

/// Xing and Info live at a version- and channel-dependent offset inside the
/// first frame; VBRI always sits 32 bytes in.
fn vbrFrameCount(frame: []const u8, h: FrameHeader) ?Vbr {
    const xing_offset: usize = 4 + switch (h.version) {
        .mpeg1 => @as(usize, if (h.channels == 1) 17 else 32),
        .mpeg2, .mpeg25 => @as(usize, if (h.channels == 1) 9 else 17),
    };

    if (frame.len >= xing_offset + 8) {
        const tag = frame[xing_offset..][0..4];
        if (std.mem.eql(u8, tag, "Xing") or std.mem.eql(u8, tag, "Info")) {
            const flags = std.mem.readInt(u32, frame[xing_offset + 4 ..][0..4], .big);
            var at = xing_offset + 8;
            var frames: u64 = 0;
            var bytes: u64 = 0;
            if (flags & 0x1 != 0) {
                if (at + 4 > frame.len) return null;
                frames = std.mem.readInt(u32, frame[at..][0..4], .big);
                at += 4;
            }
            if (flags & 0x2 != 0) {
                if (at + 4 > frame.len) return null;
                bytes = std.mem.readInt(u32, frame[at..][0..4], .big);
                at += 4;
            }
            if (frames == 0) return null;
            return .{ .frames = frames, .bytes = bytes };
        }
    }

    const vbri_offset: usize = 4 + 32;
    if (frame.len >= vbri_offset + 26 and std.mem.eql(u8, frame[vbri_offset..][0..4], "VBRI")) {
        const bytes = std.mem.readInt(u32, frame[vbri_offset + 10 ..][0..4], .big);
        const frames = std.mem.readInt(u32, frame[vbri_offset + 14 ..][0..4], .big);
        if (frames == 0) return null;
        return .{ .frames = frames, .bytes = bytes };
    }
    return null;
}

/// Offset of the first plausible frame header.
///
/// A single valid-looking header is not enough — 0xFF bytes turn up inside
/// audio data and inside tags we failed to skip — so a candidate is only
/// accepted if the frame it describes is followed by another valid header.
pub fn findSync(bytes: []const u8) ?usize {
    if (bytes.len < 4) return null;
    var i: usize = 0;
    const limit = bytes.len - 4;
    while (i <= limit) : (i += 1) {
        if (bytes[i] != 0xff) continue;
        const h = FrameHeader.parse(bytes[i..][0..4]) orelse continue;

        const len = h.frameBytes();
        if (len == 0) continue;

        const next = i + len;
        if (next + 4 > bytes.len) {
            // Not enough left to confirm; accept it, since a short read of a
            // valid file ends here legitimately.
            return i;
        }
        if (FrameHeader.parse(bytes[next..][0..4]) != null) return i;
    }
    return null;
}

fn bitrateTable(version: Version, layer: Layer) *const [16]u32 {
    return switch (version) {
        .mpeg1 => switch (layer) {
            .layer1 => &.{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 },
            .layer2 => &.{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 },
            .layer3 => &.{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 },
        },
        .mpeg2, .mpeg25 => switch (layer) {
            .layer1 => &.{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 },
            .layer2, .layer3 => &.{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
        },
    };
}

fn sampleRateTable(version: Version) *const [4]u32 {
    return switch (version) {
        .mpeg1 => &.{ 44100, 48000, 32000, 0 },
        .mpeg2 => &.{ 22050, 24000, 16000, 0 },
        .mpeg25 => &.{ 11025, 12000, 8000, 0 },
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an MPEG1 Layer III header with the given bitrate index, sample-rate
/// index and channel mode.
fn header(bitrate_index: u4, rate_index: u2, mono: bool) [4]u8 {
    return .{
        0xff,
        0xfb, // MPEG1, Layer III, no CRC
        (@as(u8, bitrate_index) << 4) | (@as(u8, rate_index) << 2),
        if (mono) 0xc0 else 0x00,
    };
}

test "a well-formed MPEG1 Layer III header" {
    // Bitrate index 9 is 128kbps, rate index 0 is 44100.
    const h = FrameHeader.parse(&header(9, 0, false)).?;
    try testing.expectEqual(Version.mpeg1, h.version);
    try testing.expectEqual(Layer.layer3, h.layer);
    try testing.expectEqual(@as(u32, 128), h.bitrate_kbps);
    try testing.expectEqual(@as(u32, 44100), h.sample_rate);
    try testing.expectEqual(@as(u32, 2), h.channels);
    try testing.expectEqual(@as(u32, 1152), h.samplesPerFrame());
    // 1152/8 * 128000 / 44100 = 417
    try testing.expectEqual(@as(u32, 417), h.frameBytes());
}

test "mono, MPEG2 and layer variants" {
    try testing.expectEqual(@as(u32, 1), FrameHeader.parse(&header(9, 0, true)).?.channels);

    // MPEG2 Layer III: version bits 10, layer bits 01.
    const mpeg2 = [_]u8{ 0xff, 0xf3, 0x90, 0x00 };
    const h = FrameHeader.parse(&mpeg2).?;
    try testing.expectEqual(Version.mpeg2, h.version);
    try testing.expectEqual(@as(u32, 22050), h.sample_rate);
    try testing.expectEqual(@as(u32, 576), h.samplesPerFrame());
}

test "implausible headers are rejected" {
    // No sync.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&.{ 0x00, 0x00, 0x00, 0x00 }));
    // Partial sync.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&.{ 0xff, 0x0b, 0x90, 0x00 }));
    // Reserved version.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&.{ 0xff, 0xeb, 0x90, 0x00 }));
    // Reserved layer.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&.{ 0xff, 0xf9, 0x90, 0x00 }));
    // Free-format and bad bitrate indices.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&header(0, 0, false)));
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&header(15, 0, false)));
    // Reserved sample rate.
    try testing.expectEqual(@as(?FrameHeader, null), FrameHeader.parse(&header(9, 3, false)));
}

/// A CBR stream of `count` frames at 128kbps/44100.
fn cbrStream(gpa: std.mem.Allocator, count: usize, lead: []const u8) ![]u8 {
    const h = header(9, 0, false);
    const frame_len = FrameHeader.parse(&h).?.frameBytes();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, lead);
    for (0..count) |_| {
        try out.appendSlice(gpa, &h);
        try out.appendNTimes(gpa, 0x55, frame_len - 4);
    }
    return out.toOwnedSlice(gpa);
}

test "findSync needs two consecutive frames to commit" {
    const gpa = testing.allocator;

    // A lone 0xFF that happens to look like a header, then the real stream.
    const stream = try cbrStream(gpa, 3, &header(9, 0, false) ++ [_]u8{ 0x00, 0x00 });
    defer gpa.free(stream);

    // The decoy at offset 0 is not followed by a valid header at its frame
    // length, so the first accepted sync is the real stream.
    const at = findSync(stream).?;
    try testing.expectEqual(@as(usize, 6), at);
}

test "findSync on data with no frames at all" {
    try testing.expectEqual(@as(?usize, null), findSync("no audio here, just text"));
    try testing.expectEqual(@as(?usize, null), findSync(""));
    try testing.expectEqual(@as(?usize, null), findSync("\xff"));
}

test "CBR duration comes from the file size" {
    const gpa = testing.allocator;
    const stream = try cbrStream(gpa, 100, "");
    defer gpa.free(stream);

    // 100 frames of 1152 samples at 44100 is about 2.61 seconds.
    const info = probe(stream, stream.len);
    try testing.expectEqual(@as(u32, 128), info.bitrate_kbps);
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expect(!info.exact);
    try testing.expectApproxEqAbs(@as(f32, 2.61), info.duration, 0.05);
}

/// A first frame carrying a Xing header declaring `frames` frames.
fn xingStream(gpa: std.mem.Allocator, frames: u32, bytes: u32) ![]u8 {
    const h = header(9, 0, false);
    const frame_len = FrameHeader.parse(&h).?.frameBytes();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &h);
    // Stereo MPEG1: Xing sits 32 bytes past the header.
    try out.appendNTimes(gpa, 0, 32);
    try out.appendSlice(gpa, "Xing");
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 0x3, .big); // frames + bytes present
    try out.appendSlice(gpa, &buf);
    std.mem.writeInt(u32, &buf, frames, .big);
    try out.appendSlice(gpa, &buf);
    std.mem.writeInt(u32, &buf, bytes, .big);
    try out.appendSlice(gpa, &buf);
    while (out.items.len < frame_len) try out.append(gpa, 0);

    // A second real frame, so findSync accepts the first.
    try out.appendSlice(gpa, &h);
    try out.appendNTimes(gpa, 0x55, frame_len - 4);
    return out.toOwnedSlice(gpa);
}

test "Xing frame count gives an exact duration" {
    const gpa = testing.allocator;
    // 7752 frames at 1152 samples / 44100 is about 202.5 seconds.
    const stream = try xingStream(gpa, 7752, 4_000_000);
    defer gpa.free(stream);

    const info = probe(stream, stream.len);
    try testing.expect(info.exact);
    try testing.expectApproxEqAbs(@as(f32, 202.5), info.duration, 0.2);
    // Average bitrate derived from the byte count, not the frame header.
    try testing.expectApproxEqAbs(@as(f32, 158), @as(f32, @floatFromInt(info.bitrate_kbps)), 2);
}

test "a Xing header with a zero frame count falls back to the size estimate" {
    const gpa = testing.allocator;
    const stream = try xingStream(gpa, 0, 0);
    defer gpa.free(stream);
    const info = probe(stream, stream.len);
    try testing.expect(!info.exact);
    try testing.expect(info.duration > 0);
}

test "VBRI headers are read too" {
    const gpa = testing.allocator;
    const h = header(9, 0, false);
    const frame_len = FrameHeader.parse(&h).?.frameBytes();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &h);
    try out.appendNTimes(gpa, 0, 32);
    try out.appendSlice(gpa, "VBRI");
    try out.appendNTimes(gpa, 0, 6); // version, delay, quality
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1_000_000, .big); // bytes
    try out.appendSlice(gpa, &buf);
    std.mem.writeInt(u32, &buf, 3876, .big); // frames
    try out.appendSlice(gpa, &buf);
    try out.appendNTimes(gpa, 0, 8);
    while (out.items.len < frame_len) try out.append(gpa, 0);
    try out.appendSlice(gpa, &h);
    try out.appendNTimes(gpa, 0x55, frame_len - 4);

    const info = probe(out.items, out.items.len);
    try testing.expect(info.exact);
    // 3876 * 1152 / 44100 is about 101.2 seconds.
    try testing.expectApproxEqAbs(@as(f32, 101.2), info.duration, 0.2);
}

test "probing something that is not MPEG yields nothing" {
    const info = probe("RIFF....WAVEfmt ", 16);
    try testing.expectEqual(@as(f32, -1), info.duration);
    try testing.expectEqual(@as(u32, 0), info.sample_rate);
}
