//! The keymap, on screen.
//!
//! A TUI that makes you quit to read `--help` is a TUI that makes you guess,
//! so `?` and F1 put the same text over the window.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Theme = @import("theme.zig").Theme;

const lines = [_][]const u8{
    "TRANSPORT                      WINDOWS",
    "  z  previous                    tab    cycle focus",
    "  x  play                        alt+e  playlist",
    "  c  pause                       alt+g  equalizer",
    "  v  stop                        w      windowshade",
    "  b  next                        ?      this help",
    "  space  play / pause            q      quit",
    "",
    "PLAYBACK                       PLAYLIST  (when focused)",
    "  left / right   seek 5s          up / down      select",
    "  pgup / pgdn    seek 30s         shift+up/down  reorder",
    "  up / down      volume           enter          play",
    "  s  shuffle   r  repeat          del            remove",
    "  t  elapsed / remaining          home / end     first / last",
    "  j  jump to playing track",
    "  g  analyzer: spectrum, scope, off",
    "",
    "EQUALIZER  (when focused)      MOUSE",
    "  left / right  select band      drag the sliders",
    "  up / down     adjust           click the buttons",
    "  o  on / off   p  preset        double-click a playlist row",
    "  0  reset band   shift+0  all   wheel: volume, or scroll",
};

/// Winamp's own boast, which has to be in here somewhere.
const footer = "it really whips the llama's ass";

/// Wide enough for the longest line with a margin, and still inside an
/// 80-column terminal.
pub const width: u16 = 68;
pub const height: u16 = lines.len + 4;

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

pub fn draw(p: Painter, th: Theme) void {
    const g = th.glyphs;
    const size = p.size();
    const w = size.x;
    const h = size.y;
    if (w < 8 or h < 4) return;

    p.fill(.{ .bg = .{ .rgb = th.bg } });

    const fs = th.onBg(th.frame_focus);
    p.set(0, 0, .{ .cp = g.tl, .style = fs });
    p.set(w - 1, 0, .{ .cp = g.tr, .style = fs });
    p.set(0, h - 1, .{ .cp = g.bl, .style = fs });
    p.set(w - 1, h - 1, .{ .cp = g.br, .style = fs });
    p.hline(1, 0, w - 2, g.h, fs);
    p.hline(1, h - 1, w - 2, g.h, fs);
    p.vline(0, 1, h - 2, g.v, fs);
    p.vline(w - 1, 1, h - 2, g.v, fs);

    _ = p.text(2, 0, " keys ", th.onBg(th.title_fg));

    var row: u16 = 2;
    for (lines) |line| {
        if (row >= h - 2) break;
        // Section headings are the all-caps lines.
        const heading = line.len > 0 and std.ascii.isUpper(line[0]);
        _ = p.text(2, row, line, th.onBg(if (heading) th.text_bright else th.text));
        row += 1;
    }

    if (h >= 3 and w > footer.len + 4) {
        _ = p.text(
            @intCast((w - footer.len) / 2),
            h - 2,
            footer,
            th.onBg(th.text_dim),
        );
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

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

test "every line fits inside the overlay" {
    for (lines) |line| {
        try testing.expect(line.len <= width - 4);
    }
    try testing.expect(footer.len <= width - 4);
}

test "the overlay centres itself and stays inside its bounds" {
    const r = rect(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try testing.expectEqual(width, r.w);
    try testing.expectEqual(height, r.h);
    try testing.expectEqual(@as(u16, (100 - width) / 2), r.x);
    try testing.expect(r.bottom() <= 40);

    // Smaller than the overlay: shrink rather than overflow.
    const tight = rect(.{ .x = 0, .y = 0, .w = 20, .h = 8 });
    try testing.expectEqual(@as(u16, 20), tight.w);
    try testing.expectEqual(@as(u16, 8), tight.h);
    try testing.expectEqual(@as(u16, 0), tight.x);
}

test "draw shows the keys and the llama, and stays in its box" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width + 4, height + 2);
    defer s.deinit();
    s.clear(.plain);

    const origin: Rect = .{ .x = 2, .y = 1, .w = width, .h = height };
    draw(s.painter(origin), .classic);

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "TRANSPORT") != null);
    try testing.expect(std.mem.indexOf(u8, text, "EQUALIZER") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shuffle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "llama") != null);

    // Nothing escaped into the margin.
    for (0..s.rows) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(0, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(s.cols - 1, @intCast(y)).?.cp);
    }
}

test "a tiny overlay does not panic" {
    const gpa = testing.allocator;
    for ([_][2]u16{ .{ 1, 1 }, .{ 8, 4 }, .{ 20, 6 }, .{ 40, 10 } }) |dims| {
        var s = try screen.Screen.init(gpa, dims[0], dims[1]);
        defer s.deinit();
        s.clear(.plain);
        draw(s.painter(s.bounds()), .classic);
    }
}
