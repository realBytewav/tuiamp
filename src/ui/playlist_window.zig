//! Winamp's playlist editor.
//!
//! This is the one window Winamp lets you resize, and the same is true here:
//! it keeps the main window's width so the stack lines up, but its height is
//! whatever the terminal can spare.
//!
//! Two independent positions matter and are easy to conflate: `cursor` is the
//! row the user has highlighted, and the *current* entry is what is playing.
//! Winamp draws them differently and they move independently.

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

/// Chrome: top border, bottom border, and the status row above it.
pub const chrome_rows: u16 = 3;
pub const min_height: u16 = chrome_rows + 1;
pub const default_rows: u16 = 10;

pub const Hit = union(enum) {
    none,
    titlebar,
    shade,
    close,
    /// A visible row, as an index into the entry list.
    row: usize,
    /// Below the last entry: clicking there deselects rather than selecting
    /// whatever happens to be last.
    empty,
    status,
};

pub const Layout = struct {
    frame: Rect,
    titlebar: Rect,
    shade_btn: Rect,
    close_btn: Rect,
    /// The scrolling entry area.
    rows: Rect,
    status: Rect,

    pub fn compute(w: u16, h: u16) Layout {
        const body_h = h -| chrome_rows;
        return .{
            .frame = .{ .x = 0, .y = 0, .w = w, .h = h },
            .titlebar = .{ .x = 0, .y = 0, .w = w, .h = 1 },
            .shade_btn = .{ .x = w -| 6, .y = 0, .w = 1, .h = 1 },
            .close_btn = .{ .x = w -| 4, .y = 0, .w = 1, .h = 1 },
            .rows = .{ .x = 1, .y = 1, .w = w -| 2, .h = body_h },
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
        if (l.titlebar.contains(p)) return .titlebar;
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
    /// First visible entry.
    scroll: usize = 0,
};

/// Keep `scroll` such that `cursor` is visible, moving it as little as
/// possible. Returns the adjusted scroll.
pub fn scrollToShow(scroll: usize, cursor: usize, count: usize, capacity: u16) usize {
    if (capacity == 0 or count == 0) return 0;
    const cap: usize = capacity;

    // Never leave blank rows at the bottom while entries exist above.
    const max_scroll = count -| cap;
    var s = @min(scroll, max_scroll);
    if (cursor < s) {
        s = cursor;
    } else if (cursor >= s + cap) {
        s = cursor - cap + 1;
    }
    return @min(s, max_scroll);
}

pub fn draw(p: Painter, l: Layout, v: View, list: *const List) void {
    const th = v.theme;
    const g = th.glyphs;

    p.fill(.{ .bg = .{ .rgb = th.bg } });
    drawFrame(p, l, v);

    const rows = p.sub(l.rows);
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
        const entry = list.entries.items[index];

        const is_cursor = index == list.cursor;
        const is_current = current != null and index == current.?;

        const style: Style = if (is_cursor and v.focused)
            .{ .fg = .{ .rgb = th.list_sel_fg }, .bg = .{ .rgb = th.list_sel_bg } }
        else if (is_current)
            th.onBg(th.list_current)
        else if (is_cursor)
            th.onBg(th.text_bright)
        else
            th.onBg(th.text);

        // Selected rows are filled edge to edge so the highlight reads as a
        // bar rather than as coloured text.
        rows.fillRect(.{ .x = 0, .y = row, .w = l.rows.w, .h = 1 }, ' ', style);

        // Right-aligned, so the dots line up down the column whatever the
        // playlist's length.
        var nbuf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&nbuf, "{d}.", .{index + 1}) catch "";
        const num_x = if (num_w > num.len + 1) num_w - @as(u16, @intCast(num.len)) - 1 else 1;
        _ = rows.text(num_x, row, num, style);

        var dbuf: [16]u8 = undefined;
        const dur = fmt.duration(&dbuf, entry.duration);
        const dur_w: u16 = @intCast(dur.len);

        // Title gets whatever is left between the number and the duration.
        const title_x = num_w;
        const reserved = title_x + dur_w + 2;
        if (l.rows.w > reserved) {
            const avail = l.rows.w - reserved;
            const title_cols = marquee_mod.displayWidth(entry.title);
            if (title_cols <= avail) {
                _ = rows.text(title_x, row, entry.title, style);
            } else {
                drawEllipsized(rows, title_x, row, avail, entry.title, style);
            }
        }
        _ = rows.text(l.rows.w - dur_w - 1, row, dur, style);

        if (is_current) {
            // A marker in the gutter, so the playing track is identifiable
            // even when the cursor highlight is sitting on top of it.
            _ = rows.text(0, row, g.now_playing, style);
        }
    }

    drawStatus(p, l, v, list);
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
    const left = std.fmt.bufPrint(&buf, "{d} track{s}", .{
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
    p.fillRect(.{ .x = l.shade_btn.x -| 1, .y = 0, .w = 6, .h = 1 }, ' ', th.onBg(th.button));
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

test "layout fits its frame and reserves the chrome rows" {
    for ([_]u16{ 4, 10, 16, 40 }) |h| {
        const l = Layout.compute(80, h);
        try testing.expectEqual(h -| chrome_rows, l.capacity());
        inline for (@typeInfo(Layout).@"struct".fields) |f| {
            const r: Rect = @field(l, f.name);
            try testing.expect(r.right() <= 80);
            try testing.expect(r.bottom() <= h);
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
