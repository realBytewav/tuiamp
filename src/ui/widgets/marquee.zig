//! The scrolling track title.
//!
//! Winamp scrolls the title only when it does not fit, pauses at each end,
//! and separates the wrap-around with a bullet. The scroll position advances
//! on a tick rather than on wall-clock time so the speed is independent of
//! the frame rate.

const std = @import("std");
const screen = @import("../../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;

pub const Marquee = struct {
    /// Codepoint offset into the repeating text.
    offset: usize = 0,
    /// Ticks spent at the current offset, for the end-of-line pause.
    dwell: u8 = 0,
    /// Frames between steps. Winamp's default feels like ~5 steps/second.
    ticks_per_step: u8 = 6,
    tick: u8 = 0,
    /// Drawn between the end of the title and its repeat. Themed, so the
    /// ASCII theme can stay ASCII.
    separator: []const u8 = default_separator,

    pub fn reset(m: *Marquee) void {
        m.* = .{ .ticks_per_step = m.ticks_per_step, .separator = m.separator };
    }

    /// Advance one frame. `text_cols` is the display width of the title and
    /// `avail` the width of the field it is drawn into.
    pub fn step(m: *Marquee, text_cols: usize, avail: u16) void {
        if (text_cols <= avail) {
            m.offset = 0;
            return;
        }
        m.tick += 1;
        if (m.tick < m.ticks_per_step) return;
        m.tick = 0;

        // Pause briefly when the start of the title is flush left, so it is
        // actually readable before it slides away again.
        if (m.offset == 0 and m.dwell < 5) {
            m.dwell += 1;
            return;
        }
        m.dwell = 0;

        const period = text_cols + countCodepoints(m.separator);
        m.offset = (m.offset + 1) % period;
    }

    /// Draw the title, scrolled to the current offset and clipped to `avail`.
    pub fn draw(m: Marquee, p: Painter, x: u16, y: u16, avail: u16, title: []const u8, style: Style) void {
        const title_cols = displayWidth(title);
        if (title_cols <= avail) {
            _ = p.text(x, y, title, style);
            return;
        }

        // Walk the virtual infinite string `title ++ separator` from `offset`,
        // emitting until the field is full.
        var col: u16 = 0;
        var skipped: usize = 0;
        var pass: usize = 0;
        while (col < avail and pass < 4) : (pass += 1) {
            const segment = if (pass % 2 == 0) title else m.separator;
            var it: std.unicode.Utf8Iterator = .{ .bytes = segment, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                if (skipped < m.offset) {
                    skipped += 1;
                    continue;
                }
                if (col >= avail) break;
                const w = screen.charWidth(cp);
                // A wide glyph that would straddle the right edge is replaced
                // by a space rather than half-drawn.
                if (col + w > avail) {
                    p.set(x + col, y, .{ .cp = ' ', .style = style });
                    col += 1;
                    break;
                }
                p.set(x + col, y, .{ .cp = cp, .style = style });
                if (w == 2) p.set(x + col + 1, y, .{ .cp = ' ', .style = style, .continuation = true });
                col += w;
            }
        }
    }
};

pub const default_separator = " ••• ";

pub fn displayWidth(s: []const u8) usize {
    var total: usize = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| total += screen.charWidth(cp);
    return total;
}

fn countCodepoints(s: []const u8) usize {
    var n: usize = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderRow(s: *screen.Screen, y: u16, buf: []u8) []const u8 {
    var len: usize = 0;
    for (0..s.cols) |x| {
        const cell = s.get(@intCast(x), y).?;
        if (cell.continuation) continue;
        len += std.unicode.utf8Encode(cell.cp, buf[len..]) catch 0;
    }
    return buf[0..len];
}

test "short titles do not scroll" {
    var m: Marquee = .{};
    var s = try screen.Screen.init(testing.allocator, 20, 1);
    defer s.deinit();
    s.clear(.plain);

    for (0..100) |_| m.step(displayWidth("Short"), 20);
    try testing.expectEqual(@as(usize, 0), m.offset);

    m.draw(s.painter(s.bounds()), 0, 0, 20, "Short", .plain);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Short               ", renderRow(&s, 0, &buf));
}

test "long titles scroll and wrap through the separator" {
    const title = "A Very Long Track Title That Will Not Fit";
    var m: Marquee = .{ .ticks_per_step = 1 };
    const avail: u16 = 10;

    var s = try screen.Screen.init(testing.allocator, avail, 1);
    defer s.deinit();

    var buf: [256]u8 = undefined;
    s.clear(.plain);
    m.draw(s.painter(s.bounds()), 0, 0, avail, title, .plain);
    try testing.expectEqualStrings("A Very Lon", renderRow(&s, 0, &buf));

    // Past the start dwell, each step shifts by exactly one column.
    for (0..6) |_| m.step(displayWidth(title), avail);
    try testing.expectEqual(@as(usize, 1), m.offset);

    s.clear(.plain);
    m.draw(s.painter(s.bounds()), 0, 0, avail, title, .plain);
    try testing.expectEqualStrings(" Very Long", renderRow(&s, 0, &buf));

    // The offset stays inside one period no matter how long it runs.
    const period = displayWidth(title) + countCodepoints(default_separator);
    for (0..1000) |_| m.step(displayWidth(title), avail);
    try testing.expect(m.offset < period);

    // And the field is always completely filled, including across the wrap.
    for (0..period) |_| {
        m.step(displayWidth(title), avail);
        s.clear(.plain);
        m.draw(s.painter(s.bounds()), 0, 0, avail, title, .plain);
        try testing.expectEqual(@as(usize, avail), displayWidth(renderRow(&s, 0, &buf)));
    }
}

test "wide glyphs never straddle the right edge" {
    const title = "\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\u{516d}";
    var m: Marquee = .{ .ticks_per_step = 1 };
    const avail: u16 = 5; // odd width, so a wide glyph must get clipped

    var s = try screen.Screen.init(testing.allocator, avail, 1);
    defer s.deinit();

    var buf: [256]u8 = undefined;
    for (0..20) |_| {
        m.step(displayWidth(title), avail);
        s.clear(.plain);
        m.draw(s.painter(s.bounds()), 0, 0, avail, title, .plain);
        try testing.expectEqual(@as(usize, avail), displayWidth(renderRow(&s, 0, &buf)));
    }
}
