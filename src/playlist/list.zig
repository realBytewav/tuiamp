//! The playlist: entries, ordering, shuffle and repeat.
//!
//! Winamp keeps the visual order of the playlist fixed and shuffles the
//! *play order* behind it, so turning shuffle on does not rearrange what you
//! are looking at. That is modelled here as a permutation (`order`) over the
//! entry list, with `order_pos` marking where in that permutation playback
//! currently is.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// Owned by the list.
    path: []const u8,
    /// Owned by the list. Display text; the filename until tags are read.
    title: []const u8,
    /// Seconds, or -1 when not yet known.
    duration: f32 = -1,

    pub fn hasDuration(e: Entry) bool {
        return e.duration >= 0;
    }
};

pub const Repeat = enum { off, all, one };

pub const List = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Play order as indices into `entries`. Identity unless shuffling.
    order: std.ArrayList(usize) = .empty,
    /// Position within `order`, meaningful only when `entries` is non-empty.
    order_pos: usize = 0,
    shuffle: bool = false,
    repeat: Repeat = .off,
    /// Row the user has highlighted, which is independent of what is playing.
    cursor: usize = 0,
    prng: std.Random.DefaultPrng,

    pub fn init(gpa: Allocator, seed: u64) List {
        return .{ .gpa = gpa, .prng = .init(seed) };
    }

    pub fn deinit(l: *List) void {
        l.clear();
        l.entries.deinit(l.gpa);
        l.order.deinit(l.gpa);
        l.* = undefined;
    }

    pub fn len(l: *const List) usize {
        return l.entries.items.len;
    }

    pub fn isEmpty(l: *const List) bool {
        return l.entries.items.len == 0;
    }

    /// The entry currently selected for playback, if any.
    pub fn currentIndex(l: *const List) ?usize {
        if (l.isEmpty()) return null;
        if (l.order_pos >= l.order.items.len) return null;
        return l.order.items[l.order_pos];
    }

    pub fn current(l: *const List) ?Entry {
        return l.entries.items[l.currentIndex() orelse return null];
    }

    pub fn append(l: *List, path: []const u8, title: []const u8, duration: f32) !void {
        const p = try l.gpa.dupe(u8, path);
        errdefer l.gpa.free(p);
        const t = try l.gpa.dupe(u8, title);
        errdefer l.gpa.free(t);

        try l.entries.append(l.gpa, .{ .path = p, .title = t, .duration = duration });
        errdefer _ = l.entries.pop();

        // New entries go at the end of the play order too. When shuffling,
        // splice them into the part of the permutation not yet played, so a
        // mid-session add can still come up.
        if (l.shuffle and l.order.items.len > l.order_pos + 1) {
            const span = l.order.items.len - (l.order_pos + 1);
            const at = l.order_pos + 1 + l.prng.random().uintLessThan(usize, span + 1);
            try l.order.insert(l.gpa, at, l.entries.items.len - 1);
        } else {
            try l.order.append(l.gpa, l.entries.items.len - 1);
        }
    }

    pub fn clear(l: *List) void {
        for (l.entries.items) |e| {
            l.gpa.free(e.path);
            l.gpa.free(e.title);
        }
        l.entries.clearRetainingCapacity();
        l.order.clearRetainingCapacity();
        l.order_pos = 0;
        l.cursor = 0;
    }

    pub fn remove(l: *List, index: usize) void {
        if (index >= l.entries.items.len) return;

        // What is playing has to survive the renumbering, so remember it as
        // an entry index rather than an order position.
        const playing = l.currentIndex();

        const e = l.entries.orderedRemove(index);
        l.gpa.free(e.path);
        l.gpa.free(e.title);

        // Drop it from the order and shift every later index down one.
        var i: usize = 0;
        while (i < l.order.items.len) {
            const v = l.order.items[i];
            if (v == index) {
                _ = l.order.orderedRemove(i);
                continue;
            }
            if (v > index) l.order.items[i] = v - 1;
            i += 1;
        }

        const target: ?usize = if (playing) |pl| blk: {
            if (pl == index) break :blk null; // the playing entry is gone
            break :blk if (pl > index) pl - 1 else pl;
        } else null;

        if (target) |t| {
            l.order_pos = indexOf(l.order.items, t) orelse 0;
        } else {
            l.order_pos = @min(l.order_pos, l.order.items.len -| 1);
        }

        l.cursor = @min(l.cursor, l.entries.items.len -| 1);
    }

    /// Move the entry at `from` so that it sits at `to`, shifting the rest.
    pub fn move(l: *List, from: usize, to: usize) void {
        const n = l.entries.items.len;
        if (from >= n or to >= n or from == to) return;

        const playing = l.currentIndex();

        const e = l.entries.orderedRemove(from);
        l.entries.insert(l.gpa, to, e) catch {
            // Reinsertion into a list that just shrank cannot fail to find
            // capacity, but if it somehow did the entry would leak, so put it
            // back where it came from.
            l.entries.insert(l.gpa, from, e) catch {};
            return;
        };

        for (l.order.items) |*v| v.* = remap(v.*, from, to);
        if (playing) |pl| {
            l.order_pos = indexOf(l.order.items, remap(pl, from, to)) orelse l.order_pos;
        }
        l.cursor = remap(l.cursor, from, to);
    }

    /// Advance to the next entry and return it. Null means playback is over.
    pub fn advance(l: *List) ?usize {
        if (l.isEmpty()) return null;
        if (l.repeat == .one) return l.currentIndex();

        if (l.order_pos + 1 < l.order.items.len) {
            l.order_pos += 1;
            return l.currentIndex();
        }

        if (l.repeat == .all) {
            // A fresh permutation each time round, so repeated listening does
            // not replay the same shuffled sequence.
            if (l.shuffle) l.reshuffle(.from_start);
            l.order_pos = 0;
            return l.currentIndex();
        }
        return null;
    }

    pub fn retreat(l: *List) ?usize {
        if (l.isEmpty()) return null;
        if (l.repeat == .one) return l.currentIndex();

        if (l.order_pos > 0) {
            l.order_pos -= 1;
        } else if (l.repeat == .all) {
            l.order_pos = l.order.items.len - 1;
        } else {
            return null;
        }
        return l.currentIndex();
    }

    /// Play a specific entry, keeping the shuffle permutation intact.
    pub fn jumpTo(l: *List, index: usize) ?usize {
        if (index >= l.entries.items.len) return null;
        l.order_pos = indexOf(l.order.items, index) orelse return null;
        return index;
    }

    pub const Reshuffle = enum {
        /// Permute everything; play order starts from the beginning.
        from_start,
        /// Keep what is playing as the current position and permute the rest,
        /// so toggling shuffle never interrupts the current track.
        keep_current,
    };

    pub fn setShuffle(l: *List, on: bool) void {
        if (l.shuffle == on) return;
        l.shuffle = on;
        if (on) {
            l.reshuffle(.keep_current);
        } else {
            const playing = l.currentIndex();
            l.identityOrder();
            l.order_pos = playing orelse 0;
        }
    }

    pub fn reshuffle(l: *List, mode: Reshuffle) void {
        const playing = if (mode == .keep_current) l.currentIndex() else null;

        l.identityOrder();
        l.prng.random().shuffle(usize, l.order.items);

        if (playing) |pl| {
            // Swap the playing entry to the front and treat it as position 0.
            const at = indexOf(l.order.items, pl).?;
            std.mem.swap(usize, &l.order.items[0], &l.order.items[at]);
            l.order_pos = 0;
        } else {
            l.order_pos = 0;
        }
    }

    fn identityOrder(l: *List) void {
        l.order.clearRetainingCapacity();
        // Capacity was reserved as entries were appended, so this cannot fail
        // in practice; falling back to a shorter order would still be sound.
        l.order.ensureTotalCapacity(l.gpa, l.entries.items.len) catch {};
        for (0..l.entries.items.len) |i| l.order.appendAssumeCapacity(i);
    }

    /// Sum of known durations. Unknown ones contribute nothing, so the total
    /// is a lower bound until every entry has been probed.
    pub fn totalDuration(l: *const List) f32 {
        var total: f32 = 0;
        for (l.entries.items) |e| if (e.hasDuration()) {
            total += e.duration;
        };
        return total;
    }

    pub fn setDuration(l: *List, index: usize, secs: f32) void {
        if (index < l.entries.items.len) l.entries.items[index].duration = secs;
    }

    pub fn setTitle(l: *List, index: usize, title: []const u8) !void {
        if (index >= l.entries.items.len) return;
        const t = try l.gpa.dupe(u8, title);
        l.gpa.free(l.entries.items[index].title);
        l.entries.items[index].title = t;
    }

    pub fn sortByTitle(l: *List) void {
        l.reorderPreservingPlayback(struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a.title, b.title);
            }
        }.lessThan);
    }

    pub fn sortByPath(l: *List) void {
        l.reorderPreservingPlayback(struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
    }

    pub fn reverse(l: *List) void {
        const playing = l.currentIndex();
        std.mem.reverse(Entry, l.entries.items);
        const n = l.entries.items.len;
        l.restoreOrder(if (playing) |pl| n - 1 - pl else null);
    }

    fn reorderPreservingPlayback(
        l: *List,
        comptime lessThan: fn (void, Entry, Entry) bool,
    ) void {
        const playing_path: ?[]const u8 = if (l.current()) |e| e.path else null;
        std.mem.sort(Entry, l.entries.items, {}, lessThan);

        var new_playing: ?usize = null;
        if (playing_path) |p| {
            for (l.entries.items, 0..) |e, i| if (e.path.ptr == p.ptr) {
                new_playing = i;
                break;
            };
        }
        l.restoreOrder(new_playing);
    }

    /// Rebuild the play order after the entries have been permuted wholesale.
    fn restoreOrder(l: *List, new_playing: ?usize) void {
        if (l.shuffle) {
            l.identityOrder();
            l.prng.random().shuffle(usize, l.order.items);
            if (new_playing) |pl| {
                const at = indexOf(l.order.items, pl).?;
                std.mem.swap(usize, &l.order.items[0], &l.order.items[at]);
            }
            l.order_pos = 0;
        } else {
            l.identityOrder();
            l.order_pos = new_playing orelse 0;
        }
        l.cursor = @min(l.cursor, l.entries.items.len -| 1);
    }
};

fn indexOf(haystack: []const usize, needle: usize) ?usize {
    for (haystack, 0..) |v, i| if (v == needle) return i;
    return null;
}

/// Where index `v` ends up after the entry at `from` is moved to `to`.
fn remap(v: usize, from: usize, to: usize) usize {
    if (v == from) return to;
    if (from < to) {
        return if (v > from and v <= to) v - 1 else v;
    }
    return if (v >= to and v < from) v + 1 else v;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeList(n: usize) !List {
    var l = List.init(testing.allocator, 0x1234);
    errdefer l.deinit();
    var buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = try std.fmt.bufPrint(&buf, "track{d}", .{i});
        try l.append(name, name, @floatFromInt(60 + i));
    }
    return l;
}

/// Every entry index must appear in the play order exactly once, always.
fn expectValidOrder(l: *const List) !void {
    try testing.expectEqual(l.entries.items.len, l.order.items.len);
    var seen = try testing.allocator.alloc(bool, l.entries.items.len);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    for (l.order.items) |v| {
        try testing.expect(v < seen.len);
        try testing.expect(!seen[v]);
        seen[v] = true;
    }
}

test "append, current and total duration" {
    var l = try makeList(3);
    defer l.deinit();

    try testing.expectEqual(@as(usize, 3), l.len());
    try testing.expectEqualStrings("track0", l.current().?.title);
    // 60 + 61 + 62
    try testing.expectApproxEqAbs(@as(f32, 183), l.totalDuration(), 0.01);
    try expectValidOrder(&l);
}

test "unknown durations are excluded from the total" {
    var l = List.init(testing.allocator, 1);
    defer l.deinit();
    try l.append("a", "a", 30);
    try l.append("b", "b", -1);
    try testing.expectApproxEqAbs(@as(f32, 30), l.totalDuration(), 0.01);
}

test "sequential advance stops at the end unless repeating" {
    var l = try makeList(3);
    defer l.deinit();

    try testing.expectEqual(@as(?usize, 1), l.advance());
    try testing.expectEqual(@as(?usize, 2), l.advance());
    try testing.expectEqual(@as(?usize, null), l.advance());
    // A refused advance leaves the position where it was.
    try testing.expectEqual(@as(?usize, 2), l.currentIndex());

    l.repeat = .all;
    try testing.expectEqual(@as(?usize, 0), l.advance());
}

test "repeat one stays put in both directions" {
    var l = try makeList(3);
    defer l.deinit();
    _ = l.advance();
    l.repeat = .one;
    try testing.expectEqual(@as(?usize, 1), l.advance());
    try testing.expectEqual(@as(?usize, 1), l.retreat());
}

test "retreat wraps only when repeating all" {
    var l = try makeList(3);
    defer l.deinit();
    try testing.expectEqual(@as(?usize, null), l.retreat());
    l.repeat = .all;
    try testing.expectEqual(@as(?usize, 2), l.retreat());
}

test "empty list has nothing to play" {
    var l = List.init(testing.allocator, 7);
    defer l.deinit();
    try testing.expectEqual(@as(?usize, null), l.currentIndex());
    try testing.expectEqual(@as(?usize, null), l.advance());
    try testing.expectEqual(@as(?usize, null), l.retreat());
    try testing.expectEqual(@as(?usize, null), l.jumpTo(0));
    l.remove(0); // must not panic
    l.move(0, 1);
    l.setShuffle(true);
    try expectValidOrder(&l);
}

test "shuffle is a valid permutation and keeps the current track playing" {
    var l = try makeList(12);
    defer l.deinit();
    _ = l.advance();
    _ = l.advance();
    const before = l.currentIndex().?;

    l.setShuffle(true);
    try expectValidOrder(&l);
    // Toggling shuffle must not change what is playing right now.
    try testing.expectEqual(before, l.currentIndex().?);

    // Walking the whole permutation visits every entry exactly once.
    var seen = [_]bool{false} ** 12;
    seen[l.currentIndex().?] = true;
    var count: usize = 1;
    while (l.advance()) |i| {
        try testing.expect(!seen[i]);
        seen[i] = true;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 12), count);

    // And turning it off restores sequential order from the current track.
    l.setShuffle(false);
    try expectValidOrder(&l);
    try testing.expectEqual(l.order_pos, l.currentIndex().?);
}

test "removing the playing entry and others keeps the order consistent" {
    var l = try makeList(5);
    defer l.deinit();
    _ = l.advance();
    _ = l.advance(); // playing track2

    l.remove(0); // earlier entry: playing track must follow its new index
    try expectValidOrder(&l);
    try testing.expectEqualStrings("track2", l.current().?.title);

    l.remove(l.currentIndex().?); // the playing entry itself
    try expectValidOrder(&l);
    try testing.expect(l.currentIndex() != null);

    // Remove everything; nothing should panic and the order stays valid.
    while (!l.isEmpty()) {
        l.remove(0);
        try expectValidOrder(&l);
    }
    try testing.expectEqual(@as(?usize, null), l.currentIndex());
}

test "remove past the end is ignored" {
    var l = try makeList(2);
    defer l.deinit();
    l.remove(99);
    try testing.expectEqual(@as(usize, 2), l.len());
}

test "move keeps the playing track and the cursor on the same entries" {
    var l = try makeList(5);
    defer l.deinit();
    _ = l.advance(); // playing track1
    l.cursor = 3;

    l.move(1, 4); // the playing entry moves to the end
    try expectValidOrder(&l);
    try testing.expectEqualStrings("track1", l.current().?.title);
    // The highlight follows its own entry rather than staying on row 3.
    try testing.expectEqual(@as(usize, 2), l.cursor);
    try testing.expectEqualStrings("track3", l.entries.items[l.cursor].title);

    l.move(4, 0); // and back to the front
    try expectValidOrder(&l);
    try testing.expectEqualStrings("track1", l.current().?.title);
}

test "remap matches an actual move for every index pair" {
    const n = 6;
    var from: usize = 0;
    while (from < n) : (from += 1) {
        var to: usize = 0;
        while (to < n) : (to += 1) {
            var l = try makeList(n);
            defer l.deinit();

            // Record identities, apply the move, then check remap predicted
            // where each one landed.
            var names: [n][]const u8 = undefined;
            for (l.entries.items, 0..) |e, i| names[i] = e.title;

            l.move(from, to);
            if (from == to) continue;
            for (names, 0..) |name, i| {
                const predicted = remap(i, from, to);
                try testing.expectEqualStrings(name, l.entries.items[predicted].title);
            }
        }
    }
}

test "jumpTo selects an entry without disturbing the permutation" {
    var l = try makeList(8);
    defer l.deinit();
    l.setShuffle(true);
    const order_before = try testing.allocator.dupe(usize, l.order.items);
    defer testing.allocator.free(order_before);

    try testing.expectEqual(@as(?usize, 5), l.jumpTo(5));
    try testing.expectEqual(@as(usize, 5), l.currentIndex().?);
    try testing.expectEqualSlices(usize, order_before, l.order.items);
    try testing.expectEqual(@as(?usize, null), l.jumpTo(99));
}

test "sorting preserves what is playing" {
    var l = List.init(testing.allocator, 3);
    defer l.deinit();
    try l.append("/m/c.mp3", "Charlie", 10);
    try l.append("/m/a.mp3", "alpha", 20);
    try l.append("/m/b.mp3", "Bravo", 30);

    _ = l.jumpTo(0); // playing Charlie
    l.sortByTitle();
    try expectValidOrder(&l);
    try testing.expectEqualStrings("alpha", l.entries.items[0].title);
    try testing.expectEqualStrings("Bravo", l.entries.items[1].title);
    try testing.expectEqualStrings("Charlie", l.entries.items[2].title);
    try testing.expectEqualStrings("Charlie", l.current().?.title);

    l.sortByPath();
    try testing.expectEqualStrings("/m/a.mp3", l.entries.items[0].path);
    try testing.expectEqualStrings("Charlie", l.current().?.title);

    l.reverse();
    try expectValidOrder(&l);
    try testing.expectEqualStrings("/m/c.mp3", l.entries.items[0].path);
    try testing.expectEqualStrings("Charlie", l.current().?.title);
}

test "appending while shuffling keeps a valid permutation" {
    var l = try makeList(4);
    defer l.deinit();
    l.setShuffle(true);
    _ = l.advance();

    for (0..6) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "added{d}", .{i});
        try l.append(name, name, 42);
        try expectValidOrder(&l);
    }

    // Everything from the current position onward is still reachable, and
    // reached exactly once. The first entry was consumed before the appends,
    // so 9 of the 10 remain.
    var seen = [_]bool{false} ** 10;
    seen[l.currentIndex().?] = true;
    var count: usize = 1;
    while (l.advance()) |i| {
        try testing.expect(!seen[i]);
        seen[i] = true;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 9), count);
    try testing.expectEqual(@as(usize, 10), l.len());
}

test "setTitle replaces owned memory without leaking" {
    var l = try makeList(2);
    defer l.deinit();
    try l.setTitle(0, "A Much Longer Title Than Before");
    try testing.expectEqualStrings("A Much Longer Title Than Before", l.entries.items[0].title);
    try l.setTitle(99, "ignored");
}
