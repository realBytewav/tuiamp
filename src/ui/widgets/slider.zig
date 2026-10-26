//! Horizontal sliders: the seek bar, volume, balance, and the EQ bands.
//!
//! Two visual modes, both of which Winamp uses. `drawTrack` is a groove with
//! a thumb riding in it (the seek bar and volume slider); `drawFill` is a
//! meter that fills from the left with sub-cell precision (the EQ preamp and
//! the balance indicator read better this way in a terminal).
//!
//! Hit-testing is the reason this is a widget rather than a draw call: the
//! mapping from a click column to a value and back has to agree exactly, or
//! grabbing the thumb makes it jump.

const std = @import("std");
const screen = @import("../../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("../theme.zig").Theme;

/// Value is always normalized to 0..1; callers scale it to seconds, decibels
/// or whatever else they mean.
pub const Slider = struct {
    width: u16,

    pub fn drawTrack(
        s: Slider,
        p: Painter,
        x: u16,
        y: u16,
        value: f32,
        th: Theme,
        track_style: Style,
        thumb_style: Style,
    ) void {
        if (s.width == 0) return;
        p.hline(x, y, s.width, th.glyphs.track, track_style);
        p.set(x + s.thumbCol(value), y, .{ .cp = th.glyphs.thumb, .style = thumb_style });
    }

    pub fn drawFill(
        s: Slider,
        p: Painter,
        x: u16,
        y: u16,
        value: f32,
        th: Theme,
        track_style: Style,
        fill_style: Style,
    ) void {
        if (s.width == 0) return;
        const v = std.math.clamp(value, 0, 1);
        // Eighths of a cell, so a 20-cell meter has 160 distinguishable steps.
        const eighths: u32 = @intFromFloat(@round(v * @as(f32, @floatFromInt(s.width)) * 8));
        var col: u16 = 0;
        while (col < s.width) : (col += 1) {
            const remaining = eighths -| (@as(u32, col) * 8);
            const level = @min(remaining, 8);
            p.set(x + col, y, .{
                .cp = th.glyphs.hbars[level],
                .style = if (level == 0) track_style else fill_style,
            });
        }
    }

    /// Column the thumb occupies for `value`, in 0..width-1.
    pub fn thumbCol(s: Slider, value: f32) u16 {
        if (s.width <= 1) return 0;
        const v = std.math.clamp(value, 0, 1);
        const span: f32 = @floatFromInt(s.width - 1);
        return @intFromFloat(@round(v * span));
    }

    /// Value for a click at local column `col`. Inverse of `thumbCol`, so a
    /// click on the thumb leaves it exactly where it was.
    pub fn valueAt(s: Slider, col: u16) f32 {
        if (s.width <= 1) return 0;
        const c: f32 = @floatFromInt(@min(col, s.width - 1));
        return c / @as(f32, @floatFromInt(s.width - 1));
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "thumbCol and valueAt are mutual inverses at every column" {
    for ([_]u16{ 2, 3, 10, 29, 80 }) |w| {
        const s: Slider = .{ .width = w };
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            // Clicking a column then re-deriving its column must not move it.
            try testing.expectEqual(col, s.thumbCol(s.valueAt(col)));
        }
    }
}

test "thumbCol spans the full track" {
    const s: Slider = .{ .width = 20 };
    try testing.expectEqual(@as(u16, 0), s.thumbCol(0));
    try testing.expectEqual(@as(u16, 19), s.thumbCol(1));
    try testing.expectEqual(@as(u16, 10), s.thumbCol(0.5));
    // Out-of-range values clamp rather than drawing off the end.
    try testing.expectEqual(@as(u16, 0), s.thumbCol(-5));
    try testing.expectEqual(@as(u16, 19), s.thumbCol(5));
}

test "degenerate widths do not panic" {
    const zero: Slider = .{ .width = 0 };
    try testing.expectEqual(@as(u16, 0), zero.thumbCol(0.5));
    try testing.expectEqual(@as(f32, 0), zero.valueAt(7));

    const one: Slider = .{ .width = 1 };
    try testing.expectEqual(@as(u16, 0), one.thumbCol(1));

    var s = try screen.Screen.init(testing.allocator, 4, 1);
    defer s.deinit();
    s.clear(.plain);
    zero.drawTrack(s.painter(s.bounds()), 0, 0, 0.5, Theme.classic, .plain, .plain);
    zero.drawFill(s.painter(s.bounds()), 0, 0, 0.5, Theme.classic, .plain, .plain);
}

test "drawTrack places the thumb at the mapped column" {
    var s = try screen.Screen.init(testing.allocator, 12, 1);
    defer s.deinit();
    s.clear(.plain);

    const th = Theme.classic;
    const sl: Slider = .{ .width = 11 };
    sl.drawTrack(s.painter(s.bounds()), 0, 0, 0.5, th, .plain, .plain);

    try testing.expectEqual(th.glyphs.thumb, s.get(5, 0).?.cp);
    try testing.expectEqual(th.glyphs.track, s.get(4, 0).?.cp);
    try testing.expectEqual(th.glyphs.track, s.get(6, 0).?.cp);
}

test "drawFill is monotonic and saturates at both ends" {
    var s = try screen.Screen.init(testing.allocator, 10, 1);
    defer s.deinit();
    const th = Theme.classic;
    const sl: Slider = .{ .width = 10 };

    s.clear(.plain);
    sl.drawFill(s.painter(s.bounds()), 0, 0, 0, th, .plain, .plain);
    try testing.expectEqual(th.glyphs.hbars[0], s.get(0, 0).?.cp);

    s.clear(.plain);
    sl.drawFill(s.painter(s.bounds()), 0, 0, 1, th, .plain, .plain);
    for (0..10) |x| {
        try testing.expectEqual(th.glyphs.hbars[8], s.get(@intCast(x), 0).?.cp);
    }

    // Fill level must never decrease as value increases.
    var prev: usize = 0;
    var step: u32 = 0;
    while (step <= 80) : (step += 1) {
        s.clear(.plain);
        sl.drawFill(
            s.painter(s.bounds()),
            0,
            0,
            @as(f32, @floatFromInt(step)) / 80.0,
            th,
            .plain,
            .plain,
        );
        var total: usize = 0;
        for (0..10) |x| {
            const cp = s.get(@intCast(x), 0).?.cp;
            for (th.glyphs.hbars, 0..) |g, level| if (g == cp) {
                total += level;
                break;
            };
        }
        try testing.expect(total >= prev);
        prev = total;
    }
}
