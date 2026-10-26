//! The big time readout.
//!
//! Winamp's time is a bitmap font three times the height of its other text,
//! and it is the single most recognizable thing about the window. Here each
//! digit is a 3x3 seven-segment cell drawn with box glyphs.

const std = @import("std");
const screen = @import("../../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("../theme.zig").Theme;

pub const digit_w = 3;
pub const digit_h = 3;

/// Seven-segment digits, row-major, three codepoints per row.
const digits = [10][digit_h][]const u8{
    .{ "┌─┐", "│ │", "└─┘" }, // 0
    .{ "  ╷", "  │", "  ╵" }, // 1
    .{ "╶─┐", "┌─┘", "└─╴" }, // 2
    .{ "╶─┐", "╶─┤", "╶─┘" }, // 3
    .{ "╷ ╷", "└─┤", "  ╵" }, // 4
    .{ "┌─╴", "└─┐", "╶─┘" }, // 5
    .{ "┌─╴", "├─┐", "└─┘" }, // 6
    .{ "╶─┐", "  │", "  ╵" }, // 7
    .{ "┌─┐", "├─┤", "└─┘" }, // 8
    .{ "┌─┐", "└─┤", "  ╵" }, // 9
};

/// ASCII fallback, for themes whose glyph set has no box drawing.
const digits_ascii = [10][digit_h][]const u8{
    .{ " _ ", "| |", "|_|" },
    .{ "   ", "  |", "  |" },
    .{ " _ ", " _|", "|_ " },
    .{ " _ ", " _|", " _|" },
    .{ "   ", "|_|", "  |" },
    .{ " _ ", "|_ ", " _|" },
    .{ " _ ", "|_ ", "|_|" },
    .{ " _ ", "  |", "  |" },
    .{ " _ ", "|_|", "|_|" },
    .{ " _ ", "|_|", " _|" },
};

/// Width in cells of `mm:ss` at this size.
pub const clock_w = 2 * digit_w + 1 + 2 * digit_w;

pub fn drawDigit(p: Painter, x: u16, y: u16, value: u8, style: Style, th: Theme) void {
    const set = if (th.glyphs.tl == '┌') &digits else &digits_ascii;
    const rows = set[@min(value, 9)];
    for (rows, 0..) |row, dy| {
        _ = p.text(x, y + @as(u16, @intCast(dy)), row, style);
    }
}

/// Draw `mm:ss`. Minutes above 99 are clamped, matching Winamp, which simply
/// has nowhere to put a third digit.
pub fn drawClock(
    p: Painter,
    x: u16,
    y: u16,
    secs_total: u32,
    style: Style,
    th: Theme,
    /// Winamp blinks the colon while paused.
    colon_lit: bool,
) void {
    const mins: u8 = @intCast(@min(secs_total / 60, 99));
    const secs: u8 = @intCast(secs_total % 60);

    drawDigit(p, x, y, mins / 10, style, th);
    drawDigit(p, x + digit_w, y, mins % 10, style, th);

    if (colon_lit) {
        const cx = x + 2 * digit_w;
        p.set(cx, y, .{ .cp = th.glyphs.colon, .style = style });
        p.set(cx, y + 2, .{ .cp = th.glyphs.colon, .style = style });
    }

    const sx = x + 2 * digit_w + 1;
    drawDigit(p, sx, y, secs / 10, style, th);
    drawDigit(p, sx + digit_w, y, secs % 10, style, th);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "every digit row is exactly three columns wide" {
    for (digits) |d| for (d) |row| {
        var count: usize = 0;
        var it: std.unicode.Utf8Iterator = .{ .bytes = row, .i = 0 };
        while (it.nextCodepoint()) |_| count += 1;
        try testing.expectEqual(@as(usize, digit_w), count);
    };
    for (digits_ascii) |d| for (d) |row| {
        try testing.expectEqual(@as(usize, digit_w), row.len);
    };
}

test "drawClock lays out mm:ss within clock_w" {
    var s = try screen.Screen.init(testing.allocator, 40, 4);
    defer s.deinit();
    s.clear(.plain);

    const th = Theme.classic;
    drawClock(s.painter(s.bounds()), 0, 0, 5 * 60 + 7, .plain, th, true);

    // '0' '5' ':' '0' '7' -> the colon sits at column 6.
    try testing.expectEqual(th.glyphs.colon, s.get(2 * digit_w, 0).?.cp);
    // Nothing drawn past the clock's declared width.
    try testing.expectEqual(@as(u21, ' '), s.get(clock_w, 0).?.cp);
    try testing.expectEqual(@as(u16, 13), clock_w);
}

test "minutes past 99 clamp instead of overflowing the field" {
    var s = try screen.Screen.init(testing.allocator, 40, 4);
    defer s.deinit();
    s.clear(.plain);
    // 200 minutes; must still render inside clock_w and not panic.
    drawClock(s.painter(s.bounds()), 0, 0, 200 * 60, .plain, Theme.classic, true);
    try testing.expectEqual(@as(u21, ' '), s.get(clock_w, 0).?.cp);
}

test "unlit colon leaves the cells untouched" {
    var s = try screen.Screen.init(testing.allocator, 40, 4);
    defer s.deinit();
    s.clear(.plain);
    drawClock(s.painter(s.bounds()), 0, 0, 61, .plain, Theme.classic, false);
    try testing.expectEqual(@as(u21, ' '), s.get(2 * digit_w, 0).?.cp);
}
