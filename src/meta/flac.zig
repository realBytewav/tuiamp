//! FLAC metadata: STREAMINFO for the stream format and exact length, and
//! VORBIS_COMMENT for the tags.
//!
//! FLAC is pleasant compared to ID3: the header is fixed-layout, the sample
//! count is exact, and the comments are length-prefixed UTF-8 by definition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

pub const StreamInfo = struct {
    sample_rate: u32 = 0,
    channels: u32 = 0,
    bits_per_sample: u32 = 0,
    total_samples: u64 = 0,

    pub fn duration(s: StreamInfo) f32 {
        if (s.sample_rate == 0 or s.total_samples == 0) return -1;
        return @as(f32, @floatFromInt(s.total_samples)) /
            @as(f32, @floatFromInt(s.sample_rate));
    }
};

pub const Fields = struct {
    title: ?[]u8 = null,
    artist: ?[]u8 = null,
    album: ?[]u8 = null,
    track: ?u32 = null,
    year: ?u32 = null,
    stream: StreamInfo = .{},

    pub fn deinit(f: *Fields, gpa: Allocator) void {
        if (f.title) |v| gpa.free(v);
        if (f.artist) |v| gpa.free(v);
        if (f.album) |v| gpa.free(v);
        f.* = .{};
    }
};

pub fn isFlac(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "fLaC");
}

/// Walk the metadata blocks at the start of the file. Unknown block types
/// are skipped, and a truncated block ends the walk rather than failing it.
pub fn parse(gpa: Allocator, bytes: []const u8) !Fields {
    var fields: Fields = .{};
    errdefer fields.deinit(gpa);
    if (!isFlac(bytes)) return fields;

    var i: usize = 4;
    while (i + 4 <= bytes.len) {
        const last = bytes[i] & 0x80 != 0;
        const block_type = bytes[i] & 0x7f;
        const len: usize = (@as(usize, bytes[i + 1]) << 16) |
            (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
        const start = i + 4;
        if (start + len > bytes.len) break;
        const block = bytes[start .. start + len];

        switch (block_type) {
            0 => fields.stream = parseStreamInfo(block) orelse fields.stream,
            4 => try parseComments(gpa, block, &fields),
            else => {},
        }

        i = start + len;
        if (last) break;
    }
    return fields;
}

fn parseStreamInfo(block: []const u8) ?StreamInfo {
    if (block.len < 34) return null;
    // Bytes 10..17 pack sample rate (20 bits), channels (3), bits per
    // sample (5) and total samples (36) into one 64-bit big-endian field.
    const packed_bits = std.mem.readInt(u64, block[10..18], .big);
    return .{
        .sample_rate = @intCast((packed_bits >> 44) & 0xfffff),
        .channels = @intCast(((packed_bits >> 41) & 0x7) + 1),
        .bits_per_sample = @intCast(((packed_bits >> 36) & 0x1f) + 1),
        .total_samples = packed_bits & 0xf_ffff_ffff,
    };
}

fn parseComments(gpa: Allocator, block: []const u8, out: *Fields) !void {
    var i: usize = 0;
    if (i + 4 > block.len) return;
    const vendor_len = std.mem.readInt(u32, block[i..][0..4], .little);
    i += 4;
    if (i + vendor_len > block.len) return;
    i += vendor_len;

    if (i + 4 > block.len) return;
    const count = std.mem.readInt(u32, block[i..][0..4], .little);
    i += 4;

    for (0..count) |_| {
        if (i + 4 > block.len) return;
        const len = std.mem.readInt(u32, block[i..][0..4], .little);
        i += 4;
        if (len > block.len or i + len > block.len) return;
        const entry = block[i .. i + len];
        i += len;

        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try assign(gpa, entry[0..eq], text.trim(entry[eq + 1 ..]), out);
    }
}

fn assign(gpa: Allocator, key: []const u8, value: []const u8, out: *Fields) !void {
    if (value.len == 0) return;
    const eq = std.ascii.eqlIgnoreCase;

    if (eq(key, "TITLE")) {
        try setString(gpa, &out.title, value);
    } else if (eq(key, "ARTIST")) {
        try setString(gpa, &out.artist, value);
    } else if (eq(key, "ALBUM")) {
        try setString(gpa, &out.album, value);
    } else if (eq(key, "TRACKNUMBER")) {
        out.track = out.track orelse leadingNumber(value);
    } else if (eq(key, "DATE") or eq(key, "YEAR")) {
        out.year = out.year orelse leadingNumber(value);
    }
}

/// First value wins, matching the ID3 reader: repeated keys are legal in
/// Vorbis comments and players conventionally show the first.
fn setString(gpa: Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.* != null) return;
    slot.* = try text.sanitizeUtf8(gpa, value);
}

fn leadingNumber(s: []const u8) ?u32 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, s[0..end], 10) catch null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const Builder = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator) !Builder {
        var b: Builder = .{ .gpa = gpa };
        try b.out.appendSlice(gpa, "fLaC");
        return b;
    }

    fn deinit(b: *Builder) void {
        b.out.deinit(b.gpa);
    }

    fn block(b: *Builder, block_type: u8, last: bool, payload: []const u8) !void {
        try b.out.append(b.gpa, block_type | (@as(u8, if (last) 0x80 else 0)));
        try b.out.append(b.gpa, @intCast((payload.len >> 16) & 0xff));
        try b.out.append(b.gpa, @intCast((payload.len >> 8) & 0xff));
        try b.out.append(b.gpa, @intCast(payload.len & 0xff));
        try b.out.appendSlice(b.gpa, payload);
    }

    fn streamInfo(b: *Builder, rate: u32, channels: u32, bits: u32, samples: u64) !void {
        var payload: [34]u8 = @splat(0);
        const packed_bits: u64 = (@as(u64, rate) << 44) |
            (@as(u64, channels - 1) << 41) |
            (@as(u64, bits - 1) << 36) |
            samples;
        std.mem.writeInt(u64, payload[10..18], packed_bits, .big);
        try b.block(0, false, &payload);
    }

    fn comments(b: *Builder, entries: []const []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(b.gpa);

        const vendor = "tuiamp test";
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, vendor.len, .little);
        try payload.appendSlice(b.gpa, &len);
        try payload.appendSlice(b.gpa, vendor);

        std.mem.writeInt(u32, &len, @intCast(entries.len), .little);
        try payload.appendSlice(b.gpa, &len);
        for (entries) |e| {
            std.mem.writeInt(u32, &len, @intCast(e.len), .little);
            try payload.appendSlice(b.gpa, &len);
            try payload.appendSlice(b.gpa, e);
        }
        try b.block(4, true, payload.items);
    }
};

test "STREAMINFO gives format and exact duration" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    // 44100Hz stereo 16-bit, 8,820,000 samples = exactly 200 seconds.
    try b.streamInfo(44100, 2, 16, 8_820_000);
    try b.comments(&.{});

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);

    try testing.expectEqual(@as(u32, 44100), f.stream.sample_rate);
    try testing.expectEqual(@as(u32, 2), f.stream.channels);
    try testing.expectEqual(@as(u32, 16), f.stream.bits_per_sample);
    try testing.expectApproxEqAbs(@as(f32, 200), f.stream.duration(), 0.001);
}

test "unusual channel counts and bit depths round-trip" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    try b.streamInfo(96000, 6, 24, 0);
    try b.comments(&.{});

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(u32, 96000), f.stream.sample_rate);
    try testing.expectEqual(@as(u32, 6), f.stream.channels);
    try testing.expectEqual(@as(u32, 24), f.stream.bits_per_sample);
    // An unknown sample count is reported as unknown, not as zero seconds.
    try testing.expectEqual(@as(f32, -1), f.stream.duration());
}

test "Vorbis comments, case-insensitively keyed" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    try b.streamInfo(44100, 2, 16, 44100);
    try b.comments(&.{
        "TITLE=Bleed",
        "artist=Meshuggah",
        "Album=obZen",
        "TRACKNUMBER=2",
        "DATE=2008-03-07",
        "REPLAYGAIN_TRACK_GAIN=-8.2 dB",
    });

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Bleed", f.title.?);
    try testing.expectEqualStrings("Meshuggah", f.artist.?);
    try testing.expectEqualStrings("obZen", f.album.?);
    try testing.expectEqual(@as(?u32, 2), f.track);
    try testing.expectEqual(@as(?u32, 2008), f.year);
}

test "repeated keys keep the first, empty values are ignored" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    try b.streamInfo(44100, 2, 16, 0);
    try b.comments(&.{ "TITLE=First", "TITLE=Second", "ARTIST=", "ALBUM=  " });

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("First", f.title.?);
    try testing.expectEqual(@as(?[]u8, null), f.artist);
    try testing.expectEqual(@as(?[]u8, null), f.album);
}

test "a comment with no equals sign is skipped" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    try b.streamInfo(44100, 2, 16, 0);
    try b.comments(&.{ "junk-with-no-equals", "TITLE=Still Found" });

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Still Found", f.title.?);
}

test "non-FLAC input and truncated blocks" {
    const gpa = testing.allocator;

    for ([_][]const u8{
        "",
        "fLa",
        "ID3\x03\x00\x00\x00\x00\x00\x00",
        "fLaC", // magic only
        "fLaC\x00\x00\x00\x22", // a STREAMINFO header with no body
        "fLaC\x04\x7f\xff\xff", // a comment block claiming 8MB
    }) |input| {
        var f = try parse(gpa, input);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(?[]u8, null), f.title);
    }

    try testing.expect(!isFlac("RIFF"));
    try testing.expect(isFlac("fLaC...."));
}

test "a comment count larger than the block stops cleanly" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    try b.streamInfo(44100, 2, 16, 0);

    // Hand-build a comment block claiming 1000 entries but holding one.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, 0, .little); // empty vendor
    try payload.appendSlice(gpa, &len);
    std.mem.writeInt(u32, &len, 1000, .little);
    try payload.appendSlice(gpa, &len);
    const entry = "TITLE=Only One";
    std.mem.writeInt(u32, &len, entry.len, .little);
    try payload.appendSlice(gpa, &len);
    try payload.appendSlice(gpa, entry);
    try b.block(4, true, payload.items);

    var f = try parse(gpa, b.out.items);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Only One", f.title.?);
}
