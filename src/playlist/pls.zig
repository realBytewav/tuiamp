//! PLS (SHOUTcast/Winamp playlist) reading and writing.
//!
//! PLS is an INI file whose entries are numbered rather than ordered:
//!
//!     [playlist]
//!     File2=/music/b.mp3
//!     Title2=B
//!     Length2=200
//!     File1=/music/a.mp3
//!     NumberOfEntries=2
//!
//! The numbering is authoritative and may arrive in any order and with gaps,
//! so parsing has to collect by index rather than stream. Returned slices
//! point into the input, which the caller keeps alive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Track = @import("m3u.zig").Track;

/// Parse into a slice ordered by entry number, with gaps dropped. Caller owns
/// the returned slice (but not the strings inside it, which borrow `bytes`).
pub fn parse(gpa: Allocator, bytes: []const u8) ![]Track {
    const Slot = struct {
        path: ?[]const u8 = null,
        title: ?[]const u8 = null,
        duration: f32 = -1,
    };

    var slots: std.ArrayList(Slot) = .empty;
    defer slots.deinit(gpa);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n\xef\xbb\xbf");
        if (line.len == 0 or line[0] == '[' or line[0] == ';' or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const field = splitKey(key) orelse continue;
        if (field.number == 0) continue; // PLS numbers from 1

        // Grow to fit; absent indices stay empty and are dropped at the end.
        while (slots.items.len < field.number) try slots.append(gpa, .{});
        const slot = &slots.items[field.number - 1];

        switch (field.kind) {
            .file => slot.path = value,
            .title => slot.title = if (value.len > 0) value else null,
            .length => {
                const d = std.fmt.parseFloat(f32, value) catch -1;
                slot.duration = if (d < 0) -1 else d;
            },
        }
    }

    var out: std.ArrayList(Track) = .empty;
    errdefer out.deinit(gpa);
    for (slots.items) |s| {
        const path = s.path orelse continue;
        if (path.len == 0) continue;
        try out.append(gpa, .{ .path = path, .title = s.title, .duration = s.duration });
    }
    return out.toOwnedSlice(gpa);
}

const Field = struct {
    kind: enum { file, title, length },
    number: usize,
};

/// `File12` -> .{ .file, 12 }. Returns null for NumberOfEntries, Version and
/// anything else we do not care about.
fn splitKey(key: []const u8) ?Field {
    const kind: @FieldType(Field, "kind"), const prefix_len: usize =
        if (std.ascii.startsWithIgnoreCase(key, "file"))
            .{ .file, 4 }
        else if (std.ascii.startsWithIgnoreCase(key, "title"))
            .{ .title, 5 }
        else if (std.ascii.startsWithIgnoreCase(key, "length"))
            .{ .length, 6 }
        else
            return null;

    if (key.len <= prefix_len) return null;
    const number = std.fmt.parseInt(usize, key[prefix_len..], 10) catch return null;
    return .{ .kind = kind, .number = number };
}

pub const WriteEntry = @import("m3u.zig").WriteEntry;

pub fn write(w: *std.Io.Writer, entries: []const WriteEntry) !void {
    try w.writeAll("[playlist]\n");
    for (entries, 1..) |e, n| {
        const secs: i64 = if (e.duration >= 0) @intFromFloat(@round(e.duration)) else -1;
        try w.print("File{d}={s}\nTitle{d}={s}\nLength{d}={d}\n", .{
            n, e.path, n, e.title, n, secs,
        });
    }
    try w.print("NumberOfEntries={d}\nVersion=2\n", .{entries.len});
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "entries are ordered by number, not by file position" {
    const text =
        \\[playlist]
        \\File2=/music/b.mp3
        \\Title2=Bee
        \\Length2=200
        \\File1=/music/a.mp3
        \\Title1=Ay
        \\Length1=100
        \\NumberOfEntries=2
        \\Version=2
    ;
    const tracks = try parse(testing.allocator, text);
    defer testing.allocator.free(tracks);

    try testing.expectEqual(@as(usize, 2), tracks.len);
    try testing.expectEqualStrings("/music/a.mp3", tracks[0].path);
    try testing.expectEqualStrings("Ay", tracks[0].title.?);
    try testing.expectApproxEqAbs(@as(f32, 100), tracks[0].duration, 0.01);
    try testing.expectEqualStrings("/music/b.mp3", tracks[1].path);
}

test "gaps in the numbering are dropped, not turned into empty rows" {
    const text =
        \\[playlist]
        \\File1=a.mp3
        \\File5=e.mp3
        \\Title5=E
    ;
    const tracks = try parse(testing.allocator, text);
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 2), tracks.len);
    try testing.expectEqualStrings("a.mp3", tracks[0].path);
    try testing.expectEqualStrings("e.mp3", tracks[1].path);
}

test "missing titles and lengths fall back cleanly" {
    const tracks = try parse(testing.allocator, "[playlist]\nFile1=only.mp3\n");
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqual(@as(?[]const u8, null), tracks[0].title);
    try testing.expectEqual(@as(f32, -1), tracks[0].duration);
}

test "a Title with no File is not an entry" {
    const tracks = try parse(testing.allocator, "[playlist]\nTitle1=orphan\nLength1=5\n");
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 0), tracks.len);
}

test "case-insensitive keys, CRLF, comments and a BOM" {
    const text = "\xef\xbb\xbf[Playlist]\r\n; a comment\r\nfile1=x.mp3\r\nTITLE1=X\r\nlength1=-1\r\n";
    const tracks = try parse(testing.allocator, text);
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqualStrings("x.mp3", tracks[0].path);
    try testing.expectEqualStrings("X", tracks[0].title.?);
    try testing.expectEqual(@as(f32, -1), tracks[0].duration);
}

test "junk and unknown keys are ignored" {
    const text =
        \\[playlist]
        \\NumberOfEntries=1
        \\Version=2
        \\FileNotANumber=skip.mp3
        \\File0=zero-is-invalid.mp3
        \\Length1=abc
        \\File1=good.mp3
        \\no equals sign here
    ;
    const tracks = try parse(testing.allocator, text);
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqualStrings("good.mp3", tracks[0].path);
    try testing.expectEqual(@as(f32, -1), tracks[0].duration);
}

test "empty input" {
    const tracks = try parse(testing.allocator, "");
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 0), tracks.len);
}

test "a large sparse index does not explode" {
    const tracks = try parse(testing.allocator, "[playlist]\nFile3000=far.mp3\n");
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqualStrings("far.mp3", tracks[0].path);
}

test "write then read round-trips" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, &.{
        .{ .path = "/m/a.mp3", .title = "Ay", .duration = 100.6 },
        .{ .path = "/m/b.mp3", .title = "Bee", .duration = -1 },
    });

    const tracks = try parse(testing.allocator, w.buffered());
    defer testing.allocator.free(tracks);
    try testing.expectEqual(@as(usize, 2), tracks.len);
    try testing.expectEqualStrings("/m/a.mp3", tracks[0].path);
    try testing.expectEqualStrings("Ay", tracks[0].title.?);
    try testing.expectApproxEqAbs(@as(f32, 101), tracks[0].duration, 0.01);
    try testing.expectEqual(@as(f32, -1), tracks[1].duration);
}
