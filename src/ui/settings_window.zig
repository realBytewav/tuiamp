//! Winamp's preferences, which it opened on Ctrl+P.
//!
//! One page for now, the theme picker, because a palette is the one setting
//! you cannot judge from its name: the caller applies the theme under the
//! cursor immediately, so moving down the list recolours the whole player
//! and `esc` puts back whatever was there before. Winamp applied a skin the
//! moment you clicked it too.
//!
//! An overlay rather than a fourth window in the stack. Winamp's preferences
//! was a separate dialog, not part of the chrome you show and collapse, and
//! a modal list wants the arrow keys that the stacked windows already use.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const Catalog = theme_mod.Catalog;

/// Wide enough for the footer with a margin, and narrow enough to read as a
/// dialog over the 80-column windows rather than as another one of them.
pub const width: u16 = 48;
/// Theme rows on screen at once. A longer list scrolls.
pub const list_rows: u16 = 8;
/// Frame, a blank, the heading, the list, a blank, the footer, frame.
pub const height: u16 = list_rows + 6;

/// First row of the list, inside the frame and below the heading.
const list_y: u16 = 3;

const heading = "THEME";
const footer = "up/down preview   enter keep   esc cancel";

pub const Hit = union(enum) {
    none,
    titlebar,
    close,
    /// A visible row, as an index into the catalog.
    row: usize,
};

/// Centre the overlay in `bounds`, shrinking if it has to.
pub fn rect(bounds: Rect) Rect {
    const w = @min(width, bounds.w);
    const h = @min(height, bounds.h);
    return .{
        .x = bounds.x + (bounds.w -| w) / 2,
        .y = bounds.y + (bounds.h -| h) / 2,
        .w = w,
        .h = h,
    };
}

/// How many rows the list actually gets in an overlay `h` rows tall, which
/// is fewer than `list_rows` once the terminal is too short for the whole
/// dialog. The caller needs this to keep the cursor on screen.
pub fn rowsFor(h: u16) u16 {
    return @min(list_rows, h -| 6);
}

pub fn closeButton(w: u16) Rect {
    return .{ .x = w -| 4, .y = 0, .w = 1, .h = 1 };
}

pub fn hitTest(l: Rect, p: Point, scroll: usize, count: usize) Hit {
    if (closeButton(l.w).contains(p)) return .close;
    if (p.y == 0) return .titlebar;

    const rows = rowsFor(l.h);
    if (rows == 0 or p.y < list_y or p.y >= list_y + rows) return .none;
    const index = scroll + (p.y - list_y);
    return if (index < count) .{ .row = index } else .none;
}

pub const View = struct {
    theme: Theme,
    /// What to list. Borrowed for the duration of the draw only.
    catalog: *const Catalog,
    /// Index into the catalog.
    cursor: usize = 0,
    /// First visible row.
    scroll: usize = 0,
};

pub fn draw(p: Painter, v: View) void {
    const th = v.theme;
    const g = th.glyphs;
    const size = p.size();
    const w = size.x;
    const h = size.y;
    if (w < 12 or h < 6) return;

    p.fill(.{ .bg = .{ .rgb = th.bg } });
    drawFrame(p, w, h, th);

    _ = p.text(2, 2, heading, th.onBg(th.text_bright));

    const rows = rowsFor(h);
    const count = v.catalog.len();
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const index = v.scroll + row;
        if (index >= count) break;
        const y = list_y + row;
        const selected = index == v.cursor;

        // Filled edge to edge, so the selection reads as a bar rather than
        // as coloured text — the same as a playlist row.
        const style: Style = if (selected)
            .{ .fg = .{ .rgb = th.list_sel_fg }, .bg = .{ .rgb = th.list_sel_bg } }
        else
            th.onBg(th.text);
        p.fillRect(.{ .x = 1, .y = y, .w = w -| 2, .h = 1 }, ' ', style);

        if (selected) _ = p.text(2, y, g.now_playing, style);
        const name = v.catalog.nameAt(index);
        _ = p.text(4, y, name, style);
    }

    // Say so rather than leaving a short list looking like a broken one.
    if (count == 0) {
        _ = p.text(4, list_y, "no themes found", th.onBg(th.text_dim));
    }

    if (h >= 3 and w >= footer.len + 4) {
        _ = p.text(2, h - 2, footer, th.onBg(th.text_dim));
    }
}

fn drawFrame(p: Painter, w: u16, h: u16, th: Theme) void {
    const g = th.glyphs;
    const fs = th.onBg(th.frame_focus);
    p.set(0, 0, .{ .cp = g.tl, .style = fs });
    p.set(w - 1, 0, .{ .cp = g.tr, .style = fs });
    p.set(0, h - 1, .{ .cp = g.bl, .style = fs });
    p.set(w - 1, h - 1, .{ .cp = g.br, .style = fs });
    p.hline(1, 0, w - 2, g.h, fs);
    p.hline(1, h - 1, w - 2, g.h, fs);
    p.vline(0, 1, h - 2, g.v, fs);
    p.vline(w - 1, 1, h - 2, g.v, fs);

    _ = p.text(2, 0, " settings ", th.onBg(th.title_fg));
    const close = closeButton(w);
    _ = p.text(close.x, 0, g.win_close, th.onBg(th.button));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the footer and heading fit inside the frame" {
    try testing.expect(footer.len <= width - 4);
    try testing.expect(heading.len <= width - 4);
    // The list has to fit between the heading and the footer.
    try testing.expectEqual(list_rows, rowsFor(height));
}

test "rowsFor shrinks the list rather than overflowing the dialog" {
    try testing.expectEqual(list_rows, rowsFor(height + 10));
    try testing.expectEqual(@as(u16, 2), rowsFor(8));
    try testing.expectEqual(@as(u16, 0), rowsFor(6));
    try testing.expectEqual(@as(u16, 0), rowsFor(0));
}

test "the overlay centres itself and stays inside its bounds" {
    const r = rect(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try testing.expectEqual(width, r.w);
    try testing.expectEqual(height, r.h);
    try testing.expectEqual(@as(u16, (100 - width) / 2), r.x);
    try testing.expect(r.bottom() <= 40);

    const tight = rect(.{ .x = 0, .y = 0, .w = 20, .h = 8 });
    try testing.expectEqual(@as(u16, 20), tight.w);
    try testing.expectEqual(@as(u16, 8), tight.h);
}

test "hitTest maps rows through the scroll offset" {
    const l: Rect = .{ .x = 0, .y = 0, .w = width, .h = height };

    try testing.expectEqual(Hit{ .row = 0 }, hitTest(l, .{ .x = 5, .y = list_y }, 0, 20));
    try testing.expectEqual(Hit{ .row = 7 }, hitTest(l, .{ .x = 5, .y = list_y + 7 }, 0, 20));
    // Scrolled down, the same cell is a different theme.
    try testing.expectEqual(Hit{ .row = 12 }, hitTest(l, .{ .x = 5, .y = list_y }, 12, 20));
    // Past the end of a short list, and outside the list entirely.
    try testing.expectEqual(Hit.none, hitTest(l, .{ .x = 5, .y = list_y + 5 }, 0, 2));
    try testing.expectEqual(Hit.none, hitTest(l, .{ .x = 5, .y = height - 2 }, 0, 20));
    try testing.expectEqual(Hit.titlebar, hitTest(l, .{ .x = 5, .y = 0 }, 0, 20));
    try testing.expectEqual(Hit.close, hitTest(l, .{ .x = width - 4, .y = 0 }, 0, 20));
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

test "draw lists the themes, marks the cursor, and stays in its box" {
    const gpa = testing.allocator;
    var catalog: Catalog = .init(gpa);
    defer catalog.deinit();
    catalog.refresh(testing.io, null);

    var s = try screen.Screen.init(gpa, width + 4, height + 2);
    defer s.deinit();
    s.clear(.plain);

    const origin: Rect = .{ .x = 2, .y = 1, .w = width, .h = height };
    draw(s.painter(origin), .{ .theme = .classic, .catalog = &catalog, .cursor = 1 });

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "settings") != null);
    try testing.expect(std.mem.indexOf(u8, text, "THEME") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ascii") != null);
    try testing.expect(std.mem.indexOf(u8, text, "classic") != null);
    // The footer has to say how to get out of a modal dialog.
    try testing.expect(std.mem.indexOf(u8, text, "esc") != null);
    try testing.expect(std.mem.indexOf(u8, text, "enter") != null);
    // The cursor marker sits on the second entry, not the first.
    const marker = try std.unicode.utf8Decode(Theme.classic.glyphs.now_playing);
    try testing.expectEqual(marker, s.get(4, 1 + list_y + 1).?.cp);
    try testing.expectEqual(@as(u21, ' '), s.get(4, 1 + list_y).?.cp);

    // Nothing escaped into the margin.
    for (0..s.rows) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(0, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(s.cols - 1, @intCast(y)).?.cp);
    }
}

test "a scrolled list starts at the right theme" {
    const gpa = testing.allocator;
    var catalog: Catalog = .init(gpa);
    defer catalog.deinit();
    // More themes than fit, built by hand so the test does not need files.
    var buf: [16]u8 = undefined;
    for (0..20) |i| {
        catalog.add(try std.fmt.bufPrint(&buf, "theme{d:0>2}", .{i}));
    }

    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), .{
        .theme = .classic,
        .catalog = &catalog,
        .cursor = 12,
        .scroll = 10,
    });

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "theme10") != null);
    try testing.expect(std.mem.indexOf(u8, text, "theme17") != null);
    // Neither side of the window bleeds in.
    try testing.expect(std.mem.indexOf(u8, text, "theme09") == null);
    try testing.expect(std.mem.indexOf(u8, text, "theme18") == null);
}

test "an empty catalog says so rather than drawing a blank box" {
    const gpa = testing.allocator;
    var catalog: Catalog = .init(gpa);
    defer catalog.deinit();

    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), .{ .theme = .classic, .catalog = &catalog });

    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "no themes found") != null);
}

test "a dialog too small to draw does not panic" {
    const gpa = testing.allocator;
    var catalog: Catalog = .init(gpa);
    defer catalog.deinit();
    catalog.refresh(testing.io, null);

    for ([_][2]u16{ .{ 1, 1 }, .{ 8, 4 }, .{ 14, 7 }, .{ 30, 10 } }) |dims| {
        var s = try screen.Screen.init(gpa, dims[0], dims[1]);
        defer s.deinit();
        s.clear(.plain);
        draw(s.painter(s.bounds()), .{ .theme = .classic, .catalog = &catalog });
    }
}
