//! ID3v2 tag reading, versions 2.2 through 2.4.
//!
//! The three versions differ in frame-ID length, how frame sizes are encoded,
//! and where unsynchronisation is applied, so each is handled explicitly
//! rather than pretended to be the same.
//!
//! Parsing is deliberately forgiving. Tags in the wild are full of truncated
//! frames, bogus sizes and padding; a single bad frame should cost that frame
//! and nothing else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

pub const Fields = struct {
    title: ?[]u8 = null,
    artist: ?[]u8 = null,
    album: ?[]u8 = null,
    track: ?u32 = null,
    year: ?u32 = null,

    pub fn deinit(f: *Fields, gpa: Allocator) void {
        if (f.title) |v| gpa.free(v);
        if (f.artist) |v| gpa.free(v);
        if (f.album) |v| gpa.free(v);
        f.* = .{};
    }
};

/// Total bytes the ID3v2 tag occupies at the start of the file, including
/// the header, or 0 when there is no tag. Callers need this to find where
/// the audio actually begins.
pub fn tagSize(bytes: []const u8) usize {
    const h = Header.parse(bytes) orelse return 0;
    return h.totalSize();
}

const Header = struct {
    major: u8,
    /// Size of the frame area, excluding the 10-byte header.
    body_size: usize,
    unsynchronized: bool,
    extended: bool,
    footer: bool,

    fn parse(bytes: []const u8) ?Header {
        if (bytes.len < 10) return null;
        if (!std.mem.eql(u8, bytes[0..3], "ID3")) return null;
        // 0xFF is never a valid version byte, and marks a corrupt header.
        if (bytes[3] == 0xff or bytes[4] == 0xff) return null;

        const flags = bytes[5];
        return .{
            .major = bytes[3],
            .body_size = synchsafe(bytes[6..10]) orelse return null,
            .unsynchronized = flags & 0x80 != 0,
            .extended = flags & 0x40 != 0,
            .footer = flags & 0x10 != 0,
        };
    }

    fn totalSize(h: Header) usize {
        return 10 + h.body_size + @as(usize, if (h.footer) 10 else 0);
    }
};

/// Read the tag at the start of `bytes`. Returns empty fields when there is
/// no tag or it cannot be understood.
pub fn parse(gpa: Allocator, bytes: []const u8) !Fields {
    var fields: Fields = .{};
    errdefer fields.deinit(gpa);

    const h = Header.parse(bytes) orelse return fields;
    if (h.major < 2 or h.major > 4) return fields;

    const end = @min(10 + h.body_size, bytes.len);
    if (end <= 10) return fields;
    var body = bytes[10..end];

    // In 2.3 and earlier unsynchronisation covers the whole tag; in 2.4 it is
    // per-frame and handled below.
    //
    // ID3v2.3 declares frame sizes in on-disk (still escaped) bytes, but the
    // frame headers are escaped too, so the only way to read them is to
    // de-synchronise the whole body first. That leaves declared sizes up to
    // `slack` bytes longer than what remains — exactly the number of escapes
    // removed — which `parseFrames` uses as its tolerance.
    var slack: usize = 0;
    var owned_body: ?[]u8 = null;
    defer if (owned_body) |b| gpa.free(b);
    if (h.unsynchronized and h.major < 4) {
        owned_body = try deunsynchronize(gpa, body);
        slack = body.len - owned_body.?.len;
        body = owned_body.?;
    }

    if (h.extended) {
        const skip = extendedHeaderSize(h.major, body);
        if (skip >= body.len) return fields;
        body = body[skip..];
    }

    if (h.major == 2) {
        try parseFramesV22(gpa, body, slack, &fields);
    } else {
        try parseFrames(gpa, body, h.major, h.unsynchronized, slack, &fields);
    }
    return fields;
}

fn parseFrames(
    gpa: Allocator,
    body: []const u8,
    major: u8,
    tag_unsync: bool,
    slack: usize,
    out: *Fields,
) !void {
    var i: usize = 0;
    while (i + 10 <= body.len) {
        const id = body[i..][0..4];
        // A run of zeroes is the padding that ends the frame area.
        if (id[0] == 0) break;

        const size: usize = if (major >= 4)
            synchsafe(body[i + 4 ..][0..4]) orelse break
        else
            std.mem.readInt(u32, body[i + 4 ..][0..4], .big);

        const flags = std.mem.readInt(u16, body[i + 8 ..][0..2], .big);
        const start = i + 10;
        if (size == 0 or start > body.len) break;
        const end = clampFrameEnd(start, size, body.len, slack) orelse break;
        var payload = body[start..end];
        i = end;

        // 2.4 frames carry their own unsynchronisation flag.
        var owned: ?[]u8 = null;
        defer if (owned) |b| gpa.free(b);
        if (major >= 4 and (flags & 0x0002 != 0) and !tag_unsync) {
            owned = try deunsynchronize(gpa, payload);
            payload = owned.?;
        }

        // A data-length indicator precedes the payload when the frame is
        // compressed or encrypted. We cannot read those, so skip them.
        if (major >= 4 and (flags & 0x000c != 0)) continue;
        if (major == 3 and (flags & 0x00c0 != 0)) continue;

        try assign(gpa, id, payload, out);
    }
}

fn parseFramesV22(gpa: Allocator, body: []const u8, slack: usize, out: *Fields) !void {
    var i: usize = 0;
    while (i + 6 <= body.len) {
        const id3 = body[i..][0..3];
        if (id3[0] == 0) break;

        const size: usize = (@as(usize, body[i + 3]) << 16) |
            (@as(usize, body[i + 4]) << 8) | body[i + 5];
        const start = i + 6;
        if (size == 0 or start > body.len) break;
        const end = clampFrameEnd(start, size, body.len, slack) orelse break;
        const payload = body[start..end];
        i = end;

        // Map the three-character IDs onto their modern equivalents.
        const id: *const [4]u8 =
            if (std.mem.eql(u8, id3, "TT2")) "TIT2" else if (std.mem.eql(u8, id3, "TP1"))
                "TPE1"
            else if (std.mem.eql(u8, id3, "TAL"))
                "TALB"
            else if (std.mem.eql(u8, id3, "TRK"))
                "TRCK"
            else if (std.mem.eql(u8, id3, "TYE"))
                "TYER"
            else
                continue;

        try assign(gpa, id, payload, out);
    }
}

fn assign(gpa: Allocator, id: *const [4]u8, payload: []const u8, out: *Fields) !void {
    const eq = std.mem.eql;
    if (eq(u8, id, "TIT2")) {
        try setString(gpa, &out.title, payload);
    } else if (eq(u8, id, "TPE1")) {
        try setString(gpa, &out.artist, payload);
    } else if (eq(u8, id, "TALB")) {
        try setString(gpa, &out.album, payload);
    } else if (eq(u8, id, "TRCK")) {
        out.track = try parseLeadingNumber(gpa, payload);
    } else if (eq(u8, id, "TYER") or eq(u8, id, "TDRC")) {
        out.year = try parseLeadingNumber(gpa, payload);
    }
}

/// First value wins: duplicated frames are common and the first is the one
/// most players show.
fn setString(gpa: Allocator, slot: *?[]u8, payload: []const u8) !void {
    if (slot.* != null) return;
    const decoded = try decodeTextFrame(gpa, payload) orelse return;
    if (decoded.len == 0) {
        gpa.free(decoded);
        return;
    }
    slot.* = decoded;
}

/// A text frame is an encoding byte followed by the text itself.
fn decodeTextFrame(gpa: Allocator, payload: []const u8) !?[]u8 {
    if (payload.len < 1) return null;
    const encoding: text.Encoding = @enumFromInt(payload[0]);
    const raw = payload[1..];

    const decoded = try text.decode(gpa, encoding, raw);
    defer gpa.free(decoded);

    // ID3v2.4 allows multiple NUL-separated values; show the first.
    const first = if (std.mem.indexOfScalar(u8, decoded, 0)) |nul|
        decoded[0..nul]
    else
        decoded;

    return try gpa.dupe(u8, text.trim(first));
}

/// `TRCK` is "5" or "5/12"; `TYER` may be "1998" or a full ISO timestamp.
fn parseLeadingNumber(gpa: Allocator, payload: []const u8) !?u32 {
    const s = try decodeTextFrame(gpa, payload) orelse return null;
    defer gpa.free(s);

    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, s[0..end], 10) catch null;
}

/// End offset of a frame whose declared `size` may overshoot by at most
/// `slack` bytes. Returns null when the overshoot is too large to be the
/// unsynchronisation accounting, which means the tag is truncated or bogus
/// and parsing should stop.
fn clampFrameEnd(start: usize, size: usize, body_len: usize, slack: usize) ?usize {
    const declared = start + size;
    if (declared <= body_len) return declared;
    if (declared <= body_len + slack) return body_len;
    return null;
}

/// Undo the 0xFF 0x00 escaping that keeps tag bytes from looking like an
/// MPEG sync word to a naive decoder.
fn deunsynchronize(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        try out.append(gpa, bytes[i]);
        if (bytes[i] == 0xff and i + 1 < bytes.len and bytes[i + 1] == 0x00) i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn extendedHeaderSize(major: u8, body: []const u8) usize {
    if (body.len < 4) return body.len;
    if (major >= 4) {
        // 2.4: the size is synchsafe and includes itself.
        return synchsafe(body[0..4]) orelse body.len;
    }
    // 2.3: the size excludes the four size bytes themselves.
    return 4 + std.mem.readInt(u32, body[0..4], .big);
}

/// ID3's 28-bit size format: four bytes, seven bits each, high bit always 0.
fn synchsafe(bytes: *const [4]u8) ?usize {
    for (bytes) |b| if (b & 0x80 != 0) return null;
    return (@as(usize, bytes[0]) << 21) |
        (@as(usize, bytes[1]) << 14) |
        (@as(usize, bytes[2]) << 7) |
        @as(usize, bytes[3]);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an ID3v2 tag in memory, so the tests do not need sample files.
const Builder = struct {
    gpa: Allocator,
    major: u8,
    flags: u8 = 0,
    frames: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator, major: u8) Builder {
        return .{ .gpa = gpa, .major = major };
    }

    fn deinit(b: *Builder) void {
        b.frames.deinit(b.gpa);
    }

    fn textFrame(b: *Builder, id: []const u8, encoding: u8, body: []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(b.gpa);
        try payload.append(b.gpa, encoding);
        try payload.appendSlice(b.gpa, body);
        try b.rawFrame(id, payload.items, 0);
    }

    fn rawFrame(b: *Builder, id: []const u8, payload: []const u8, frame_flags: u16) !void {
        if (b.major == 2) {
            try b.frames.appendSlice(b.gpa, id[0..3]);
            try b.frames.append(b.gpa, @intCast((payload.len >> 16) & 0xff));
            try b.frames.append(b.gpa, @intCast((payload.len >> 8) & 0xff));
            try b.frames.append(b.gpa, @intCast(payload.len & 0xff));
        } else {
            try b.frames.appendSlice(b.gpa, id[0..4]);
            var size: [4]u8 = undefined;
            if (b.major >= 4) {
                writeSynchsafe(&size, payload.len);
            } else {
                std.mem.writeInt(u32, &size, @intCast(payload.len), .big);
            }
            try b.frames.appendSlice(b.gpa, &size);
            var ff: [2]u8 = undefined;
            std.mem.writeInt(u16, &ff, frame_flags, .big);
            try b.frames.appendSlice(b.gpa, &ff);
        }
        try b.frames.appendSlice(b.gpa, payload);
    }

    /// Finish the tag and append `padding` zero bytes plus `trailer`.
    fn build(b: *Builder, padding: usize, trailer: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(b.gpa);

        const body_len = b.frames.items.len + padding;
        try out.appendSlice(b.gpa, "ID3");
        try out.append(b.gpa, b.major);
        try out.append(b.gpa, 0);
        try out.append(b.gpa, b.flags);
        var size: [4]u8 = undefined;
        writeSynchsafe(&size, body_len);
        try out.appendSlice(b.gpa, &size);
        try out.appendSlice(b.gpa, b.frames.items);
        try out.appendNTimes(b.gpa, 0, padding);
        try out.appendSlice(b.gpa, trailer);
        return out.toOwnedSlice(b.gpa);
    }
};

fn writeSynchsafe(out: *[4]u8, value: usize) void {
    out[0] = @intCast((value >> 21) & 0x7f);
    out[1] = @intCast((value >> 14) & 0x7f);
    out[2] = @intCast((value >> 7) & 0x7f);
    out[3] = @intCast(value & 0x7f);
}

test "clampFrameEnd tolerates only the unsynchronisation shortfall" {
    // Fits exactly.
    try testing.expectEqual(@as(?usize, 20), clampFrameEnd(10, 10, 20, 0));
    // Overshoots with no slack: refuse.
    try testing.expectEqual(@as(?usize, null), clampFrameEnd(10, 11, 20, 0));
    // Overshoots within the slack: clamp to what is there.
    try testing.expectEqual(@as(?usize, 20), clampFrameEnd(10, 11, 20, 1));
    try testing.expectEqual(@as(?usize, 20), clampFrameEnd(10, 13, 20, 3));
    // Overshoots beyond the slack: still refuse.
    try testing.expectEqual(@as(?usize, null), clampFrameEnd(10, 14, 20, 3));
}

test "synchsafe decoding rejects bytes with the high bit set" {
    try testing.expectEqual(@as(?usize, 0), synchsafe(&.{ 0, 0, 0, 0 }));
    try testing.expectEqual(@as(?usize, 1), synchsafe(&.{ 0, 0, 0, 1 }));
    try testing.expectEqual(@as(?usize, 128), synchsafe(&.{ 0, 0, 1, 0 }));
    try testing.expectEqual(@as(?usize, 0x0fffffff), synchsafe(&.{ 0x7f, 0x7f, 0x7f, 0x7f }));
    try testing.expectEqual(@as(?usize, null), synchsafe(&.{ 0, 0, 0, 0x80 }));
}

test "ID3v2.3 latin1 frames" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TIT2", 0, "Dancing Mad");
    try b.textFrame("TPE1", 0, "Nobuo Uematsu");
    try b.textFrame("TALB", 0, "Final Fantasy VI");
    try b.textFrame("TRCK", 0, "14/20");
    try b.textFrame("TYER", 0, "1994");
    const tag = try b.build(64, "\xff\xfb\x90\x00audio");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);

    try testing.expectEqualStrings("Dancing Mad", f.title.?);
    try testing.expectEqualStrings("Nobuo Uematsu", f.artist.?);
    try testing.expectEqualStrings("Final Fantasy VI", f.album.?);
    try testing.expectEqual(@as(?u32, 14), f.track);
    try testing.expectEqual(@as(?u32, 1994), f.year);

    // The audio starts right after the tag, padding included.
    try testing.expectEqual(tag.len - 9, tagSize(tag));
}

test "ID3v2.4 UTF-8 and TDRC" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 4);
    defer b.deinit();
    try b.textFrame("TIT2", 3, "na\u{ef}ve \u{266b}");
    try b.textFrame("TDRC", 3, "2003-05-17T12:00:00");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("na\u{ef}ve \u{266b}", f.title.?);
    try testing.expectEqual(@as(?u32, 2003), f.year);
}

test "ID3v2.2 three-character frame IDs" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 2);
    defer b.deinit();
    try b.textFrame("TT2", 0, "Old Tag");
    try b.textFrame("TP1", 0, "Someone");
    try b.textFrame("TRK", 0, "3");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Old Tag", f.title.?);
    try testing.expectEqualStrings("Someone", f.artist.?);
    try testing.expectEqual(@as(?u32, 3), f.track);
}

test "UTF-16 frames with a BOM" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TIT2", 1, "\xff\xfeH\x00i\x00");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Hi", f.title.?);
}

test "whole-tag unsynchronisation is undone" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    b.flags = 0x80;
    // The escaped form of a title containing 0xFF.
    try b.textFrame("TIT2", 0, "A\xff\x00B");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("A\u{ff}B", f.title.?);
}

test "per-frame unsynchronisation in 2.4" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 4);
    defer b.deinit();
    try b.rawFrame("TIT2", "\x00A\xff\x00B", 0x0002);
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("A\u{ff}B", f.title.?);
}

test "compressed and encrypted frames are skipped, not garbled" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 4);
    defer b.deinit();
    // Compression flag set: the payload is not plain text.
    try b.rawFrame("TIT2", "\x00\x78\x9c garbage", 0x0008);
    try b.textFrame("TPE1", 0, "Readable");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), f.title);
    try testing.expectEqualStrings("Readable", f.artist.?);
}

test "duplicate frames keep the first" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TIT2", 0, "First");
    try b.textFrame("TIT2", 0, "Second");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("First", f.title.?);
}

test "no tag, truncated tag, and junk" {
    const gpa = testing.allocator;

    for ([_][]const u8{
        "",
        "ID3",
        "ID3\x03\x00\x00",
        "ID3\x03\x00\x00\x00\x00\x00", // header cut short
        "\xff\xfb\x90\x00raw mp3 with no tag",
        "ID3\xff\xff\x00\x00\x00\x00\x00", // bogus version
        "ID3\x09\x00\x00\x00\x00\x00\x20" ++ ("x" ** 32), // unsupported version
    }) |input| {
        var f = try parse(gpa, input);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(?[]u8, null), f.title);
    }

    try testing.expectEqual(@as(usize, 0), tagSize("no tag here"));
}

test "a frame claiming more bytes than exist stops parsing cleanly" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TIT2", 0, "Good");
    // Hand-write a frame header whose size runs past the end of the tag.
    try b.frames.appendSlice(gpa, "TPE1");
    try b.frames.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x7f, 0xff });
    try b.frames.appendSlice(gpa, &[_]u8{ 0, 0 });
    try b.frames.appendSlice(gpa, "short");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("Good", f.title.?);
    try testing.expectEqual(@as(?[]u8, null), f.artist);
}

test "empty text frames do not become empty titles" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TIT2", 0, "");
    try b.textFrame("TPE1", 0, "\x00\x00");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), f.title);
    try testing.expectEqual(@as(?[]u8, null), f.artist);
}

test "an extended header is skipped" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    b.flags = 0x40;
    // A 2.3 extended header: four size bytes, then that many bytes.
    try b.frames.appendSlice(gpa, &[_]u8{ 0, 0, 0, 6 });
    try b.frames.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    try b.textFrame("TIT2", 0, "After Extended");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqualStrings("After Extended", f.title.?);
}

test "non-numeric track and year fields are ignored" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, 3);
    defer b.deinit();
    try b.textFrame("TRCK", 0, "A/B");
    try b.textFrame("TYER", 0, "unknown");
    const tag = try b.build(0, "");
    defer gpa.free(tag);

    var f = try parse(gpa, tag);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(?u32, null), f.track);
    try testing.expectEqual(@as(?u32, null), f.year);
}
