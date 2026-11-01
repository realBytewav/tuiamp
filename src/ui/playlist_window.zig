//! Winamp's playlist editor.
//!
//! This is the one window Winamp lets you resize, and the same is true here:
//! it keeps the main window's width so the stack lines up, but its height is
//! whatever the terminal can spare.
//!
//! Two independent positions matter and are easy to conflate: `cursor` is the
//! row the user has highlighted, and the *current* entry is what is playing.
//! Winamp draws them differently and they move independently.
//!
//! The scrollbar lives in the window's own right-hand border rather than in a
//! column of its own, which is where Winamp put it too: a 1,457-track
//! playlist needs to show you where you are, and it should not cost a
//! character of title to do it.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("theme.zig").Theme;
const fmt = @import("fmt.zig");
const marquee_mod = @import("widgets/marquee.zig");
const list_mod = @import("../playlist/list.zig");
const List = list_mod.List;
const folders_mod = @import("../playlist/folders.zig");
const Folders = folders_mod.Folders;

/// Chrome: top border, bottom border, and the status row above it.
pub const chrome_rows: u16 = 3;
pub const min_height: u16 = chrome_rows + 1;
pub const default_rows: u16 = 10;

pub const Hit = union(enum) {
    none,
    titlebar,
    shade,
    close,
    /// The titlebar's folder toggle: flat list, or grouped by folder.
    folders,
    /// A visible row, as an index into the entry list.
    row: usize,
    /// Below the last entry: clicking there deselects rather than selecting
    /// whatever happens to be last.
    empty,
    status,
    /// The scrollbar, carrying the scroll position the click asks for. Only
    /// produced while the bar is actually drawn.
    scrollbar: usize,
};

pub const Layout = struct {
    frame: Rect,
    titlebar: Rect,
    folders_btn: Rect,
    shade_btn: Rect,
    close_btn: Rect,
    /// The scrolling entry area.
    rows: Rect,
    /// The right-hand border alongside `rows`, doubling as the scrollbar.
    scrollbar: Rect,
    status: Rect,

    pub fn compute(w: u16, h: u16) Layout {
        const body_h = h -| chrome_rows;
        return .{
            .frame = .{ .x = 0, .y = 0, .w = w, .h = h },
            .titlebar = .{ .x = 0, .y = 0, .w = w, .h = 1 },
            // Spaced as the main window spaces its own three, so the row of
            // buttons lines up across the stack.
            .folders_btn = .{ .x = w -| 8, .y = 0, .w = 1, .h = 1 },
            .shade_btn = .{ .x = w -| 6, .y = 0, .w = 1, .h = 1 },
            .close_btn = .{ .x = w -| 4, .y = 0, .w = 1, .h = 1 },
            .rows = .{ .x = 1, .y = 1, .w = w -| 2, .h = body_h },
            .scrollbar = .{ .x = w -| 1, .y = 1, .w = @min(w, 1), .h = body_h },
            .status = .{ .x = 1, .y = 1 + body_h, .w = w -| 2, .h = 1 },
        };
    }

    /// Visible entry rows.
    pub fn capacity(l: Layout) u16 {
        return l.rows.h;
    }

    pub fn hitTest(l: Layout, p: Point, scroll: usize, count: usize) Hit {
        if (l.close_btn.contains(p)) return .close;
        if (l.shade_btn.contains(p)) return .shade;
        if (l.folders_btn.contains(p)) return .folders;
        if (l.titlebar.contains(p)) return .titlebar;
        if (l.scrollbar.localize(p)) |q| {
            // A click on the plain border of a playlist that fits is not a
            // scroll request, because there is no bar there to grab.
            if (thumbSpan(0, count, l.capacity(), l.scrollbar.h) == null) return .none;
            return .{ .scrollbar = scrollForThumbTop(q.y, count, l.capacity(), l.scrollbar.h) };
        }
        if (l.status.contains(p)) return .status;
        if (l.rows.localize(p)) |q| {
            const index = scroll + q.y;
            return if (index < count) .{ .row = index } else .empty;
        }
        return .none;
    }
};

pub const View = struct {
    theme: Theme,
    focused: bool = false,
    /// First visible row.
    scroll: usize = 0,
    /// The highlighted row. In flat mode a row is an entry and this is the
    /// list's own cursor; in folder mode it may be a folder header, which no
    /// entry index can name, so the window is told rather than deducing it.
    cursor_row: usize = 0,
    /// Set to group the entries by folder. The grouping is a view over the
    /// same list, rebuilt by the caller; the window only reads it.
    folders: ?*const Folders = null,
};

/// Hold `scroll` inside the range that leaves no blank rows below the last
/// entry while entries exist above it.
pub fn clampScroll(scroll: usize, count: usize, capacity: u16) usize {
    if (capacity == 0 or count == 0) return 0;
    return @min(scroll, count -| @as(usize, capacity));
}

/// Keep `scroll` such that `cursor` is visible, moving it as little as
/// possible. Returns the adjusted scroll.
pub fn scrollToShow(scroll: usize, cursor: usize, count: usize, capacity: u16) usize {
    if (capacity == 0 or count == 0) return 0;
    const cap: usize = capacity;

    const max_scroll = count -| cap;
    var s = @min(scroll, max_scroll);
    if (cursor < s) {
        s = cursor;
    } else if (cursor >= s + cap) {
        s = cursor - cap + 1;
    }
    return @min(s, max_scroll);
}

/// Where the thumb sits in a `track_h`-row trough.
pub const Thumb = struct { start: u16, len: u16 };

/// The thumb for `scroll`, or null when every entry already fits and there is
/// nothing to show. Mutual inverse of `scrollForThumbTop`, so grabbing the
/// thumb and dragging it tracks the pointer instead of jumping — the same
/// property `Slider.thumbCol` and `Slider.valueAt` hold for the seek bar.
pub fn thumbSpan(scroll: usize, count: usize, capacity: u16, track_h: u16) ?Thumb {
    if (track_h == 0 or capacity == 0 or count <= capacity) return null;

    // Proportional to the fraction on screen, but never shorter than a row:
    // a 10,000-track playlist still needs a thumb you can see and grab.
    const proportional = @round(ratio(track_h, capacity, count));
    const len: u16 = @min(track_h, @max(1, @as(u16, @intFromFloat(proportional))));
    const travel = track_h - len;
    const max_scroll = count - capacity;
    if (travel == 0 or max_scroll == 0) return .{ .start = 0, .len = len };

    const start: u16 = @intFromFloat(@round(ratio(travel, @min(scroll, max_scroll), max_scroll)));
    return .{ .start = @min(start, travel), .len = len };
}

/// The scroll position that puts the thumb's top at row `row` of the trough.
/// Used for a click in the trough and for every frame of a drag.
pub fn scrollForThumbTop(row: u16, count: usize, capacity: u16, track_h: u16) usize {
    const thumb = thumbSpan(0, count, capacity, track_h) orelse return 0;
    const travel = track_h - thumb.len;
    if (travel == 0) return 0;
    const max_scroll = count - capacity;
    const scroll: usize = @intFromFloat(@round(ratio(max_scroll, @min(row, travel), travel)));
    return @min(scroll, max_scroll);
}

/// `span * numerator / denominator` in floating point, which is how the
/// sliders scale their travel too.
fn ratio(span: usize, numerator: usize, denominator: usize) f32 {
    const d: f32 = @floatFromInt(denominator);
    if (d == 0) return 0;
    const s: f32 = @floatFromInt(span);
    const n: f32 = @floatFromInt(numerator);
    return s * n / d;
}

pub fn draw(p: Painter, l: Layout, v: View, list: *const List) void {
    const th = v.theme;

    p.fill(.{ .bg = .{ .rgb = th.bg } });
    drawFrame(p, l, v);

    const rows = p.sub(l.rows);
    if (v.folders) |f| {
        drawGrouped(rows, l, v, list, f);
    } else {
        drawFlat(rows, l, v, list);
    }

    drawScrollbar(p, l, v, rowCount(v, list));
    drawStatus(p, l, v, list);
}

/// Rows on offer, which is entries in flat mode and visible rows in folder
/// mode. The scrollbar and the hit-testing both count in these.
pub fn rowCount(v: View, list: *const List) usize {
    return if (v.folders) |f| f.len() else list.len();
}

fn drawFlat(rows: Painter, l: Layout, v: View, list: *const List) void {
    const count = list.len();
    const current = list.currentIndex();

    // The index column is as wide as the largest number it has to show, so a
    // 1000-track playlist does not shove the titles sideways by a character
    // every time it crosses a power of ten. Width is the x=0 gutter, the
    // digits, the dot and one space.
    const num_w: u16 = @intCast(1 + digits(count) + 2);
    var row: u16 = 0;
    while (row < l.rows.h) : (row += 1) {
        const index = v.scroll + row;
        if (index >= count) break;
        drawEntryRow(rows, l, v, .{
            .row = row,
            .entry = list.entries.items[index],
            .number = index + 1,
            .num_w = num_w,
            .selected = index == v.cursor_row,
            .playing = current != null and index == current.?,
        });
    }
}

fn drawGrouped(rows: Painter, l: Layout, v: View, list: *const List, f: *const Folders) void {
    const current = list.currentIndex();

    // Numbers run within their folder, so the column is as wide as the
    // biggest folder rather than as the whole playlist.
    var biggest: usize = 1;
    for (f.groups.items) |g| biggest = @max(biggest, g.count);
    const num_w: u16 = @intCast(fold_indent + digits(biggest) + 2);

    var row: u16 = 0;
    while (row < l.rows.h) : (row += 1) {
        const index = v.scroll + row;
        switch (f.rowAt(index) orelse break) {
            .folder => |gi| drawFolderRow(rows, l, v, f.groups.items[gi], .{
                .row = row,
                .selected = index == v.cursor_row,
                // A folded folder has to say that the playing track is in
                // there somewhere, or `j` looks like it did nothing.
                .playing = current != null and f.groups.items[gi].contains(current.?),
            }),
            .track => |entry| drawEntryRow(rows, l, v, .{
                .row = row,
                .entry = list.entries.items[entry],
                .number = entry - groupFirst(f, entry) + 1,
                .num_w = num_w,
                .selected = index == v.cursor_row,
                .playing = current != null and entry == current.?,
                .indent = fold_indent,
            }),
        }
    }
}

/// Indent on a track under its folder header.
const fold_indent: u16 = 2;

fn groupFirst(f: *const Folders, entry: usize) usize {
    const gi = f.groupOf(entry) orelse return 0;
    return f.groups.items[gi].first;
}

/// How a row is marked out: the cursor sits on it, it is playing, or neither.
fn rowStyle(th: Theme, v: View, selected: bool, playing: bool) Style {
    if (selected and v.focused) {
        return .{ .fg = .{ .rgb = th.list_sel_fg }, .bg = .{ .rgb = th.list_sel_bg } };
    }
    if (playing) return th.onBg(th.list_current);
    if (selected) return th.onBg(th.text_bright);
    return th.onBg(th.text);
}

const EntryRow = struct {
    row: u16,
    entry: list_mod.Entry,
    /// What to print in the index column, one-based.
    number: usize,
    num_w: u16,
    selected: bool,
    playing: bool,
    indent: u16 = 0,
};

fn drawEntryRow(rows: Painter, l: Layout, v: View, r: EntryRow) void {
    const th = v.theme;
    const g = th.glyphs;
    const style = rowStyle(th, v, r.selected, r.playing);

    // Selected rows are filled edge to edge so the highlight reads as a
    // bar rather than as coloured text.
    rows.fillRect(.{ .x = 0, .y = r.row, .w = l.rows.w, .h = 1 }, ' ', style);

    // Right-aligned, so the dots line up down the column whatever the
    // playlist's length.
    var nbuf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&nbuf, "{d}.", .{r.number}) catch "";
    const num_x = if (r.num_w > num.len + 1) r.num_w - @as(u16, @intCast(num.len)) - 1 else 1;
    _ = rows.text(num_x, r.row, num, style);

    var dbuf: [16]u8 = undefined;
    const dur = fmt.duration(&dbuf, r.entry.duration);
    const dur_w: u16 = @intCast(dur.len);

    // Title gets whatever is left between the number and the duration.
    const title_x = r.num_w;
    const reserved = title_x + dur_w + 2;
    if (l.rows.w > reserved) {
        const avail = l.rows.w - reserved;
        const title_cols = marquee_mod.displayWidth(r.entry.title);
        if (title_cols <= avail) {
            _ = rows.text(title_x, r.row, r.entry.title, style);
        } else {
            drawEllipsized(rows, title_x, r.row, avail, r.entry.title, style);
        }
    }
    _ = rows.text(l.rows.w - dur_w - 1, r.row, dur, style);

    if (r.playing) {
        // A marker in the gutter, so the playing track is identifiable
        // even when the cursor highlight is sitting on top of it. Column
        // zero in both modes: the folder indent shifts the number, and
        // putting the marker in there instead would land it on the digits.
        _ = rows.text(0, r.row, g.now_playing, style);
    }
}

const FolderRow = struct {
    row: u16,
    selected: bool,
    playing: bool,
};

fn drawFolderRow(rows: Painter, l: Layout, v: View, group: folders_mod.Group, r: FolderRow) void {
    const th = v.theme;
    const g = th.glyphs;
    const style = rowStyle(th, v, r.selected, r.playing);
    const bright: Style = if (r.selected and v.focused) style else th.onBg(th.text_bright);

    rows.fillRect(.{ .x = 0, .y = r.row, .w = l.rows.w, .h = 1 }, ' ', style);

    var marker: [4]u8 = undefined;
    const cp: u21 = if (group.collapsed) g.fold_closed else g.fold_open;
    const n = std.unicode.utf8Encode(cp, &marker) catch 0;
    _ = rows.text(0, r.row, marker[0..n], bright);
    // A folded folder holding the playing track says so by colour alone:
    // the one free column is the gap before the label, and a second
    // triangle next to the fold marker would read as part of it.

    // The track count and the folder's running time, right-aligned, with the
    // playlist's own "+" for a sum that is still missing a length.
    var tail_buf: [40]u8 = undefined;
    var dbuf: [20]u8 = undefined;
    // Knowing none of the lengths is a dash, as it is on a track; knowing
    // some of them is a lower bound.
    var total = fmt.duration(
        dbuf[0 .. dbuf.len - 1],
        if (group.partial and group.duration == 0) -1 else group.duration,
    );
    if (group.partial and group.duration > 0) {
        dbuf[total.len] = '+';
        total = dbuf[0 .. total.len + 1];
    }
    const tail = std.fmt.bufPrint(&tail_buf, "{d}  {s}", .{ group.count, total }) catch "";
    const tail_w: u16 = @intCast(tail.len);

    const label_x: u16 = 2;
    const reserved = label_x + tail_w + 2;
    if (l.rows.w > reserved) {
        const avail = l.rows.w - reserved;
        const label = group.label();
        if (marquee_mod.displayWidth(label) <= avail) {
            _ = rows.text(label_x, r.row, label, bright);
        } else {
            drawEllipsized(rows, label_x, r.row, avail, label, bright);
        }
        _ = rows.text(l.rows.w - tail_w - 1, r.row, tail, style);
    }
}

/// A thumb in the right-hand border, drawn only when the playlist overflows:
/// a bar that is always full length tells you nothing, and an empty trough on
/// a three-track playlist is just noise.
fn drawScrollbar(p: Painter, l: Layout, v: View, count: usize) void {
    const th = v.theme;
    const g = th.glyphs;
    const thumb = thumbSpan(v.scroll, count, l.capacity(), l.scrollbar.h) orelse return;

    const bar = p.sub(l.scrollbar);
    bar.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = l.scrollbar.h }, g.v, th.onBg(th.track));
    bar.fillRect(
        .{ .x = 0, .y = thumb.start, .w = 1, .h = thumb.len },
        g.thumb,
        th.onBg(if (v.focused) th.thumb else th.fill),
    );
}

/// Clip a title to `avail` columns, ending in an ellipsis so it is obvious
/// that something was cut.
fn drawEllipsized(p: Painter, x: u16, y: u16, avail: u16, text: []const u8, style: Style) void {
    if (avail == 0) return;
    if (avail <= 1) {
        _ = p.text(x, y, "\u{2026}", style);
        return;
    }
    var col: u16 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const w = screen.charWidth(cp);
        if (col + w > avail - 1) break;
        p.set(x + col, y, .{ .cp = cp, .style = style });
        if (w == 2) p.set(x + col + 1, y, .{ .cp = ' ', .style = style, .continuation = true });
        col += w;
    }
    p.set(x + col, y, .{ .cp = '\u{2026}', .style = style });
}

fn drawStatus(p: Painter, l: Layout, v: View, list: *const List) void {
    const th = v.theme;
    const g = th.glyphs;
    const status = p.sub(l.status);
    status.fill(th.onBg(th.text_dim));

    // A rule between the entries and the status line.
    p.hline(l.status.x, l.status.y -| 0, 0, g.h, th.onBg(th.frame));

    var buf: [64]u8 = undefined;
    const count = list.len();
    const left = if (v.folders) |f| std.fmt.bufPrint(&buf, "{d} folder{s}, {d} track{s}", .{
        f.groups.items.len,
        if (f.groups.items.len == 1) "" else "s",
        count,
        if (count == 1) "" else "s",
    }) catch "" else std.fmt.bufPrint(&buf, "{d} track{s}", .{
        count,
        if (count == 1) "" else "s",
    }) catch "";
    _ = status.text(1, 0, left, th.onBg(th.text_dim));

    // Durations are not known until a track has been probed, so a total
    // over a freshly-added playlist is a lower bound. Say so with a "+"
    // rather than presenting a partial sum as the real figure.
    var tbuf: [20]u8 = undefined;
    const total_secs = if (count == 0) 0 else list.totalDuration();
    var total = fmt.duration(tbuf[0 .. tbuf.len - 1], total_secs);
    if (count > 0 and unknownDurations(list) > 0) {
        tbuf[total.len] = '+';
        total = tbuf[0 .. total.len + 1];
    }
    if (l.status.w > total.len + 2) {
        _ = status.text(@intCast(l.status.w - total.len - 1), 0, total, th.onBg(th.text_dim));
    }

    // Shuffle and repeat read out here too, because the playlist is where
    // they take effect.
    const mid = std.fmt.bufPrint(&buf, "{s}{s}", .{
        if (list.shuffle) "shuffle " else "",
        switch (list.repeat) {
            .off => "",
            .all => "repeat",
            .one => "repeat-1",
        },
    }) catch "";
    if (mid.len > 0 and l.status.w > 30) {
        _ = status.text(l.status.w / 2 -| @as(u16, @intCast(mid.len / 2)), 0, mid, th.onBg(th.text));
    }
}

fn drawFrame(p: Painter, l: Layout, v: View) void {
    const th = v.theme;
    const g = th.glyphs;
    const fs = th.onBg(if (v.focused) th.frame_focus else th.frame);
    const w = l.frame.w;
    const h = l.frame.h;
    if (w < 2 or h < 2) return;

    p.set(0, 0, .{ .cp = g.tl, .style = fs });
    p.set(w - 1, 0, .{ .cp = g.tr, .style = fs });
    p.set(0, h - 1, .{ .cp = g.bl, .style = fs });
    p.set(w - 1, h - 1, .{ .cp = g.br, .style = fs });
    p.hline(1, 0, w - 2, g.h, fs);
    p.hline(1, h - 1, w - 2, g.h, fs);
    p.vline(0, 1, h - 2, g.v, fs);
    p.vline(w - 1, 1, h - 2, g.v, fs);

    _ = p.text(2, 0, " Playlist ", th.onBg(th.title_fg));
    // One block behind all three buttons, so they read as a group rather
    // than as three marks that happen to be near each other.
    p.fillRect(.{ .x = l.folders_btn.x -| 1, .y = 0, .w = 8, .h = 1 }, ' ', th.onBg(th.button));
    // Lit while the grouping is what is on screen, dim while it is not,
    // which is how the equalizer's toggles say the same thing.
    _ = p.text(l.folders_btn.x, 0, g.win_folders, th.onBg(
        if (v.folders != null) th.button_active else th.button,
    ));
    _ = p.text(l.shade_btn.x, 0, g.win_shade, th.onBg(th.button));
    _ = p.text(l.close_btn.x, 0, g.win_close, th.onBg(th.button));
}

fn unknownDurations(list: *const List) usize {
    var n: usize = 0;
    for (list.entries.items) |e| {
        if (!e.hasDuration()) n += 1;
    }
    return n;
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "scrollToShow keeps the cursor visible with minimal movement" {
    // Cursor already on screen: no movement.
    try testing.expectEqual(@as(usize, 0), scrollToShow(0, 3, 100, 10));
    try testing.expectEqual(@as(usize, 5), scrollToShow(5, 7, 100, 10));

    // Cursor above the window: scroll up to it exactly.
    try testing.expectEqual(@as(usize, 3), scrollToShow(10, 3, 100, 10));

    // Cursor below: scroll down just enough to put it on the last row.
    try testing.expectEqual(@as(usize, 11), scrollToShow(0, 20, 100, 10));

    // Never scroll past the end, so there are no blank rows below entries.
    try testing.expectEqual(@as(usize, 90), scrollToShow(95, 99, 100, 10));
    try testing.expectEqual(@as(usize, 0), scrollToShow(0, 0, 5, 10));

    // Degenerate inputs.
    try testing.expectEqual(@as(usize, 0), scrollToShow(5, 5, 0, 10));
    try testing.expectEqual(@as(usize, 0), scrollToShow(5, 5, 100, 0));
}

test "clampScroll never leaves blank rows below the entries" {
    try testing.expectEqual(@as(usize, 90), clampScroll(95, 100, 10));
    try testing.expectEqual(@as(usize, 5), clampScroll(5, 100, 10));
    try testing.expectEqual(@as(usize, 0), clampScroll(7, 5, 10));
    try testing.expectEqual(@as(usize, 0), clampScroll(7, 0, 10));
    try testing.expectEqual(@as(usize, 0), clampScroll(7, 100, 0));
}

test "no scrollbar while every entry already fits" {
    // Nothing to scroll means nothing to draw: an always-full bar says
    // nothing, and an empty trough on a short playlist is just noise.
    try testing.expect(thumbSpan(0, 5, 10, 10) == null);
    try testing.expect(thumbSpan(0, 10, 10, 10) == null);
    try testing.expect(thumbSpan(0, 0, 10, 10) == null);
    // Degenerate geometry.
    try testing.expect(thumbSpan(0, 100, 0, 10) == null);
    try testing.expect(thumbSpan(0, 100, 10, 0) == null);
}

test "the thumb spans the trough proportionally and reaches both ends" {
    // Half the entries visible: half the trough, top to bottom.
    const top = thumbSpan(0, 20, 10, 10).?;
    try testing.expectEqual(@as(u16, 0), top.start);
    try testing.expectEqual(@as(u16, 5), top.len);

    const bottom = thumbSpan(10, 20, 10, 10).?;
    try testing.expectEqual(@as(u16, 5), bottom.start);
    try testing.expectEqual(@as(u16, 5), bottom.len);

    // A huge playlist still gets a thumb you can see.
    const huge = thumbSpan(0, 100_000, 10, 10).?;
    try testing.expectEqual(@as(u16, 1), huge.len);

    // Scroll past the end clamps rather than running the thumb off.
    const clamped = thumbSpan(99_999_999, 100_000, 10, 10).?;
    try testing.expectEqual(@as(u16, 9), clamped.start);
}

test "the thumb never overflows the trough" {
    for ([_]u16{ 1, 2, 3, 7, 10, 24 }) |track| {
        for ([_]usize{ 2, 3, 11, 50, 1457, 100_000 }) |count| {
            if (count <= track) continue;
            var scroll: usize = 0;
            while (scroll <= count) : (scroll += 1 + count / 37) {
                const t = thumbSpan(scroll, count, track, track) orelse continue;
                try testing.expect(t.len >= 1);
                try testing.expect(t.start + t.len <= track);
            }
        }
    }
}

test "thumbSpan and scrollForThumbTop are mutual inverses at every row" {
    // The property that stops a drag from jumping: whatever row the pointer
    // puts the thumb's top on, the thumb redraws with its top on that row.
    // The trough is always exactly the entry area, so capacity == track_h.
    for ([_]u16{ 1, 2, 3, 4, 7, 10, 13, 24 }) |track| {
        for ([_]usize{ 2, 3, 5, 11, 40, 97, 1457, 50_000 }) |count| {
            if (count <= track) continue;
            const t = thumbSpan(0, count, track, track).?;
            const travel = track - t.len;
            var row: u16 = 0;
            while (row <= travel) : (row += 1) {
                const scroll = scrollForThumbTop(row, count, track, track);
                try testing.expectEqual(row, thumbSpan(scroll, count, track, track).?.start);
            }
            // And the ends line up exactly, so the bar can reach both. A
            // one-row trough is the exception: the thumb fills it and has
            // nowhere to go, so every row means the same thing.
            try testing.expectEqual(@as(usize, 0), scrollForThumbTop(0, count, track, track));
            if (travel > 0) {
                try testing.expectEqual(
                    count - track,
                    scrollForThumbTop(travel, count, track, track),
                );
            }
        }
    }
}

test "layout fits its frame and reserves the chrome rows" {
    for ([_]u16{ 4, 10, 16, 40 }) |h| {
        const l = Layout.compute(80, h);
        try testing.expectEqual(h -| chrome_rows, l.capacity());
        inline for (@typeInfo(Layout).@"struct".fields) |f| {
            const r: Rect = @field(l, f.name);
            try testing.expect(r.right() <= 80);
            try testing.expect(r.bottom() <= h);
        }
        // The three titlebar buttons are distinct cells, in Winamp's order.
        const buttons = [_]Rect{ l.folders_btn, l.shade_btn, l.close_btn };
        for (buttons, 0..) |a, i| {
            for (buttons[i + 1 ..]) |b| {
                try testing.expect(a.right() <= b.x or b.right() <= a.x);
            }
        }
    }
}

test "hitTest maps rows through the scroll offset" {
    const l = Layout.compute(80, 10); // 7 entry rows

    try testing.expectEqual(Hit{ .row = 0 }, l.hitTest(.{ .x = 10, .y = 1 }, 0, 50));
    try testing.expectEqual(Hit{ .row = 6 }, l.hitTest(.{ .x = 10, .y = 7 }, 0, 50));
    // Scrolled down, the same cell is a different entry.
    try testing.expectEqual(Hit{ .row = 20 }, l.hitTest(.{ .x = 10, .y = 1 }, 20, 50));
    // Past the end of a short list.
    try testing.expectEqual(Hit.empty, l.hitTest(.{ .x = 10, .y = 5 }, 0, 2));
    try testing.expectEqual(Hit.close, l.hitTest(.{ .x = l.close_btn.x, .y = 0 }, 0, 50));
    try testing.expectEqual(Hit.shade, l.hitTest(.{ .x = l.shade_btn.x, .y = 0 }, 0, 50));
    try testing.expectEqual(Hit.folders, l.hitTest(.{ .x = l.folders_btn.x, .y = 0 }, 0, 50));
    // The rest of the titlebar is still the titlebar.
    try testing.expectEqual(Hit.titlebar, l.hitTest(.{ .x = 4, .y = 0 }, 0, 50));
    try testing.expectEqual(Hit.status, l.hitTest(.{ .x = 4, .y = l.status.y }, 0, 50));
}

test "hitTest reads the border as a scrollbar only when there is one" {
    const l = Layout.compute(80, 10); // 7 entry rows
    const bar_x = l.scrollbar.x;

    // 50 entries in 7 rows: the border is a scrollbar, and the top of the
    // trough asks for the top of the list.
    try testing.expectEqual(
        Hit{ .scrollbar = 0 },
        l.hitTest(.{ .x = bar_x, .y = 1 }, 0, 50),
    );
    // The bottom of the trough asks for the end of the list.
    const travel = l.scrollbar.h - thumbSpan(0, 50, l.capacity(), l.scrollbar.h).?.len;
    try testing.expectEqual(
        Hit{ .scrollbar = 50 - l.capacity() },
        l.hitTest(.{ .x = bar_x, .y = 1 + travel }, 0, 50),
    );

    // A playlist that fits has no bar, so the border is just a border.
    try testing.expectEqual(Hit.none, l.hitTest(.{ .x = bar_x, .y = 1 }, 0, 3));
    // The titlebar still wins over the bar's column, and the trough stops
    // above the status row rather than swallowing the bottom-left corner.
    try testing.expectEqual(Hit.close, l.hitTest(.{ .x = l.close_btn.x, .y = 0 }, 0, 50));
    try testing.expectEqual(Hit.none, l.hitTest(.{ .x = bar_x, .y = l.status.y }, 0, 50));
    try testing.expectEqual(Hit.status, l.hitTest(.{ .x = 4, .y = l.status.y }, 0, 50));
}

fn renderText(s: *screen.Screen, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const cell = s.get(@intCast(x), @intCast(y)).?;
            if (cell.continuation) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.cp, &buf) catch 0;
            try out.appendSlice(gpa, buf[0..n]);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "indices are right-aligned so the dots line up" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    var buf: [32]u8 = undefined;
    for (0..120) |i| {
        const name = try std.fmt.bufPrint(&buf, "T{d}", .{i});
        try list.append(name, name, 60);
    }

    var s = try screen.Screen.init(gpa, 50, 8);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(50, 8), .{ .theme = .classic }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    // 120 entries: three digit columns, so "1." is pushed right by two.
    try testing.expect(std.mem.indexOf(u8, text, "  1. T0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  2. T1") != null);
}

test "draw shows numbers, titles, durations and a total" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    try list.append("/m/a.mp3", "First Track", 192);
    try list.append("/m/b.mp3", "Second Track", 3873);
    try list.append("/m/c.mp3", "Unprobed", -1);
    list.cursor = 1;

    var s = try screen.Screen.init(gpa, 80, 10);
    defer s.deinit();
    s.clear(.plain);

    const l = Layout.compute(80, 10);
    draw(s.painter(s.bounds()), l, .{ .theme = .classic, .focused = true }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Playlist") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "First Track") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3:12") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1:04:33") != null);
    // Unknown duration shows a dash, not 0:00.
    try testing.expect(std.mem.indexOf(u8, text, "-:--") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3 tracks") != null);
    // One entry has no duration yet, so the total is marked as a lower bound.
    try testing.expect(std.mem.indexOf(u8, text, "1:07:45+") != null);
}

test "a fully probed playlist shows an exact total" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    try list.append("/m/a.mp3", "A", 60);
    try list.append("/m/b.mp3", "B", 90);

    var s = try screen.Screen.init(gpa, 60, 7);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(60, 7), .{ .theme = .classic }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "2:30") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2:30+") == null);
}

test "an empty playlist draws its chrome and says so" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();

    var s = try screen.Screen.init(gpa, 80, 6);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(80, 6), .{ .theme = .classic }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "0 tracks") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Playlist") != null);
}

test "long titles are ellipsized and never overrun the duration column" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    try list.append(
        "/m/x.mp3",
        "An Extremely Long Track Title That Cannot Possibly Fit Inside A Narrow Playlist Window",
        192,
    );

    var s = try screen.Screen.init(gpa, 40, 6);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(40, 6), .{ .theme = .classic }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
    // The duration still made it to the right-hand edge.
    try testing.expect(std.mem.indexOf(u8, text, "3:12") != null);
    // And nothing wrapped onto the border column.
    for (0..s.rows) |y| {
        const edge = s.get(s.cols - 1, @intCast(y)).?.cp;
        try testing.expect(edge == '\u{2502}' or edge == '\u{250c}' or
            edge == '\u{2510}' or edge == '\u{2514}' or edge == '\u{2518}' or edge == ' ');
    }
}

test "wide-glyph titles stay inside the row" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    try list.append("/m/j.mp3", "\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\u{516d}\u{4e03}\u{516b}\u{4e5d}\u{5341}", 60);

    var s = try screen.Screen.init(gpa, 28, 5);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(28, 5), .{ .theme = .classic }, &list);
    // The border column survived, so no wide glyph straddled the edge.
    try testing.expectEqual(@as(u21, '\u{2502}'), s.get(27, 1).?.cp);
}

test "scrolled view starts at the right entry" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    var buf: [32]u8 = undefined;
    for (0..50) |i| {
        const name = try std.fmt.bufPrint(&buf, "Track{d}", .{i});
        try list.append(name, name, 60);
    }

    var s = try screen.Screen.init(gpa, 80, 7); // 4 entry rows
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(80, 7), .{ .theme = .classic, .scroll = 20 }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "21. Track20") != null);
    try testing.expect(std.mem.indexOf(u8, text, "24. Track23") != null);
    // Right-aligned: a two-digit number sits one column further right than
    // the column's left edge, with the dot in the same place throughout.
    try testing.expect(std.mem.indexOf(u8, text, " 1. Track0") == null);
    try testing.expect(std.mem.indexOf(u8, text, "25. Track24") == null);
}

test "a long playlist draws a thumb in its border, a short one does not" {
    const gpa = testing.allocator;

    var long = List.init(gpa, 1);
    defer long.deinit();
    var buf: [32]u8 = undefined;
    for (0..60) |i| {
        const name = try std.fmt.bufPrint(&buf, "Track{d}", .{i});
        try long.append(name, name, 60);
    }

    const l = Layout.compute(40, 8); // 5 entry rows
    var s = try screen.Screen.init(gpa, 40, 8);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = .classic, .scroll = 0 }, &long);

    // The thumb is at the top of the trough, and the trough fills the rest.
    const bar_x = l.scrollbar.x;
    try testing.expectEqual(Theme.classic.glyphs.thumb, s.get(bar_x, 1).?.cp);
    try testing.expectEqual(Theme.classic.glyphs.v, s.get(bar_x, l.scrollbar.h).?.cp);

    // Scrolled to the end, the thumb is at the bottom of the trough.
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = .classic, .scroll = 55 }, &long);
    try testing.expectEqual(
        Theme.classic.glyphs.thumb,
        s.get(bar_x, l.scrollbar.h).?.cp,
    );
    try testing.expectEqual(Theme.classic.glyphs.v, s.get(bar_x, 1).?.cp);

    // A playlist that fits leaves the border alone.
    var short = List.init(gpa, 1);
    defer short.deinit();
    try short.append("/m/a.mp3", "A", 60);
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = .classic }, &short);
    var y: u16 = 1;
    while (y <= l.scrollbar.h) : (y += 1) {
        try testing.expectEqual(Theme.classic.glyphs.v, s.get(bar_x, y).?.cp);
    }
}

fn groupedList(gpa: std.mem.Allocator) !List {
    var list = List.init(gpa, 1);
    errdefer list.deinit();
    try list.append("/mnt/1T/Music/Bowie/Low/01.mp3", "Speed of Life", 166);
    try list.append("/mnt/1T/Music/Bowie/Low/02.mp3", "Breaking Glass", 112);
    try list.append("/mnt/1T/Music/Eno/Another Green World/01.mp3", "Sky Saw", 189);
    try list.append("/mnt/1T/Music/Talk Talk/Spirit of Eden/01.mp3", "The Rainbow", -1);
    return list;
}

test "folder mode draws headers, indented tracks and per-folder totals" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);

    var s = try screen.Screen.init(gpa, 60, 12);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(60, 12), .{
        .theme = .classic,
        .focused = true,
        .folders = &f,
    }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    // Labels drop the prefix every folder shares, so the row says what the
    // folder is rather than where the library lives.
    try testing.expect(std.mem.indexOf(u8, text, "Bowie/Low") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Another Green World") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/mnt/1T") == null);
    // Tracks are numbered within their folder, not across the playlist: the
    // single track of the third folder is its 1, not the playlist's 4.
    try testing.expect(std.mem.indexOf(u8, text, "1. The Rainbow") != null);
    // Bowie/Low: two tracks, 4:38 between them.
    try testing.expect(std.mem.indexOf(u8, text, "4:38") != null);
    // A folder with no known length shows a dash rather than 0:00.
    try testing.expect(std.mem.indexOf(u8, text, "-:--") != null);
    // And the status row counts both things.
    try testing.expect(std.mem.indexOf(u8, text, "3 folders, 4 tracks") != null);
}

test "a folded folder hides its tracks and says it is shut" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);
    try f.setCollapsed(&list, 0, true);

    var s = try screen.Screen.init(gpa, 60, 12);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(60, 12), .{
        .theme = .classic,
        .folders = &f,
    }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Bowie/Low") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Speed of Life") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Breaking Glass") == null);
    // Its neighbours are untouched.
    try testing.expect(std.mem.indexOf(u8, text, "Sky Saw") != null);
    // The marker says which way it is: closed on the folded one, open on the
    // rest.
    try testing.expect(std.mem.indexOf(u8, text, "\u{25b6} Bowie/Low") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\u{25bc} Eno") != null);
    // The tracks are still in the playlist; only their rows went away.
    try testing.expect(std.mem.indexOf(u8, text, "3 folders, 4 tracks") != null);
}

test "the highlight follows cursor_row, in both modes" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    const th: Theme = .classic;
    var s = try screen.Screen.init(gpa, 60, 12);
    defer s.deinit();
    const l = Layout.compute(60, 12);
    const selected: screen.Color = .{ .rgb = th.list_sel_bg };

    // Flat: the row the caller names is the entry it names.
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{
        .theme = th,
        .focused = true,
        .cursor_row = 2,
    }, &list);
    try testing.expect(s.get(2, 1 + 2).?.style.bg.eql(selected));
    try testing.expect(!s.get(2, 1 + 1).?.style.bg.eql(selected));

    // Grouped: row 0 is a header, which no entry index could have selected.
    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);

    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{
        .theme = th,
        .focused = true,
        .cursor_row = 0,
        .folders = &f,
    }, &list);
    try testing.expect(s.get(2, 1).?.style.bg.eql(selected));
    try testing.expect(!s.get(2, 2).?.style.bg.eql(selected));
}

test "folder mode draws the ascii theme without non-ASCII glyphs" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);
    try f.setCollapsed(&list, 1, true);

    var s = try screen.Screen.init(gpa, 60, 12);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), Layout.compute(60, 12), .{
        .theme = .ascii,
        .focused = true,
        .folders = &f,
    }, &list);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    for (text) |b| try testing.expect(b < 0x80);
    // The fold markers survive as the ascii convention.
    try testing.expect(std.mem.indexOf(u8, text, "- Bowie/Low") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Eno") != null);
}

test "the folder button is lit in folder mode and dim out of it" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    const th: Theme = .classic;
    var s = try screen.Screen.init(gpa, 60, 10);
    defer s.deinit();
    const l = Layout.compute(60, 10);
    const marker = firstCodepoint(th.glyphs.win_folders);

    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = th }, &list);
    const off = s.get(l.folders_btn.x, 0).?;
    try testing.expectEqual(marker, off.cp);
    try testing.expect(off.style.fg.eql(.{ .rgb = th.button }));

    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);

    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = th, .folders = &f }, &list);
    const on = s.get(l.folders_btn.x, 0).?;
    try testing.expectEqual(marker, on.cp);
    try testing.expect(on.style.fg.eql(.{ .rgb = th.button_active }));

    // And it sits beside the other two rather than on top of one.
    try testing.expectEqual(
        firstCodepoint(th.glyphs.win_shade),
        s.get(l.shade_btn.x, 0).?.cp,
    );
    try testing.expectEqual(
        firstCodepoint(th.glyphs.win_close),
        s.get(l.close_btn.x, 0).?.cp,
    );
}

/// The themes carry their titlebar marks as strings, since some are more
/// than one byte; the screen holds codepoints.
fn firstCodepoint(bytes: []const u8) u21 {
    var it: std.unicode.Utf8Iterator = .{ .bytes = bytes, .i = 0 };
    return it.nextCodepoint() orelse ' ';
}

test "rowCount counts rows in whichever mode is on" {
    const gpa = testing.allocator;
    var list = try groupedList(gpa);
    defer list.deinit();

    var f = folders_mod.Folders.init(gpa);
    defer f.deinit();
    try f.rebuild(&list);

    try testing.expectEqual(@as(usize, 4), rowCount(.{ .theme = .classic }, &list));
    // Three headers and four tracks.
    try testing.expectEqual(
        @as(usize, 7),
        rowCount(.{ .theme = .classic, .folders = &f }, &list),
    );
    try f.setAll(&list, true);
    try testing.expectEqual(
        @as(usize, 3),
        rowCount(.{ .theme = .classic, .folders = &f }, &list),
    );
}

test "a window too small to hold a row does not panic" {
    const gpa = testing.allocator;
    var list = List.init(gpa, 1);
    defer list.deinit();
    try list.append("/m/a.mp3", "A", 1);

    for ([_]u16{ 1, 2, 3 }) |h| {
        var s = try screen.Screen.init(gpa, 10, h);
        defer s.deinit();
        s.clear(.plain);
        draw(s.painter(s.bounds()), Layout.compute(10, h), .{ .theme = .classic }, &list);
    }
}
