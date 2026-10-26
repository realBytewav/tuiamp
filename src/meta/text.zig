//! Text decoding for tag formats.
//!
//! ID3 predates the settling of Unicode and carries four different encodings
//! depending on the tag version and a per-frame byte. Everything here
//! normalizes to UTF-8, which is what the rest of the program speaks.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Encoding = enum(u8) {
    /// ID3's "ISO-8859-1", in practice Latin-1.
    latin1 = 0,
    /// UTF-16 with a byte order mark.
    utf16_bom = 1,
    /// UTF-16 big endian, no BOM. ID3v2.4 only.
    utf16_be = 2,
    /// ID3v2.4 only.
    utf8 = 3,
    _,
};

/// Decode `bytes` to owned UTF-8. Invalid sequences are replaced rather than
/// rejected: a tag with one bad byte should still give up its title.
pub fn decode(gpa: Allocator, encoding: Encoding, bytes: []const u8) ![]u8 {
    return switch (encoding) {
        .latin1 => latin1ToUtf8(gpa, bytes),
        .utf16_bom => utf16ToUtf8(gpa, bytes, null),
        .utf16_be => utf16ToUtf8(gpa, bytes, .big),
        .utf8 => sanitizeUtf8(gpa, bytes),
        // An unknown encoding byte is most often Latin-1 in the wild.
        _ => latin1ToUtf8(gpa, bytes),
    };
}

pub fn latin1ToUtf8(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);
    for (bytes) |b| {
        if (b < 0x80) {
            try out.append(gpa, b);
        } else {
            // Every Latin-1 byte is a codepoint, so this is a 2-byte encode.
            try out.append(gpa, 0xc0 | (b >> 6));
            try out.append(gpa, 0x80 | (b & 0x3f));
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `forced` overrides BOM detection; pass null to read a BOM, defaulting to
/// little endian when there is none.
pub fn utf16ToUtf8(gpa: Allocator, bytes: []const u8, forced: ?std.builtin.Endian) ![]u8 {
    var src = bytes;
    var endian: std.builtin.Endian = forced orelse .little;

    if (forced == null and src.len >= 2) {
        if (src[0] == 0xff and src[1] == 0xfe) {
            endian = .little;
            src = src[2..];
        } else if (src[0] == 0xfe and src[1] == 0xff) {
            endian = .big;
            src = src[2..];
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i + 1 < src.len) : (i += 2) {
        const unit = readU16(src[i..][0..2], endian);

        var cp: u21 = unit;
        if (unit >= 0xd800 and unit < 0xdc00) {
            // High surrogate: pair it with the low one if there is a low one.
            if (i + 3 < src.len) {
                const low = readU16(src[i + 2 ..][0..2], endian);
                if (low >= 0xdc00 and low < 0xe000) {
                    cp = 0x10000 +
                        ((@as(u21, unit) - 0xd800) << 10) +
                        (@as(u21, low) - 0xdc00);
                    i += 2;
                } else {
                    cp = 0xfffd;
                }
            } else {
                cp = 0xfffd;
            }
        } else if (unit >= 0xdc00 and unit < 0xe000) {
            // An unpaired low surrogate.
            cp = 0xfffd;
        }

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
            buf[0] = '?';
            break :blk 1;
        };
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Copy UTF-8 through, replacing anything malformed.
pub fn sanitizeUtf8(gpa: Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
            continue;
        };
        if (i + len > bytes.len or
            std.unicode.utf8Decode(bytes[i..][0..len]) == error.Utf8InvalidStartByte)
        {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(bytes[i..][0..len]) catch {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
            continue;
        };
        try out.appendSlice(gpa, bytes[i..][0..len]);
        i += len;
    }
    return out.toOwnedSlice(gpa);
}

fn readU16(pair: *const [2]u8, endian: std.builtin.Endian) u16 {
    return switch (endian) {
        .little => @as(u16, pair[0]) | (@as(u16, pair[1]) << 8),
        .big => (@as(u16, pair[0]) << 8) | @as(u16, pair[1]),
    };
}

/// Tag values are routinely padded with NULs and whitespace.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &[_]u8{ 0, ' ', '\t', '\r', '\n' });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDecoded(expected: []const u8, encoding: Encoding, bytes: []const u8) !void {
    const got = try decode(testing.allocator, encoding, bytes);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "latin1 high bytes become proper UTF-8" {
    try expectDecoded("Bjork", .latin1, "Bjork");
    // 0xF6 is o-umlaut, 0xE9 is e-acute.
    try expectDecoded("Bj\u{f6}rk", .latin1, "Bj\xf6rk");
    try expectDecoded("Caf\u{e9}", .latin1, "Caf\xe9");
    try expectDecoded("", .latin1, "");
}

test "utf16 with either BOM" {
    // "Hi" little endian with BOM.
    try expectDecoded("Hi", .utf16_bom, "\xff\xfeH\x00i\x00");
    // Big endian with BOM.
    try expectDecoded("Hi", .utf16_bom, "\xfe\xff\x00H\x00i");
    // No BOM defaults to little endian.
    try expectDecoded("Hi", .utf16_bom, "H\x00i\x00");
    // Declared big endian, no BOM.
    try expectDecoded("Hi", .utf16_be, "\x00H\x00i");
}

test "utf16 surrogate pairs and lone surrogates" {
    // U+1F3B5 MUSICAL NOTE as a surrogate pair, little endian.
    try expectDecoded("\u{1f3b5}", .utf16_be, "\xd8\x3c\xdf\xb5");
    // A lone high surrogate becomes the replacement character.
    try expectDecoded("\u{fffd}", .utf16_be, "\xd8\x3c");
    // A lone low surrogate too.
    try expectDecoded("\u{fffd}", .utf16_be, "\xdf\xb5");
}

test "utf16 with an odd trailing byte does not read past the end" {
    try expectDecoded("Hi", .utf16_be, "\x00H\x00i\x00");
}

test "utf8 passes through and invalid bytes are replaced" {
    try expectDecoded("na\u{ef}ve \u{266b}", .utf8, "na\u{ef}ve \u{266b}");
    // A bare continuation byte is not valid UTF-8.
    const got = try decode(testing.allocator, .utf8, "ok\xff!");
    defer testing.allocator.free(got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    try testing.expect(std.mem.startsWith(u8, got, "ok"));
    try testing.expect(std.mem.endsWith(u8, got, "!"));
}

test "an unknown encoding byte falls back to latin1" {
    try expectDecoded("Caf\u{e9}", @enumFromInt(9), "Caf\xe9");
}

test "trim strips NUL padding as well as whitespace" {
    try testing.expectEqualStrings("Title", trim("Title\x00\x00"));
    try testing.expectEqualStrings("Title", trim("  Title \r\n"));
    try testing.expectEqualStrings("", trim("\x00\x00"));
    try testing.expectEqualStrings("", trim(""));
}
