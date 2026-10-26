//! Reading a file's tags and stream properties without decoding it.
//!
//! One entry point, `read`, works out the format from the file's own magic
//! bytes rather than its extension, then hands off to the right reader.
//! Nothing here fails hard: a file we cannot understand gives empty tags and
//! the caller falls back to the filename, which is what Winamp does too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const id3 = @import("id3.zig");
const mpeg = @import("mpeg.zig");
const flac = @import("flac.zig");
const wav = @import("wav.zig");

/// How much of the file to read before giving up on finding a tag. Enough
/// for an ID3v2 tag with cover art plus the first audio frames.
const base_prefix = 64 << 10;
const max_prefix = 4 << 20;
/// Bytes of audio to keep past the tag, for the frame header and its VBR
/// header. Two maximum-size MPEG frames is plenty.
const audio_probe_bytes = 8 << 10;

pub const Tags = struct {
    title: ?[]u8 = null,
    artist: ?[]u8 = null,
    album: ?[]u8 = null,
    track: ?u32 = null,
    year: ?u32 = null,
    /// Seconds, or -1 when unknown.
    duration: f32 = -1,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    bitrate_kbps: u32 = 0,

    pub fn deinit(t: *Tags, gpa: Allocator) void {
        if (t.title) |v| gpa.free(v);
        if (t.artist) |v| gpa.free(v);
        if (t.album) |v| gpa.free(v);
        t.* = .{};
    }

    /// What the marquee and the playlist show: "Artist - Title" when both
    /// are known, the title alone when only it is, and otherwise the
    /// filename with its extension stripped. Caller owns the result.
    pub fn displayTitle(t: Tags, gpa: Allocator, path: []const u8) ![]u8 {
        if (t.artist) |artist| {
            if (t.title) |title| {
                return std.fmt.allocPrint(gpa, "{s} - {s}", .{ artist, title });
            }
        }
        if (t.title) |title| return gpa.dupe(u8, title);
        return gpa.dupe(u8, fileStem(path));
    }
};

/// Filename with its directory and extension removed.
pub fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

pub fn read(gpa: Allocator, io: Io, path: []const u8) Tags {
    return readFallible(gpa, io, path) catch .{};
}

fn readFallible(gpa: Allocator, io: Io, path: []const u8) !Tags {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const file_size = stat.size;
    if (file_size == 0) return .{};

    var prefix = try readPrefix(gpa, io, file, file_size, base_prefix);
    defer gpa.free(prefix);

    // An ID3v2 tag can be larger than the prefix we took; if so, re-read
    // enough to reach the audio behind it.
    const tag_size = id3.tagSize(prefix);
    if (tag_size + audio_probe_bytes > prefix.len and tag_size < max_prefix) {
        const want = @min(tag_size + audio_probe_bytes, max_prefix);
        const bigger = try readPrefix(gpa, io, file, file_size, want);
        gpa.free(prefix);
        prefix = bigger;
    }

    return try parseBytes(gpa, prefix, file_size);
}

fn readPrefix(gpa: Allocator, io: Io, file: Io.File, file_size: u64, want: usize) ![]u8 {
    const len: usize = @intCast(@min(file_size, want));
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return gpa.realloc(buf, n) catch buf[0..n];
}

/// Split out from `readFallible` so the format dispatch is testable without
/// touching the filesystem.
pub fn parseBytes(gpa: Allocator, prefix: []const u8, file_size: u64) !Tags {
    if (flac.isFlac(prefix)) {
        var f = try flac.parse(gpa, prefix);
        // Ownership of the strings moves into the returned Tags.
        defer f.stream = .{};
        return .{
            .title = take(&f.title),
            .artist = take(&f.artist),
            .album = take(&f.album),
            .track = f.track,
            .year = f.year,
            .duration = f.stream.duration(),
            .sample_rate = f.stream.sample_rate,
            .channels = f.stream.channels,
            .bitrate_kbps = flacBitrate(f.stream, file_size),
        };
    }

    if (wav.isWav(prefix)) {
        const info = wav.parse(prefix, file_size);
        return .{
            .duration = info.duration(),
            .sample_rate = info.sample_rate,
            .channels = info.channels,
            .bitrate_kbps = info.bitrateKbps(),
        };
    }

    // Anything else is treated as MPEG, with or without an ID3v2 tag.
    var fields = try id3.parse(gpa, prefix);
    errdefer fields.deinit(gpa);

    const tag_size = id3.tagSize(prefix);
    var tags: Tags = .{
        .title = take(&fields.title),
        .artist = take(&fields.artist),
        .album = take(&fields.album),
        .track = fields.track,
        .year = fields.year,
    };

    if (tag_size < prefix.len) {
        const audio_bytes = if (file_size > tag_size) file_size - tag_size else 0;
        const info = mpeg.probe(prefix[tag_size..], audio_bytes);
        tags.duration = info.duration;
        tags.sample_rate = info.sample_rate;
        tags.channels = info.channels;
        tags.bitrate_kbps = info.bitrate_kbps;
    }
    return tags;
}

/// Move a string out of a parser's fields, so freeing the fields afterwards
/// does not free what the caller now owns.
fn take(slot: *?[]u8) ?[]u8 {
    const v = slot.*;
    slot.* = null;
    return v;
}

fn flacBitrate(s: flac.StreamInfo, file_size: u64) u32 {
    const secs = s.duration();
    if (secs <= 0 or file_size == 0) return 0;
    const bits = @as(f64, @floatFromInt(file_size)) * 8;
    return @intFromFloat(@round(bits / @as(f64, secs) / 1000));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "fileStem strips directory and extension" {
    try testing.expectEqualStrings("Bleed", fileStem("/m/Meshuggah/Bleed.mp3"));
    try testing.expectEqualStrings("track", fileStem("track.flac"));
    try testing.expectEqualStrings("no-ext", fileStem("/a/b/no-ext"));
    try testing.expectEqualStrings(".hidden", fileStem("/a/.hidden"));
    try testing.expectEqualStrings("", fileStem(""));
}

test "displayTitle prefers Artist - Title, then Title, then the filename" {
    const gpa = testing.allocator;

    {
        var t: Tags = .{
            .title = try gpa.dupe(u8, "Bleed"),
            .artist = try gpa.dupe(u8, "Meshuggah"),
        };
        defer t.deinit(gpa);
        const s = try t.displayTitle(gpa, "/m/x.mp3");
        defer gpa.free(s);
        try testing.expectEqualStrings("Meshuggah - Bleed", s);
    }
    {
        var t: Tags = .{ .title = try gpa.dupe(u8, "Just A Title") };
        defer t.deinit(gpa);
        const s = try t.displayTitle(gpa, "/m/x.mp3");
        defer gpa.free(s);
        try testing.expectEqualStrings("Just A Title", s);
    }
    {
        // An artist with no title is not enough; fall back to the filename.
        var t: Tags = .{ .artist = try gpa.dupe(u8, "Someone") };
        defer t.deinit(gpa);
        const s = try t.displayTitle(gpa, "/m/Nice Song.mp3");
        defer gpa.free(s);
        try testing.expectEqualStrings("Nice Song", s);
    }
    {
        var t: Tags = .{};
        const s = try t.displayTitle(gpa, "/m/Nice Song.mp3");
        defer gpa.free(s);
        try testing.expectEqualStrings("Nice Song", s);
    }
}

test "format dispatch is by magic bytes, not by extension" {
    const gpa = testing.allocator;

    // A FLAC stream.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "fLaC");
        var si: [34]u8 = @splat(0);
        const packed_bits: u64 = (@as(u64, 44100) << 44) | (@as(u64, 1) << 41) |
            (@as(u64, 15) << 36) | 441000;
        std.mem.writeInt(u64, si[10..18], packed_bits, .big);
        try buf.appendSlice(gpa, &[_]u8{ 0x80, 0, 0, 34 });
        try buf.appendSlice(gpa, &si);

        var t = try parseBytes(gpa, buf.items, 1_000_000);
        defer t.deinit(gpa);
        try testing.expectApproxEqAbs(@as(f32, 10), t.duration, 0.001);
        try testing.expectEqual(@as(u32, 2), t.channels);
        try testing.expect(t.bitrate_kbps > 0);
    }

    // A WAV stream.
    {
        const w = "RIFF\x00\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++
            "\x01\x00\x02\x00\x44\xac\x00\x00\x10\xb1\x02\x00\x04\x00\x10\x00" ++
            "data\x00\x00\x00\x00";
        var t = try parseBytes(gpa, w, w.len + 176400);
        defer t.deinit(gpa);
        try testing.expectEqual(@as(u32, 44100), t.sample_rate);
        try testing.expectApproxEqAbs(@as(f32, 1), t.duration, 0.01);
    }

    // Something that is none of the above.
    {
        var t = try parseBytes(gpa, "this is a text file", 19);
        defer t.deinit(gpa);
        try testing.expectEqual(@as(?[]u8, null), t.title);
        try testing.expectEqual(@as(f32, -1), t.duration);
    }
}

test "an ID3 tag and the audio behind it are read together" {
    const gpa = testing.allocator;

    // An ID3v2.3 tag with a title, then a CBR MPEG stream.
    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(gpa);

    const frame_payload = "\x00Tagged Title";
    const frames_len = 10 + frame_payload.len;
    try tag.appendSlice(gpa, "ID3\x03\x00\x00");
    try tag.appendSlice(gpa, &[_]u8{ 0, 0, 0, @intCast(frames_len) });
    try tag.appendSlice(gpa, "TIT2");
    try tag.appendSlice(gpa, &[_]u8{ 0, 0, 0, @intCast(frame_payload.len) });
    try tag.appendSlice(gpa, &[_]u8{ 0, 0 });
    try tag.appendSlice(gpa, frame_payload);

    // 128kbps 44100 stereo frames.
    const header = [_]u8{ 0xff, 0xfb, 0x90, 0x00 };
    for (0..50) |_| {
        try tag.appendSlice(gpa, &header);
        try tag.appendNTimes(gpa, 0x55, 417 - 4);
    }

    var t = try parseBytes(gpa, tag.items, tag.items.len);
    defer t.deinit(gpa);

    try testing.expectEqualStrings("Tagged Title", t.title.?);
    try testing.expectEqual(@as(u32, 44100), t.sample_rate);
    try testing.expectEqual(@as(u32, 128), t.bitrate_kbps);
    // 50 frames of 1152 samples at 44100 is about 1.3 seconds.
    try testing.expectApproxEqAbs(@as(f32, 1.3), t.duration, 0.1);
}

test "reading a real file off disk, and a missing one" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A tiny but valid WAV.
    const w = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++
        "\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00" ++
        "data\x00\x00\x01\x00" ++ ("\x00" ** 256);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.wav", .data = w });

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "a.wav" });
    defer gpa.free(path);

    var t = read(gpa, io, path);
    defer t.deinit(gpa);
    try testing.expectEqual(@as(u32, 44100), t.sample_rate);
    try testing.expectEqual(@as(u32, 1), t.channels);
    try testing.expect(t.duration > 0);

    // Missing and empty files give empty tags rather than an error.
    var missing = read(gpa, io, "/definitely/not/here.mp3");
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(f32, -1), missing.duration);

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.mp3", .data = "" });
    const empty_path = try std.fs.path.join(gpa, &.{ root, "empty.mp3" });
    defer gpa.free(empty_path);
    var empty = read(gpa, io, empty_path);
    defer empty.deinit(gpa);
    try testing.expectEqual(@as(f32, -1), empty.duration);
}
