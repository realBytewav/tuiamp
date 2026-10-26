//! Turning a path into playlist entries.
//!
//! One entry point, `addPath`, handles the three things a user can hand a
//! player: a track, a directory, or a playlist file. Winamp's "add file",
//! "add directory" and "open playlist" all collapse into it.
//!
//! Titles and durations are read from each file's tags as it is added. That
//! costs one small read per file rather than a decoder instance, so a few
//! thousand tracks stay fast, and the playlist is useful the moment it
//! appears instead of filling in only as tracks happen to play.
//!
//! Playlist files are the exception: when an `#EXTINF` line already supplies
//! a title and a length, that is taken at its word and the file is not
//! touched. The playlist author's intent wins, and an unmounted drive does
//! not stall the load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const List = @import("list.zig").List;
const m3u = @import("m3u.zig");
const pls = @import("pls.zig");
const tags_mod = @import("../meta/tags.zig");

/// What miniaudio's built-in decoders can actually play.
pub const audio_extensions = [_][]const u8{ ".mp3", ".flac", ".wav" };

/// Playlists can nest; refuse to follow them forever.
const max_playlist_depth = 4;
/// A playlist file bigger than this is not a playlist.
const max_playlist_bytes = 16 << 20;

pub fn isAudioPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (audio_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// The only failure that is not recoverable: a path we cannot read is skipped
/// rather than aborting the whole add, so nothing else propagates.
pub const AddError = Allocator.Error;

/// Add whatever `path` denotes. Returns the number of entries appended.
pub fn addPath(l: *List, io: Io, path: []const u8) AddError!usize {
    return addPathDepth(l, io, path, 0);
}

fn addPathDepth(l: *List, io: Io, path: []const u8, depth: u8) AddError!usize {
    const cwd: Io.Dir = .cwd();
    const stat = cwd.statFile(io, path, .{}) catch return 0;

    if (stat.kind == .directory) return addDirectory(l, io, path, depth);
    if (m3u.isPlaylistPath(path)) return addPlaylist(l, io, path, depth);
    if (!isAudioPath(path)) return 0;

    try appendTagged(l, io, path, null, -1);
    return 1;
}

/// Append one track, reading its tags for anything not already known.
fn appendTagged(
    l: *List,
    io: Io,
    path: []const u8,
    known_title: ?[]const u8,
    known_duration: f32,
) AddError!void {
    if (known_title != null and known_duration >= 0) {
        try l.append(path, known_title.?, known_duration);
        return;
    }

    var tags = tags_mod.read(l.gpa, io, path);
    defer tags.deinit(l.gpa);

    const title = if (known_title) |t|
        try l.gpa.dupe(u8, t)
    else
        try tags.displayTitle(l.gpa, path);
    defer l.gpa.free(title);

    const duration = if (known_duration >= 0) known_duration else tags.duration;
    try l.append(path, title, duration);
}

/// Every audio file under `root`, in sorted path order. The walk order from
/// the filesystem is undefined, and for music that matters: sorting by path
/// is what keeps an album in track order.
fn addDirectory(l: *List, io: Io, root: []const u8, depth: u8) AddError!usize {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |p| l.gpa.free(p);
        found.deinit(l.gpa);
    }

    var walker = try dir.walk(l.gpa);
    defer walker.deinit();

    var nested: std.ArrayList([]u8) = .empty;
    defer {
        for (nested.items) |p| l.gpa.free(p);
        nested.deinit(l.gpa);
    }

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(l.gpa, &.{ root, entry.path });
        if (isAudioPath(entry.path)) {
            try found.append(l.gpa, full);
        } else if (m3u.isPlaylistPath(entry.path)) {
            try nested.append(l.gpa, full);
        } else {
            l.gpa.free(full);
        }
    }

    std.mem.sort([]u8, found.items, {}, lessThanPath);
    var count: usize = 0;
    for (found.items) |p| {
        try appendTagged(l, io, p, null, -1);
        count += 1;
    }

    // A playlist sitting inside a scanned directory is followed too, which is
    // how a folder of albums plus an "everything.m3u" behaves sensibly.
    std.mem.sort([]u8, nested.items, {}, lessThanPath);
    for (nested.items) |p| count += try addPlaylist(l, io, p, depth);
    return count;
}

fn lessThanPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn addPlaylist(l: *List, io: Io, path: []const u8, depth: u8) AddError!usize {
    if (depth >= max_playlist_depth) return 0;

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, l.gpa, .limited(max_playlist_bytes)) catch
        return 0;
    defer l.gpa.free(bytes);

    // Entries are relative to the playlist's own directory, not the cwd.
    const dir = std.fs.path.dirname(path) orelse "";
    var count: usize = 0;

    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".pls")) {
        const tracks = pls.parse(l.gpa, bytes) catch return 0;
        defer l.gpa.free(tracks);
        for (tracks) |t| count += try addTrack(l, io, dir, t, depth);
    } else {
        var it: m3u.Iterator = .init(bytes);
        while (it.next()) |t| count += try addTrack(l, io, dir, t, depth);
    }
    return count;
}

/// Entries from a playlist are added whether or not the file is there right
/// now. Silently dropping them would quietly rewrite someone's playlist the
/// first time a drive was unmounted, which is worse than showing a row that
/// fails to play. Directory scans are different: they can only add what they
/// actually found.
fn addTrack(l: *List, io: Io, dir: []const u8, t: m3u.Track, depth: u8) AddError!usize {
    const resolved = try m3u.resolve(l.gpa, dir, t.path);
    defer l.gpa.free(resolved);

    // Remote streams are not playable yet; silently skipping them beats
    // filling the playlist with entries that will only ever error.
    if (std.mem.indexOf(u8, resolved, "://") != null) return 0;

    if (m3u.isPlaylistPath(resolved)) {
        return addPlaylist(l, io, resolved, depth + 1);
    }
    if (!isAudioPath(resolved)) return 0;

    try appendTagged(l, io, resolved, t.title, t.duration);
    return 1;
}

/// Write the list out as an extended M3U.
pub fn saveM3u(l: *const List, io: Io, path: []const u8) !void {
    var entries: std.ArrayList(m3u.WriteEntry) = .empty;
    defer entries.deinit(l.gpa);
    for (l.entries.items) |e| {
        try entries.append(l.gpa, .{
            .path = e.path,
            .title = e.title,
            .duration = e.duration,
        });
    }

    var out: std.Io.Writer.Allocating = .init(l.gpa);
    defer out.deinit();
    try m3u.write(&out.writer, entries.items);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "isAudioPath" {
    try testing.expect(isAudioPath("a.mp3"));
    try testing.expect(isAudioPath("/x/y/B.FLAC"));
    try testing.expect(isAudioPath("c.Wav"));
    try testing.expect(!isAudioPath("cover.jpg"));
    try testing.expect(!isAudioPath("a.m3u"));
    try testing.expect(!isAudioPath("noext"));
    try testing.expect(!isAudioPath(""));
    // A dotfile is not an extensionless match for anything.
    try testing.expect(!isAudioPath(".mp3"));
}

/// Build a throwaway tree under the test tmp dir and return its real path.
const Fixture = struct {
    tmp: testing.TmpDir,
    /// Sentinel-terminated, because that is what `realPathFileAlloc` returns
    /// and freeing it as a plain slice would mismatch the allocation size.
    root: [:0]u8,

    fn init(io: Io, gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{ .sub_path = "b-second.mp3", .data = "x" });
        try tmp.dir.writeFile(io, .{ .sub_path = "a-first.mp3", .data = "x" });
        try tmp.dir.writeFile(io, .{ .sub_path = "cover.jpg", .data = "x" });
        try tmp.dir.createDirPath(io, "album");
        try tmp.dir.writeFile(io, .{ .sub_path = "album/02.flac", .data = "x" });
        try tmp.dir.writeFile(io, .{ .sub_path = "album/01.flac", .data = "x" });

        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        gpa.free(f.root);
        f.tmp.cleanup();
    }

    fn pathTo(f: *const Fixture, gpa: Allocator, sub: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ f.root, sub });
    }
};

test "adding a single file, and ignoring non-audio" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    var l = List.init(gpa, 1);
    defer l.deinit();

    const track = try f.pathTo(gpa, "a-first.mp3");
    defer gpa.free(track);
    try testing.expectEqual(@as(usize, 1), try addPath(&l, io, track));
    try testing.expectEqualStrings("a-first", l.entries.items[0].title);

    const art = try f.pathTo(gpa, "cover.jpg");
    defer gpa.free(art);
    try testing.expectEqual(@as(usize, 0), try addPath(&l, io, art));
    try testing.expectEqual(@as(usize, 1), l.len());
}

test "adding a directory recurses and sorts by path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    var l = List.init(gpa, 1);
    defer l.deinit();

    const n = try addPath(&l, io, f.root);
    try testing.expectEqual(@as(usize, 4), n);

    // Sorted by full path, which is what keeps an album in track order and
    // groups artist/album directories together. Files and subdirectories at
    // the same level interleave alphabetically: "a-first" < "album/" < "b-".
    try testing.expectEqualStrings("a-first", l.entries.items[0].title);
    try testing.expectEqualStrings("01", l.entries.items[1].title);
    try testing.expectEqualStrings("02", l.entries.items[2].title);
    try testing.expectEqualStrings("b-second", l.entries.items[3].title);
}

test "missing paths are skipped rather than failing the whole add" {
    const io = testing.io;
    var l = List.init(testing.allocator, 1);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), try addPath(&l, io, "/definitely/not/here.mp3"));
    try testing.expect(l.isEmpty());
}

test "m3u with relative entries resolves against the playlist's directory" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    try f.tmp.dir.writeFile(io, .{
        .sub_path = "mix.m3u",
        .data = "#EXTM3U\n#EXTINF:42,Custom Title\nalbum/01.flac\nb-second.mp3\nmissing.mp3\n",
    });

    var l = List.init(gpa, 1);
    defer l.deinit();

    const playlist = try f.pathTo(gpa, "mix.m3u");
    defer gpa.free(playlist);
    const n = try addPath(&l, io, playlist);

    // All three are kept, in playlist order, including the one whose file is
    // not there — see the note on addTrack.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Custom Title", l.entries.items[0].title);
    try testing.expectApproxEqAbs(@as(f32, 42), l.entries.items[0].duration, 0.01);
    try testing.expect(std.mem.endsWith(u8, l.entries.items[0].path, "album/01.flac"));
    // No EXTINF, so the title falls back to the filename.
    try testing.expectEqualStrings("b-second", l.entries.items[1].title);
    try testing.expectEqualStrings("missing", l.entries.items[2].title);
}

test "pls playlists load too" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    try f.tmp.dir.writeFile(io, .{
        .sub_path = "mix.pls",
        .data = "[playlist]\nFile1=a-first.mp3\nTitle1=Aye\nLength1=11\nNumberOfEntries=1\n",
    });

    var l = List.init(gpa, 1);
    defer l.deinit();
    const playlist = try f.pathTo(gpa, "mix.pls");
    defer gpa.free(playlist);

    try testing.expectEqual(@as(usize, 1), try addPath(&l, io, playlist));
    try testing.expectEqualStrings("Aye", l.entries.items[0].title);
}

test "remote stream entries are skipped" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    try f.tmp.dir.writeFile(io, .{
        .sub_path = "radio.m3u",
        .data = "http://example.com/stream\na-first.mp3\n",
    });

    var l = List.init(gpa, 1);
    defer l.deinit();
    const playlist = try f.pathTo(gpa, "radio.m3u");
    defer gpa.free(playlist);
    try testing.expectEqual(@as(usize, 1), try addPath(&l, io, playlist));
}

test "a playlist that includes itself terminates" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    try f.tmp.dir.writeFile(io, .{
        .sub_path = "loop.m3u",
        .data = "loop.m3u\na-first.mp3\n",
    });

    var l = List.init(gpa, 1);
    defer l.deinit();
    const playlist = try f.pathTo(gpa, "loop.m3u");
    defer gpa.free(playlist);

    // Bounded by max_playlist_depth: the self-reference is followed a few
    // times and then stops, so the real track appears once per level rather
    // than hanging.
    const n = try addPath(&l, io, playlist);
    try testing.expect(n >= 1);
    try testing.expect(n <= max_playlist_depth + 1);
}

test "saveM3u round-trips a list" {
    const io = testing.io;
    const gpa = testing.allocator;
    var f = try Fixture.init(io, gpa);
    defer f.deinit(gpa);

    var l = List.init(gpa, 1);
    defer l.deinit();
    _ = try addPath(&l, io, f.root);
    try testing.expectEqual(@as(usize, 4), l.len());
    l.setDuration(0, 123);

    const saved = try f.pathTo(gpa, "out.m3u");
    defer gpa.free(saved);
    try saveM3u(&l, io, saved);

    var reloaded = List.init(gpa, 1);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 4), try addPath(&reloaded, io, saved));

    for (l.entries.items, reloaded.entries.items) |a, b| {
        try testing.expectEqualStrings(a.path, b.path);
        try testing.expectEqualStrings(a.title, b.title);
    }
    try testing.expectApproxEqAbs(@as(f32, 123), reloaded.entries.items[0].duration, 0.01);
}
