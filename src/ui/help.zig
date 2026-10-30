//! The keymap and the feature list, on screen.
//!
//! A TUI that makes you quit to read `--help` is a TUI that makes you guess,
//! so `?` and F1 put the same text over the window.
//!
//! Two pages, because the keys are not the whole story: a player that reads
//! m3u, scans directories recursively and pulls titles out of tags is not
//! obviously doing any of that from the outside, and a keymap cannot say so.
//! `?` walks keys, then capabilities, then closes.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Theme = @import("theme.zig").Theme;

pub const Page = enum {
    keys,
    features,

    /// The next page, or null to close. `?` cycles through this.
    pub fn next(p: Page) ?Page {
        return switch (p) {
            .keys => .features,
            .features => null,
        };
    }

    pub fn title(p: Page) []const u8 {
        return switch (p) {
            .keys => " keys  1/2 ",
            .features => " what it does  2/2 ",
        };
    }

    pub fn lines(p: Page) []const []const u8 {
        return switch (p) {
            .keys => &key_lines,
            .features => &feature_lines,
        };
    }
};

const key_lines = [_][]const u8{
    "TRANSPORT                      WINDOWS",
    "  z  previous                    tab     cycle focus",
    "  x  play                        alt+e   playlist",
    "  c  pause                       alt+g   equalizer",
    "  v  stop                        ctrl+p  settings",
    "  b  next                        w       windowshade",
    "  space  play / pause            ?       keys, then features",
    "  t  elapsed / remaining         q       quit",
    "PLAYBACK                       PLAYLIST  (when focused)",
    "  left / right   seek 5s          up / down      select",
    "  pgup / pgdn    seek 30s         shift+up/down  reorder",
    "  up / down      volume           enter          play",
    "  s  shuffle   r  repeat          del            remove",
    "  j  jump to playing track        home / end     first / last",
    "  g  analyzer: spectrum, scope, off",
    "EQUALIZER  (when focused)      MOUSE",
    "  left / right  select band      drag the sliders",
    "  up / down     adjust           click the buttons",
    "  o  on / off   p  preset        double-click a playlist row",
    "  0  reset band   shift+0  all   wheel: volume, or scroll",
};

/// What it can actually do. Kept in step with the README's "What it does"
/// and "What it does not do" — the gaps are deliberate, so they are listed
/// rather than left to be discovered.
const feature_lines = [_][]const u8{
    "FORMATS",
    "  mp3, flac and wav, through miniaudio's own decoders.",
    "  no ogg, opus or aac.",
    "TAGS",
    "  id3v2.2 / 2.3 / 2.4 and vorbis comments, read at scan time,",
    "  so titles and lengths are there before anything plays.",
    "PLAYLIST",
    "  recursive directory scan; m3u, m3u8 and pls read and written;",
    "  reorder, shuffle, repeat off / all / one.",
    "  the scrollbar is the window's right-hand border. drag it.",
    "VISUALIZER AND EQUALIZER",
    "  a windowed fft spectrum with falling peak caps, or an",
    "  oscilloscope at half-block resolution.  g cycles them.",
    "  ten bands at winamp's frequencies, +/- 12 dB, and a preamp.",
    "THEMES",
    "  palette and glyphs in a zon file.  ctrl+p lists the built-ins",
    "  and whatever is in ~/.config/tuiamp/themes/, previewing live.",
    "NOT YET",
    "  no gapless, no network streams, no double-size mode.",
};

/// Winamp's own boast, which has to be in here somewhere.
const footer = "it really whips the llama's ass";

/// Wide enough for the longest line with a margin, and still inside an
/// 80-column terminal.
pub const width: u16 = 68;
/// Sized for the tallest page, so flipping pages does not move the box.
///
/// Both pages are kept inside 20 lines deliberately: that puts the whole
/// overlay in 24 rows, so a plain 80x24 terminal shows all of it rather
/// than quietly cutting the bottom section off.
pub const height: u16 = tallest + 4;

const tallest: u16 = @max(key_lines.len, feature_lines.len);

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

pub fn draw(p: Painter, th: Theme, page: Page) void {
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

    _ = p.text(2, 0, page.title(), th.onBg(th.title_fg));

    var row: u16 = 2;
    for (page.lines()) |line| {
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

test "every line of every page fits inside the overlay" {
    inline for (comptime std.enums.values(Page)) |page| {
        for (page.lines()) |line| {
            try testing.expect(line.len <= width - 4);
        }
        try testing.expect(page.title().len <= width - 4);
        // A page taller than the box would be silently truncated.
        try testing.expect(page.lines().len <= height - 4);
    }
    try testing.expect(footer.len <= width - 4);
}

test "the pages cycle round to closed" {
    try testing.expectEqual(@as(?Page, .features), Page.keys.next());
    try testing.expectEqual(@as(?Page, null), Page.features.next());
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

/// Draw one page into a screen with a one-cell margin, and hand back what
/// it rendered.
fn renderPage(gpa: std.mem.Allocator, page: Page, s: *screen.Screen) ![]u8 {
    s.clear(.plain);
    const origin: Rect = .{ .x = 2, .y = 1, .w = width, .h = height };
    draw(s.painter(origin), .classic, page);
    return renderText(s, gpa);
}

test "the keys page shows the keys and the llama, and stays in its box" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width + 4, height + 2);
    defer s.deinit();

    const text = try renderPage(gpa, .keys, &s);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "TRANSPORT") != null);
    try testing.expect(std.mem.indexOf(u8, text, "EQUALIZER") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shuffle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "llama") != null);
    // The keymap has to say that a second page exists, or nobody finds it.
    try testing.expect(std.mem.indexOf(u8, text, "1/2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ctrl+p") != null);

    // Nothing escaped into the margin.
    for (0..s.rows) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(0, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(s.cols - 1, @intCast(y)).?.cp);
    }
}

test "the features page names the things a keymap cannot tell you" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width + 4, height + 2);
    defer s.deinit();

    const text = try renderPage(gpa, .features, &s);
    defer gpa.free(text);

    // The capabilities the author himself had lost track of.
    try testing.expect(std.mem.indexOf(u8, text, "m3u") != null);
    try testing.expect(std.mem.indexOf(u8, text, "recursive") != null);
    try testing.expect(std.mem.indexOf(u8, text, "id3v2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "vorbis comments") != null);
    // And the gaps, which are deliberate and so are stated rather than hidden.
    try testing.expect(std.mem.indexOf(u8, text, "NOT YET") != null);
    try testing.expect(std.mem.indexOf(u8, text, "gapless") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2/2") != null);

    for (0..s.rows) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(0, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(s.cols - 1, @intCast(y)).?.cp);
    }
}

test "both pages draw the same box, so flipping does not move it" {
    const gpa = testing.allocator;
    var keys = try screen.Screen.init(gpa, width + 4, height + 2);
    defer keys.deinit();
    var features = try screen.Screen.init(gpa, width + 4, height + 2);
    defer features.deinit();

    const a = try renderPage(gpa, .keys, &keys);
    defer gpa.free(a);
    const b = try renderPage(gpa, .features, &features);
    defer gpa.free(b);

    // The overlay sits at (2, 1) in both. Its side columns and bottom edge
    // are the frame, and they have to land on the same cells either way;
    // the top edge is excluded because the title sits in it and the two
    // titles are different lengths.
    const left: u16 = 2;
    const right: u16 = 2 + width - 1;
    var y: u16 = 1;
    while (y < 1 + height) : (y += 1) {
        try testing.expectEqual(keys.get(left, y).?.cp, features.get(left, y).?.cp);
        try testing.expectEqual(keys.get(right, y).?.cp, features.get(right, y).?.cp);
    }
    const bottom: u16 = 1 + height - 1;
    var x: u16 = left;
    while (x <= right) : (x += 1) {
        try testing.expectEqual(keys.get(x, bottom).?.cp, features.get(x, bottom).?.cp);
    }
}

test "a tiny overlay does not panic on either page" {
    const gpa = testing.allocator;
    inline for (comptime std.enums.values(Page)) |page| {
        for ([_][2]u16{ .{ 1, 1 }, .{ 8, 4 }, .{ 20, 6 }, .{ 40, 10 } }) |dims| {
            var s = try screen.Screen.init(gpa, dims[0], dims[1]);
            defer s.deinit();
            s.clear(.plain);
            draw(s.painter(s.bounds()), .classic, page);
        }
    }
}
