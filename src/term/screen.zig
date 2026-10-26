//! A double-buffered cell grid.
//!
//! Drawing goes to the back buffer; `render` diffs it against the front
//! buffer and emits only what changed, wrapped in a synchronized update so
//! the terminal never shows a half-drawn frame. At 60fps over a busy
//! visualizer this is the difference between smooth and unusable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const Rect = geom.Rect;
const esc = @import("tty.zig").esc;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hex(v: u24) Rgb {
        return .{
            .r = @intCast((v >> 16) & 0xff),
            .g = @intCast((v >> 8) & 0xff),
            .b = @intCast(v & 0xff),
        };
    }

    /// Linear blend, `t` in 0..1. Used for the visualizer gradient and for
    /// dimming unfocused windows.
    pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        const k = std.math.clamp(t, 0, 1);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1 - k) + @as(f32, @floatFromInt(b.r)) * k),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1 - k) + @as(f32, @floatFromInt(b.g)) * k),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1 - k) + @as(f32, @floatFromInt(b.b)) * k),
        };
    }
};

pub const Color = union(enum) {
    default,
    rgb: Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .rgb => |ar| switch (b) {
                .default => false,
                .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
            },
        };
    }
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,
    underline: bool = false,

    pub const none: Attrs = .{};

    fn eql(a: Attrs, b: Attrs) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .none,

    pub const plain: Style = .{};

    fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    style: Style = .plain,
    /// Set on the second column of a double-width glyph. Such a cell is never
    /// emitted; the wide glyph before it already covered this column.
    continuation: bool = false,

    pub const blank: Cell = .{};

    fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.continuation == b.continuation and
            a.style.eql(b.style);
    }
};

pub const Screen = struct {
    gpa: Allocator,
    cols: u16,
    rows: u16,
    /// What the terminal is currently showing.
    front: []Cell,
    /// What the next frame should show.
    back: []Cell,

    pub fn init(gpa: Allocator, cols: u16, rows: u16) !Screen {
        const n = @as(usize, cols) * rows;
        const front = try gpa.alloc(Cell, n);
        const back = try gpa.alloc(Cell, n);
        // Front starts as something impossible so the first render emits
        // everything rather than assuming a blank terminal.
        @memset(front, .{ .cp = 0 });
        @memset(back, .blank);
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .front = front, .back = back };
    }

    pub fn deinit(s: *Screen) void {
        s.gpa.free(s.front);
        s.gpa.free(s.back);
        s.* = undefined;
    }

    pub fn resize(s: *Screen, cols: u16, rows: u16) !void {
        if (cols == s.cols and rows == s.rows) return;
        const n = @as(usize, cols) * rows;
        s.front = try s.gpa.realloc(s.front, n);
        s.back = try s.gpa.realloc(s.back, n);
        s.cols = cols;
        s.rows = rows;
        s.invalidate();
    }

    /// Force the next render to emit every cell. Needed after a resize or when
    /// something outside our control has written to the terminal.
    pub fn invalidate(s: *Screen) void {
        @memset(s.front, .{ .cp = 0 });
    }

    pub fn bounds(s: *const Screen) Rect {
        return .{ .x = 0, .y = 0, .w = s.cols, .h = s.rows };
    }

    pub fn clear(s: *Screen, style: Style) void {
        @memset(s.back, .{ .cp = ' ', .style = style });
    }

    fn index(s: *const Screen, x: u16, y: u16) ?usize {
        if (x >= s.cols or y >= s.rows) return null;
        return @as(usize, y) * s.cols + x;
    }

    pub fn set(s: *Screen, x: u16, y: u16, cell: Cell) void {
        if (s.index(x, y)) |i| s.back[i] = cell;
    }

    pub fn get(s: *const Screen, x: u16, y: u16) ?Cell {
        const i = s.index(x, y) orelse return null;
        return s.back[i];
    }

    /// A clipped, translated view for drawing one window without it having to
    /// know where on screen it lives.
    pub fn painter(s: *Screen, rect: Rect) Painter {
        return .{ .screen = s, .rect = clampRect(rect, s.cols, s.rows) };
    }

    /// Emit the difference between the back and front buffers, then swap.
    pub fn render(s: *Screen, w: *std.Io.Writer) !void {
        try w.writeAll(esc.sync_begin);

        var style: Style = .plain;
        var style_known = false;
        var cursor: ?geom.Point = null;

        for (0..s.rows) |row| {
            const y: u16 = @intCast(row);
            var x: u16 = 0;
            while (x < s.cols) : (x += 1) {
                const i = @as(usize, y) * s.cols + x;
                const cell = s.back[i];
                if (cell.eql(s.front[i])) continue;
                s.front[i] = cell;
                // The trailing half of a wide glyph is implied by the glyph
                // itself, so there is nothing to emit for it.
                if (cell.continuation) continue;

                const at_cursor = if (cursor) |c| c.x == x and c.y == y else false;
                if (!at_cursor) {
                    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                }

                if (!style_known or !style.eql(cell.style)) {
                    try writeStyle(w, cell.style);
                    style = cell.style;
                    style_known = true;
                }

                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &utf8) catch blk: {
                    utf8[0] = ' ';
                    break :blk 1;
                };
                try w.writeAll(utf8[0..n]);

                const advance = charWidth(cell.cp);
                cursor = .{ .x = x + advance, .y = y };
            }
        }

        if (style_known) try w.writeAll(esc.sgr_reset);
        try w.writeAll(esc.sync_end);
        try w.flush();
    }
};

fn writeStyle(w: *std.Io.Writer, st: Style) !void {
    // One reset-and-rebuild is both shorter and safer than tracking which
    // individual attributes need turning off.
    try w.writeAll("\x1b[0");
    if (st.attrs.bold) try w.writeAll(";1");
    if (st.attrs.dim) try w.writeAll(";2");
    if (st.attrs.underline) try w.writeAll(";4");
    if (st.attrs.reverse) try w.writeAll(";7");
    switch (st.fg) {
        .default => {},
        .rgb => |c| try w.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }
    switch (st.bg) {
        .default => {},
        .rgb => |c| try w.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }
    try w.writeAll("m");
}

fn clampRect(r: Rect, cols: u16, rows: u16) Rect {
    if (r.x >= cols or r.y >= rows) return .empty;
    return .{
        .x = r.x,
        .y = r.y,
        .w = @min(r.w, cols - r.x),
        .h = @min(r.h, rows - r.y),
    };
}

/// A window-local drawing surface: coordinates are relative to its rect, and
/// anything outside is dropped rather than wrapping or corrupting a neighbour.
pub const Painter = struct {
    screen: *Screen,
    rect: Rect,

    pub fn size(p: Painter) geom.Point {
        return .{ .x = p.rect.w, .y = p.rect.h };
    }

    pub fn sub(p: Painter, r: Rect) Painter {
        return .{
            .screen = p.screen,
            .rect = clampRect(.{
                .x = p.rect.x + r.x,
                .y = p.rect.y + r.y,
                .w = r.w,
                .h = r.h,
            }, p.rect.right(), p.rect.bottom()),
        };
    }

    pub fn set(p: Painter, x: u16, y: u16, cell: Cell) void {
        if (x >= p.rect.w or y >= p.rect.h) return;
        p.screen.set(p.rect.x + x, p.rect.y + y, cell);
    }

    pub fn fill(p: Painter, style: Style) void {
        p.fillRect(.{ .x = 0, .y = 0, .w = p.rect.w, .h = p.rect.h }, ' ', style);
    }

    pub fn fillRect(p: Painter, r: Rect, cp: u21, style: Style) void {
        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            var x = r.x;
            while (x < r.right()) : (x += 1) {
                p.set(x, y, .{ .cp = cp, .style = style });
            }
        }
    }

    /// Draw `text` at (x, y), clipped to the surface. Returns the number of
    /// columns consumed.
    pub fn text(p: Painter, x: u16, y: u16, s: []const u8, style: Style) u16 {
        var col = x;
        var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (col >= p.rect.w) break;
            const w = charWidth(cp);
            p.set(col, y, .{ .cp = cp, .style = style });
            if (w == 2) p.set(col + 1, y, .{ .cp = ' ', .style = style, .continuation = true });
            col += w;
        }
        return col - x;
    }

    /// Repeat a single glyph horizontally.
    pub fn hline(p: Painter, x: u16, y: u16, len: u16, cp: u21, style: Style) void {
        var i: u16 = 0;
        while (i < len) : (i += 1) p.set(x + i, y, .{ .cp = cp, .style = style });
    }

    pub fn vline(p: Painter, x: u16, y: u16, len: u16, cp: u21, style: Style) void {
        var i: u16 = 0;
        while (i < len) : (i += 1) p.set(x, y + i, .{ .cp = cp, .style = style });
    }
};

/// Approximate display width. We only need to distinguish 0, 1 and 2 columns,
/// and the ranges below cover what actually turns up in track metadata (CJK,
/// Hangul, emoji) without carrying full Unicode tables.
pub fn charWidth(cp: u21) u16 {
    if (cp == 0) return 0;
    // Combining marks.
    if ((cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe00 and cp <= 0xfe0f)) return 0;
    if (cp < 0x1100) return 1;
    if ((cp >= 0x1100 and cp <= 0x115f) or // Hangul Jamo
        (cp >= 0x2e80 and cp <= 0x303e) or // CJK radicals, Kangxi
        (cp >= 0x3041 and cp <= 0x33ff) or // Hiragana .. CJK compat
        (cp >= 0x3400 and cp <= 0x4dbf) or
        (cp >= 0x4e00 and cp <= 0x9fff) or // CJK unified
        (cp >= 0xa000 and cp <= 0xa4cf) or // Yi
        (cp >= 0xac00 and cp <= 0xd7a3) or // Hangul syllables
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or // fullwidth forms
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or // emoji
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Render into memory so tests can assert on the exact bytes emitted.
fn renderToBuf(s: *Screen, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try s.render(&w);
    return w.buffered();
}

test "first render emits content, second emits nothing" {
    var s = try Screen.init(testing.allocator, 10, 2);
    defer s.deinit();

    s.clear(.plain);
    _ = s.painter(s.bounds()).text(0, 0, "hi", .plain);

    var buf: [4096]u8 = undefined;
    const first = try renderToBuf(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, first, "hi") != null);

    var buf2: [4096]u8 = undefined;
    const second = try renderToBuf(&s, &buf2);
    // Only the synchronized-update wrapper, no cell output.
    try testing.expectEqualStrings(esc.sync_begin ++ esc.sync_end, second);
}

test "only changed cells are emitted" {
    var s = try Screen.init(testing.allocator, 20, 1);
    defer s.deinit();

    s.clear(.plain);
    _ = s.painter(s.bounds()).text(0, 0, "aaaaaaaaaa", .plain);
    var buf: [4096]u8 = undefined;
    _ = try renderToBuf(&s, &buf);

    // Change one glyph in the middle.
    s.set(5, 0, .{ .cp = 'Z' });
    var buf2: [4096]u8 = undefined;
    const out = try renderToBuf(&s, &buf2);

    try testing.expect(std.mem.indexOf(u8, out, "Z") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a") == null);
    // Positioned at row 1, column 6.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;6H") != null);
}

test "truecolor style is emitted once per run" {
    var s = try Screen.init(testing.allocator, 8, 1);
    defer s.deinit();

    const green: Style = .{ .fg = .{ .rgb = .hex(0x00ff00) } };
    s.clear(.plain);
    _ = s.painter(s.bounds()).text(0, 0, "abc", green);

    var buf: [4096]u8 = undefined;
    const out = try renderToBuf(&s, &buf);
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out, "38;2;0;255;0"),
    );
}

test "painter clips to its rect" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    s.clear(.plain);

    const p = s.painter(.{ .x = 2, .y = 1, .w = 3, .h = 1 });
    _ = p.text(0, 0, "abcdefgh", .plain);

    try testing.expectEqual(@as(u21, 'a'), s.get(2, 1).?.cp);
    try testing.expectEqual(@as(u21, 'c'), s.get(4, 1).?.cp);
    // 'd' would land at x=5, outside the painter.
    try testing.expectEqual(@as(u21, ' '), s.get(5, 1).?.cp);
    // And nothing escaped onto a neighbouring row.
    try testing.expectEqual(@as(u21, ' '), s.get(2, 0).?.cp);
}

test "painter rect outside the screen is harmless" {
    var s = try Screen.init(testing.allocator, 4, 2);
    defer s.deinit();
    s.clear(.plain);

    const p = s.painter(.{ .x = 100, .y = 100, .w = 10, .h = 10 });
    _ = p.text(0, 0, "nope", .plain);
    p.fill(.{ .bg = .{ .rgb = .hex(0xff0000) } });

    var buf: [4096]u8 = undefined;
    const out = try renderToBuf(&s, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "nope") == null);
}

test "wide glyphs occupy two columns" {
    var s = try Screen.init(testing.allocator, 6, 1);
    defer s.deinit();
    s.clear(.plain);

    const used = s.painter(s.bounds()).text(0, 0, "\u{4e00}x", .plain);
    try testing.expectEqual(@as(u16, 3), used);
    try testing.expect(s.get(1, 0).?.continuation);
    try testing.expectEqual(@as(u21, 'x'), s.get(2, 0).?.cp);

    // The continuation cell must not be emitted as its own glyph.
    var buf: [4096]u8 = undefined;
    const out = try renderToBuf(&s, &buf);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\u{4e00}"));
}

test "resize forces a full redraw" {
    var s = try Screen.init(testing.allocator, 4, 1);
    defer s.deinit();
    s.clear(.plain);
    _ = s.painter(s.bounds()).text(0, 0, "ab", .plain);
    var buf: [4096]u8 = undefined;
    _ = try renderToBuf(&s, &buf);

    try s.resize(6, 2);
    s.clear(.plain);
    _ = s.painter(s.bounds()).text(0, 0, "ab", .plain);
    var buf2: [4096]u8 = undefined;
    const out = try renderToBuf(&s, &buf2);
    try testing.expect(std.mem.indexOf(u8, out, "ab") != null);
}

test "charWidth basics" {
    try testing.expectEqual(@as(u16, 1), charWidth('a'));
    try testing.expectEqual(@as(u16, 1), charWidth(0x2588)); // full block
    try testing.expectEqual(@as(u16, 2), charWidth(0x4e00)); // CJK
    try testing.expectEqual(@as(u16, 0), charWidth(0x0301)); // combining acute
}

test "Rgb mix endpoints and midpoint" {
    const a: Rgb = .hex(0x000000);
    const b: Rgb = .hex(0xffffff);
    try testing.expectEqual(@as(u8, 0), a.mix(b, 0).r);
    try testing.expectEqual(@as(u8, 255), a.mix(b, 1).r);
    try testing.expectEqual(@as(u8, 127), a.mix(b, 0.5).r);
    // Out-of-range t is clamped, not wrapped.
    try testing.expectEqual(@as(u8, 255), a.mix(b, 9.0).r);
}
