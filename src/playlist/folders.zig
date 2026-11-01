//! The playlist, grouped by the folder each track came from.
//!
//! This is a *view*, and it never reorders anything. A group is a run of
//! consecutive entries sharing a parent directory, so the order you see in
//! folder mode is exactly the order you see in flat mode, and a folder that
//! appears twice in the playlist appears twice here. Winamp keeps the visual
//! order of the playlist fixed and shuffles behind it; grouping by unique
//! directory instead would have broken that promise for the sake of a
//! tidier-looking list.
//!
//! The cost of the feature is that a row is no longer an entry. Everything
//! the window does — cursor, scroll, the scrollbar thumb, hit-testing —
//! works in row space while the playlist model stays in entry space, and
//! `rowOf` / `entryAt` are the only way across. A collapsed folder's tracks
//! have no row at all.
//!
//! Collapse state is keyed on the directory rather than on a group index,
//! so adding a track or removing one does not silently expand everything
//! the user had folded away.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = @import("list.zig").List;

pub const Row = union(enum) {
    /// Index into `groups`.
    folder: usize,
    /// Index into the list's entries.
    track: usize,
};

pub const Group = struct {
    /// Owned. The full directory, which is what collapse state is keyed on.
    dir: []const u8,
    /// Where the part of `dir` that identifies this folder begins: the
    /// prefix every group shares is not worth a third of the row.
    label_start: usize,
    /// First entry of the run, and how many entries it covers.
    first: usize,
    count: usize,
    /// Sum of the durations that are known, and whether any were not. A
    /// freshly scanned playlist knows them all; one loaded from an m3u
    /// without `#EXTINF` lengths knows none.
    duration: f32,
    partial: bool,
    collapsed: bool,

    /// What to draw. Falls back to the last component when this group *is*
    /// the shared prefix, which happens when one folder holds another.
    pub fn label(g: Group) []const u8 {
        const rest = std.mem.trimStart(u8, g.dir[@min(g.label_start, g.dir.len)..], "/");
        if (rest.len > 0) return rest;
        return std.fs.path.basename(g.dir);
    }

    pub fn contains(g: Group, entry: usize) bool {
        return entry >= g.first and entry < g.first + g.count;
    }
};

/// The parent directory of a path, as the grouping sees it. A bare filename
/// has no directory, and all such entries belong together.
fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

pub const Folders = struct {
    gpa: Allocator,
    groups: std.ArrayList(Group) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// Directories the user has folded away. Owned, because the groups they
    /// refer to are rebuilt from under them.
    folded: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator) Folders {
        return .{ .gpa = gpa };
    }

    pub fn deinit(f: *Folders) void {
        for (f.groups.items) |g| f.gpa.free(g.dir);
        for (f.folded.items) |d| f.gpa.free(d);
        f.groups.deinit(f.gpa);
        f.rows.deinit(f.gpa);
        f.folded.deinit(f.gpa);
        f.* = undefined;
    }

    /// Visible rows, which is what the window counts in.
    pub fn len(f: *const Folders) usize {
        return f.rows.items.len;
    }

    /// Entries covered by the groups, which is the whole list unless the
    /// grouping has gone stale under an edit.
    pub fn trackCount(f: *const Folders) usize {
        var n: usize = 0;
        for (f.groups.items) |g| n += g.count;
        return n;
    }

    pub fn rowAt(f: *const Folders, row: usize) ?Row {
        if (row >= f.rows.items.len) return null;
        return f.rows.items[row];
    }

    /// The entry on `row`, or null when it holds a folder header.
    pub fn entryAt(f: *const Folders, row: usize) ?usize {
        return switch (f.rowAt(row) orelse return null) {
            .track => |i| i,
            .folder => null,
        };
    }

    /// The row showing `entry`, or null while its folder is collapsed.
    pub fn rowOf(f: *const Folders, entry: usize) ?usize {
        for (f.rows.items, 0..) |r, row| {
            switch (r) {
                .track => |i| if (i == entry) return row,
                .folder => {},
            }
        }
        return null;
    }

    /// The group `entry` belongs to, collapsed or not.
    pub fn groupOf(f: *const Folders, entry: usize) ?usize {
        for (f.groups.items, 0..) |g, i| {
            if (g.contains(entry)) return i;
        }
        return null;
    }

    /// The row of the header for `group`.
    pub fn headerRow(f: *const Folders, group: usize) ?usize {
        for (f.rows.items, 0..) |r, row| {
            switch (r) {
                .folder => |i| if (i == group) return row,
                .track => {},
            }
        }
        return null;
    }

    /// Re-derive the groups and rows from `list`. Cheap enough to run on any
    /// change — it is one pass over the entries plus one over the groups —
    /// and the alternative is tracking which edits can invalidate what.
    pub fn rebuild(f: *Folders, list: *const List) Allocator.Error!void {
        for (f.groups.items) |g| f.gpa.free(g.dir);
        f.groups.clearRetainingCapacity();
        f.rows.clearRetainingCapacity();

        for (list.entries.items, 0..) |entry, i| {
            const dir = dirOf(entry.path);
            const tail: ?*Group = if (f.groups.items.len == 0)
                null
            else
                &f.groups.items[f.groups.items.len - 1];

            if (tail) |g| {
                if (std.mem.eql(u8, g.dir, dir)) {
                    g.count += 1;
                    if (entry.hasDuration()) g.duration += entry.duration else g.partial = true;
                    continue;
                }
            }

            const owned = try f.gpa.dupe(u8, dir);
            errdefer f.gpa.free(owned);
            try f.groups.append(f.gpa, .{
                .dir = owned,
                .label_start = 0,
                .first = i,
                .count = 1,
                .duration = if (entry.hasDuration()) entry.duration else 0,
                .partial = !entry.hasDuration(),
                .collapsed = f.isFolded(dir),
            });
        }

        f.applyCommonPrefix();
        try f.buildRows();
    }

    /// Trim the prefix every group shares, so the labels say what differs.
    fn applyCommonPrefix(f: *Folders) void {
        if (f.groups.items.len == 0) return;
        var shared: usize = f.groups.items[0].dir.len;
        for (f.groups.items[1..]) |g| {
            shared = @min(shared, sharedComponents(f.groups.items[0].dir, g.dir));
        }
        // One group has nothing to differ from, so its own basename is the
        // only sensible label; `Group.label` falls back to that.
        if (f.groups.items.len == 1) shared = f.groups.items[0].dir.len;
        for (f.groups.items) |*g| g.label_start = shared;
    }

    fn buildRows(f: *Folders) Allocator.Error!void {
        for (f.groups.items, 0..) |g, gi| {
            try f.rows.append(f.gpa, .{ .folder = gi });
            if (g.collapsed) continue;
            var i = g.first;
            while (i < g.first + g.count) : (i += 1) {
                try f.rows.append(f.gpa, .{ .track = i });
            }
        }
    }

    pub fn isFolded(f: *const Folders, dir: []const u8) bool {
        for (f.folded.items) |d| {
            if (std.mem.eql(u8, d, dir)) return true;
        }
        return false;
    }

    /// Fold or unfold one group. Rebuilds the rows, so any row index held
    /// across this call is stale.
    pub fn setCollapsed(
        f: *Folders,
        list: *const List,
        group: usize,
        collapsed: bool,
    ) Allocator.Error!void {
        if (group >= f.groups.items.len) return;
        try f.setFolded(f.groups.items[group].dir, collapsed);
        try f.rebuild(list);
    }

    pub fn toggle(f: *Folders, list: *const List, group: usize) Allocator.Error!void {
        if (group >= f.groups.items.len) return;
        try f.setCollapsed(list, group, !f.groups.items[group].collapsed);
    }

    pub fn setAll(f: *Folders, list: *const List, collapsed: bool) Allocator.Error!void {
        if (!collapsed) {
            for (f.folded.items) |d| f.gpa.free(d);
            f.folded.clearRetainingCapacity();
        } else {
            for (f.groups.items) |g| try f.setFolded(g.dir, true);
        }
        try f.rebuild(list);
    }

    fn setFolded(f: *Folders, dir: []const u8, folded: bool) Allocator.Error!void {
        for (f.folded.items, 0..) |d, i| {
            if (!std.mem.eql(u8, d, dir)) continue;
            if (!folded) {
                f.gpa.free(f.folded.swapRemove(i));
            }
            return;
        }
        if (folded) try f.folded.append(f.gpa, try f.gpa.dupe(u8, dir));
    }
};

/// How many bytes of `a` are a whole-component prefix of `b` as well. Paths
/// are compared by component so that `/music/Low` and `/music/Lowlands`
/// share `/music` rather than `/music/Low`.
fn sharedComponents(a: []const u8, b: []const u8) usize {
    var agreed: usize = 0;
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {
        if (a[i] == '/') agreed = i;
    }
    // One ran out: that is a full match if the other is at a boundary.
    if (i == a.len and (i == b.len or b[i] == '/')) return i;
    if (i == b.len and (i == a.len or a[i] == '/')) return i;
    return agreed;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn testList(gpa: Allocator, paths: []const []const u8) !List {
    var l: List = .init(gpa, 1);
    errdefer l.deinit();
    for (paths) |p| try l.append(p, std.fs.path.basename(p), 60);
    return l;
}

test "groups are runs of consecutive entries in the same directory" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{
        "/m/Bowie/Low/01.mp3",
        "/m/Bowie/Low/02.mp3",
        "/m/Eno/AGW/01.mp3",
        // Back to the first folder: a run, not a set, so this is its own
        // group rather than being merged with the one above.
        "/m/Bowie/Low/03.mp3",
    });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    try testing.expectEqual(@as(usize, 3), f.groups.items.len);
    try testing.expectEqual(@as(usize, 2), f.groups.items[0].count);
    try testing.expectEqual(@as(usize, 1), f.groups.items[1].count);
    try testing.expectEqual(@as(usize, 3), f.groups.items[2].first);

    // Every entry appears exactly once, in the list's own order.
    try testing.expectEqual(@as(usize, 4 + 3), f.len());
    var seen: usize = 0;
    var last: usize = 0;
    for (f.rows.items) |r| switch (r) {
        .track => |i| {
            try testing.expect(seen == 0 or i > last);
            last = i;
            seen += 1;
        },
        .folder => {},
    };
    try testing.expectEqual(@as(usize, 4), seen);
}

test "labels drop the prefix every folder shares" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{
        "/mnt/1T/Music/Bowie/Low/01.mp3",
        "/mnt/1T/Music/Eno/Another Green World/01.mp3",
    });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    try testing.expectEqualStrings("Bowie/Low", f.groups.items[0].label());
    try testing.expectEqualStrings("Eno/Another Green World", f.groups.items[1].label());
}

test "one folder is labelled by its own name" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{ "/mnt/1T/Music/Bowie/Low/01.mp3", "/mnt/1T/Music/Bowie/Low/02.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 1), f.groups.items.len);
    try testing.expectEqualStrings("Low", f.groups.items[0].label());
}

test "a folder that holds another is still labelled" {
    const gpa = testing.allocator;
    // The shared prefix is the first folder itself, so there is nothing left
    // of it to use as a label.
    var l = try testList(gpa, &.{ "/m/Set/01.mp3", "/m/Set/Disc 2/01.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try testing.expectEqualStrings("Set", f.groups.items[0].label());
    try testing.expectEqualStrings("Disc 2", f.groups.items[1].label());
}

test "collapsing hides a folder's tracks and nothing else's" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{
        "/m/A/01.mp3",
        "/m/A/02.mp3",
        "/m/B/01.mp3",
    });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 5), f.len());

    try f.toggle(&l, 0);
    // Two headers and B's single track.
    try testing.expectEqual(@as(usize, 3), f.len());
    try testing.expect(f.rowOf(0) == null);
    try testing.expect(f.rowOf(1) == null);
    try testing.expect(f.rowOf(2) != null);
    // The entries are still there; only their rows went away.
    try testing.expectEqual(@as(usize, 3), l.len());

    try f.toggle(&l, 0);
    try testing.expectEqual(@as(usize, 5), f.len());
    try testing.expect(f.rowOf(0) != null);
}

test "collapse state survives the list changing under it" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{ "/m/A/01.mp3", "/m/B/01.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try f.toggle(&l, 1); // fold B

    // Appending to A puts a third run on the end, because A's entries are no
    // longer consecutive once B sits between them. The fold must stay on B
    // rather than sliding onto whichever group now holds index 1, which is
    // exactly why the state is keyed on the directory.
    try l.append("/m/A/02.mp3", "02", 60);
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 3), f.groups.items.len);
    try testing.expect(!f.groups.items[0].collapsed);
    try testing.expect(f.groups.items[1].collapsed);
    try testing.expect(!f.groups.items[2].collapsed);

    // And another folder on the end leaves it where it is.
    try l.append("/m/C/01.mp3", "01", 60);
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 4), f.groups.items.len);
    try testing.expect(f.groups.items[1].collapsed);
    try testing.expect(!f.groups.items[3].collapsed);
}

test "folding a folder folds every run of it" {
    const gpa = testing.allocator;
    // Keyed on the directory, so a folder the playlist visits twice folds in
    // both places. One fold per folder is the honest reading of "fold this
    // folder", and it keeps the state independent of how the runs fall.
    var l = try testList(gpa, &.{ "/m/A/01.mp3", "/m/B/01.mp3", "/m/A/02.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 3), f.groups.items.len);

    try f.toggle(&l, 0);
    try testing.expect(f.groups.items[0].collapsed);
    try testing.expect(f.groups.items[2].collapsed);
    try testing.expect(!f.groups.items[1].collapsed);
    // Three headers and B's one track.
    try testing.expectEqual(@as(usize, 4), f.len());
}

test "setAll folds and unfolds everything" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{ "/m/A/01.mp3", "/m/B/01.mp3", "/m/C/01.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    try f.setAll(&l, true);
    try testing.expectEqual(@as(usize, 3), f.len());
    for (f.groups.items) |g| try testing.expect(g.collapsed);

    try f.setAll(&l, false);
    try testing.expectEqual(@as(usize, 6), f.len());
    for (f.groups.items) |g| try testing.expect(!g.collapsed);
}

test "row and entry spaces map both ways" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{ "/m/A/01.mp3", "/m/A/02.mp3", "/m/B/01.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    // rows: 0 header A, 1 track 0, 2 track 1, 3 header B, 4 track 2
    try testing.expectEqual(@as(?usize, 0), f.entryAt(1));
    try testing.expectEqual(@as(?usize, 1), f.entryAt(2));
    try testing.expectEqual(@as(?usize, 2), f.entryAt(4));
    try testing.expect(f.entryAt(0) == null);
    try testing.expect(f.entryAt(3) == null);
    try testing.expect(f.entryAt(99) == null);

    for ([_]usize{ 0, 1, 2 }) |entry| {
        const row = f.rowOf(entry).?;
        try testing.expectEqual(@as(?usize, entry), f.entryAt(row));
    }

    try testing.expectEqual(@as(?usize, 0), f.groupOf(0));
    try testing.expectEqual(@as(?usize, 0), f.groupOf(1));
    try testing.expectEqual(@as(?usize, 1), f.groupOf(2));
    try testing.expect(f.groupOf(99) == null);

    try testing.expectEqual(@as(?usize, 0), f.headerRow(0));
    try testing.expectEqual(@as(?usize, 3), f.headerRow(1));
    try testing.expect(f.headerRow(9) == null);
}

test "durations sum per folder, and say when they are incomplete" {
    const gpa = testing.allocator;
    var l: List = .init(gpa, 1);
    defer l.deinit();
    try l.append("/m/A/01.mp3", "01", 60);
    try l.append("/m/A/02.mp3", "02", 90);
    try l.append("/m/B/01.mp3", "01", -1);

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    try testing.expectEqual(@as(f32, 150), f.groups.items[0].duration);
    try testing.expect(!f.groups.items[0].partial);
    try testing.expectEqual(@as(f32, 0), f.groups.items[1].duration);
    try testing.expect(f.groups.items[1].partial);
}

test "an empty playlist has no groups and no rows" {
    const gpa = testing.allocator;
    var l: List = .init(gpa, 1);
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);

    try testing.expectEqual(@as(usize, 0), f.len());
    try testing.expectEqual(@as(usize, 0), f.groups.items.len);
    try testing.expect(f.rowAt(0) == null);
    try testing.expect(f.rowOf(0) == null);
    // Toggling what is not there is not a crash.
    try f.toggle(&l, 0);
    try f.setAll(&l, true);
}

test "entries with no directory group together" {
    const gpa = testing.allocator;
    var l = try testList(gpa, &.{ "01.mp3", "02.mp3" });
    defer l.deinit();

    var f: Folders = .init(gpa);
    defer f.deinit();
    try f.rebuild(&l);
    try testing.expectEqual(@as(usize, 1), f.groups.items.len);
    try testing.expectEqualStrings(".", f.groups.items[0].dir);
}

test "sharedComponents stops on component boundaries" {
    try testing.expectEqual(@as(usize, 2), sharedComponents("/m/Low", "/m/Lowlands"));
    try testing.expectEqual(@as(usize, 4), sharedComponents("/m/A", "/m/A/B"));
    try testing.expectEqual(@as(usize, 4), sharedComponents("/m/A/B", "/m/A"));
    try testing.expectEqual(@as(usize, 0), sharedComponents("/a", "/b"));
    try testing.expectEqual(@as(usize, 6), sharedComponents("/m/A/B", "/m/A/B"));
    try testing.expectEqual(@as(usize, 0), sharedComponents("", "/m"));
}
