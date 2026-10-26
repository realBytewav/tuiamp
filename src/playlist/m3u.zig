//! M3U / M3U8 reading and writing.
//!
//! The reader is an allocation-free iterator over a byte buffer: every path
//! and title it yields is a slice into that buffer, so the caller keeps the
//! bytes alive for as long as it is reading. That makes it trivially testable
//! on string literals.
//!
//! M3U in the wild is loose — CRLF or LF, a BOM or not, `#EXTINF` present or
//! absent, blank lines, Windows paths, comments we have never seen. Anything
//! unrecognized is skipped rather than treated as an error, because refusing
//! to open a playlist over one odd line is never the useful behaviour.

const std = @import("std");

pub const Track = struct {
    /// Slice into the source bytes. May be relative; see `resolve`.
    path: []const u8,
    /// From `#EXTINF`, when present.
    title: ?[]const u8 = null,
    /// Seconds from `#EXTINF`, or -1 when unknown.
    duration: f32 = -1,
};

pub const Iterator = struct {
    bytes: []const u8,
    pos: usize = 0,
    /// Carried from an `#EXTINF` line to the path line that follows it.
    pending_title: ?[]const u8 = null,
    pending_duration: f32 = -1,

    pub fn init(bytes: []const u8) Iterator {
        // A UTF-8 BOM would otherwise become part of the first path.
        const bom = "\xef\xbb\xbf";
        const start: usize = if (std.mem.startsWith(u8, bytes, bom)) bom.len else 0;
        return .{ .bytes = bytes, .pos = start };
    }

    pub fn next(it: *Iterator) ?Track {
        while (it.nextLine()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (line.len == 0) continue;

            if (line[0] == '#') {
                if (std.ascii.startsWithIgnoreCase(line, "#EXTINF:")) {
                    it.parseExtinf(line["#EXTINF:".len..]);
                }
                // #EXTM3U and every other directive carry nothing we need.
                continue;
            }

            const track: Track = .{
                .path = line,
                .title = it.pending_title,
                .duration = it.pending_duration,
            };
            it.pending_title = null;
            it.pending_duration = -1;
            return track;
        }
        return null;
    }

    /// `#EXTINF:<seconds>[ extra],<title>` — the seconds field sometimes
    /// carries trailing attributes, and the title may itself contain commas,
    /// so split on the first comma only.
    fn parseExtinf(it: *Iterator, rest: []const u8) void {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const secs_field = std.mem.trim(u8, rest[0 .. comma orelse rest.len], " \t");
        // Stop at the first character that cannot be part of the number.
        var end: usize = 0;
        while (end < secs_field.len) : (end += 1) {
            const c = secs_field[end];
            if (!(std.ascii.isDigit(c) or c == '-' or c == '+' or c == '.')) break;
        }
        it.pending_duration = std.fmt.parseFloat(f32, secs_field[0..end]) catch -1;
        if (it.pending_duration < 0) it.pending_duration = -1;

        if (comma) |c| {
            const title = std.mem.trim(u8, rest[c + 1 ..], " \t");
            it.pending_title = if (title.len > 0) title else null;
        }
    }

    fn nextLine(it: *Iterator) ?[]const u8 {
        if (it.pos >= it.bytes.len) return null;
        const start = it.pos;
        const nl = std.mem.indexOfScalarPos(u8, it.bytes, start, '\n') orelse {
            it.pos = it.bytes.len;
            return it.bytes[start..];
        };
        it.pos = nl + 1;
        return it.bytes[start..nl];
    }
};

/// Turn a possibly-relative playlist entry into a path we can open, relative
/// to the directory the playlist itself lives in. Caller owns the result.
pub fn resolve(
    gpa: std.mem.Allocator,
    playlist_dir: []const u8,
    entry: []const u8,
) ![]u8 {
    if (entry.len == 0) return gpa.dupe(u8, entry);
    if (entry[0] == '/') return gpa.dupe(u8, entry);
    // A URL is not a path; hand it back untouched so the caller can reject it.
    if (std.mem.indexOf(u8, entry, "://") != null) return gpa.dupe(u8, entry);

    // Playlists written on Windows use backslashes.
    const normalized = try gpa.dupe(u8, entry);
    defer gpa.free(normalized);
    for (normalized) |*c| if (c.* == '\\') {
        c.* = '/';
    };

    if (playlist_dir.len == 0) return gpa.dupe(u8, normalized);
    return std.fs.path.join(gpa, &.{ playlist_dir, normalized });
}

pub fn isPlaylistPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".m3u") or
        std.ascii.eqlIgnoreCase(ext, ".m3u8") or
        std.ascii.eqlIgnoreCase(ext, ".pls");
}

pub const WriteEntry = struct {
    path: []const u8,
    title: []const u8,
    /// Negative for unknown, which M3U spells as -1.
    duration: f32 = -1,
};

/// Write an extended M3U. Paths go out as given, so absolute paths in means
/// a playlist that still resolves after it is moved.
pub fn write(w: *std.Io.Writer, entries: []const WriteEntry) !void {
    try w.writeAll("#EXTM3U\n");
    for (entries) |e| {
        const secs: i64 = if (e.duration >= 0) @intFromFloat(@round(e.duration)) else -1;
        try w.print("#EXTINF:{d},{s}\n{s}\n", .{ secs, e.title, e.path });
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn collect(bytes: []const u8, out: *std.ArrayList(Track)) !void {
    var it: Iterator = .init(bytes);
    while (it.next()) |t| try out.append(testing.allocator, t);
}

test "extended m3u with durations and titles" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);

    try collect(
        \\#EXTM3U
        \\#EXTINF:147,Nobuo Uematsu - Dancing Mad
        \\/music/RemixTavern/Dancing Mad.mp3
        \\#EXTINF:-1,Unknown Length
        \\relative/path.mp3
        \\
    , &tracks);

    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    try testing.expectEqualStrings("/music/RemixTavern/Dancing Mad.mp3", tracks.items[0].path);
    try testing.expectEqualStrings("Nobuo Uematsu - Dancing Mad", tracks.items[0].title.?);
    try testing.expectApproxEqAbs(@as(f32, 147), tracks.items[0].duration, 0.01);

    try testing.expectEqualStrings("relative/path.mp3", tracks.items[1].path);
    try testing.expectEqualStrings("Unknown Length", tracks.items[1].title.?);
    try testing.expectEqual(@as(f32, -1), tracks.items[1].duration);
}

test "plain m3u with no directives at all" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect("a.mp3\nb.mp3\nc.mp3", &tracks);
    try testing.expectEqual(@as(usize, 3), tracks.items.len);
    try testing.expectEqualStrings("c.mp3", tracks.items[2].path);
    try testing.expectEqual(@as(?[]const u8, null), tracks.items[0].title);
}

test "CRLF, BOM, blank lines and stray comments" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect(
        "\xef\xbb\xbf#EXTM3U\r\n\r\n#EXTINF:10,One\r\none.mp3\r\n" ++
            "# just a comment\r\n#PLAYLIST:Mine\r\ntwo.mp3\r\n",
        &tracks,
    );
    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    try testing.expectEqualStrings("one.mp3", tracks.items[0].path);
    try testing.expectEqualStrings("One", tracks.items[0].title.?);
    // The comment must not have leaked into track two's metadata.
    try testing.expectEqual(@as(?[]const u8, null), tracks.items[1].title);
    try testing.expectEqualStrings("two.mp3", tracks.items[1].path);
}

test "titles containing commas survive" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect("#EXTINF:90,Artist - Song, Part II, Reprise\nx.mp3\n", &tracks);
    try testing.expectEqualStrings("Artist - Song, Part II, Reprise", tracks.items[0].title.?);
}

test "malformed EXTINF does not lose the track" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect(
        "#EXTINF:\nno-duration.mp3\n" ++
            "#EXTINF:abc,Bad Number\nbad.mp3\n" ++
            "#EXTINF:120\nno-comma.mp3\n",
        &tracks,
    );
    try testing.expectEqual(@as(usize, 3), tracks.items.len);
    try testing.expectEqual(@as(f32, -1), tracks.items[0].duration);
    try testing.expectEqual(@as(f32, -1), tracks.items[1].duration);
    try testing.expectEqualStrings("Bad Number", tracks.items[1].title.?);
    // A duration with no comma still yields the duration.
    try testing.expectApproxEqAbs(@as(f32, 120), tracks.items[2].duration, 0.01);
}

test "EXTINF attributes after the seconds field are tolerated" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect("#EXTINF:235 tvg-id=\"x\",Title Here\nz.mp3\n", &tracks);
    try testing.expectApproxEqAbs(@as(f32, 235), tracks.items[0].duration, 0.01);
    try testing.expectEqualStrings("Title Here", tracks.items[0].title.?);
}

test "empty input yields nothing" {
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect("", &tracks);
    try collect("\n\n\n", &tracks);
    try collect("#EXTM3U\n", &tracks);
    try testing.expectEqual(@as(usize, 0), tracks.items.len);
}

test "resolve handles absolute, relative, Windows and URL entries" {
    const gpa = testing.allocator;

    const abs = try resolve(gpa, "/playlists", "/music/a.mp3");
    defer gpa.free(abs);
    try testing.expectEqualStrings("/music/a.mp3", abs);

    const rel = try resolve(gpa, "/playlists", "sub/a.mp3");
    defer gpa.free(rel);
    try testing.expectEqualStrings("/playlists/sub/a.mp3", rel);

    const win = try resolve(gpa, "/playlists", "sub\\dir\\a.mp3");
    defer gpa.free(win);
    try testing.expectEqualStrings("/playlists/sub/dir/a.mp3", win);

    const url = try resolve(gpa, "/playlists", "http://example.com/s.mp3");
    defer gpa.free(url);
    try testing.expectEqualStrings("http://example.com/s.mp3", url);

    const no_dir = try resolve(gpa, "", "a.mp3");
    defer gpa.free(no_dir);
    try testing.expectEqualStrings("a.mp3", no_dir);
}

test "write then read round-trips" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, &.{
        .{ .path = "/m/one.mp3", .title = "One", .duration = 147.4 },
        .{ .path = "/m/two, live.mp3", .title = "Two, Live", .duration = -1 },
    });
    const text = w.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "#EXTM3U\n"));

    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(testing.allocator);
    try collect(text, &tracks);

    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    try testing.expectEqualStrings("/m/one.mp3", tracks.items[0].path);
    try testing.expectEqualStrings("One", tracks.items[0].title.?);
    // 147.4 rounds to the nearest second on the way out.
    try testing.expectApproxEqAbs(@as(f32, 147), tracks.items[0].duration, 0.01);
    try testing.expectEqualStrings("/m/two, live.mp3", tracks.items[1].path);
    try testing.expectEqualStrings("Two, Live", tracks.items[1].title.?);
    try testing.expectEqual(@as(f32, -1), tracks.items[1].duration);
}

test "isPlaylistPath" {
    try testing.expect(isPlaylistPath("a.m3u"));
    try testing.expect(isPlaylistPath("a.M3U8"));
    try testing.expect(isPlaylistPath("/x/y.pls"));
    try testing.expect(!isPlaylistPath("a.mp3"));
    try testing.expect(!isPlaylistPath("a"));
}
