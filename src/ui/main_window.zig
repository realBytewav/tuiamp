//! Winamp's main window, at 80x16 cells.
//!
//! 275x116 pixels at a 2:1 cell aspect is 80x16.9 cells, so 80x16 is the
//! faithful size, and like Winamp's own main window it does not resize — it
//! sits centred in the terminal instead of stretching. The playlist is the
//! window that grows, which is also how Winamp behaves.
//!
//! `Layout` is the single source of truth: `draw` and `hitTest` both derive
//! from it, so a widget can never be drawn somewhere the mouse does not find
//! it.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("theme.zig").Theme;
const lcd = @import("widgets/lcd.zig");
const Marquee = @import("widgets/marquee.zig").Marquee;
const Slider = @import("widgets/slider.zig").Slider;
const player_mod = @import("../audio/player.zig");
const vis = @import("widgets/vis.zig");

pub const width: u16 = 80;
pub const height: u16 = 16;
/// Winamp's "windowshade": the window collapsed to a single status row
/// between its top and bottom borders.
pub const shade_height: u16 = 3;
/// Narrower than this and even the shade view has nothing useful to say.
pub const min_shade_width: u16 = 24;

pub const Hit = union(enum) {
    none,
    titlebar,
    shade,
    close,
    /// The `?` in the titlebar, which opens the same overlay the `?` key
    /// does. Winamp had no such button; a TUI needs one, because there is
    /// nothing else on screen to tell you the overlay exists.
    help,
    /// Winamp toggles elapsed/remaining when the time display is clicked.
    time,
    /// Clicking the analyzer cycles its mode.
    vis,
    seek: f32,
    volume: f32,
    balance: f32,
    prev,
    play,
    pause,
    stop,
    next,
    eject,
    shuffle,
    repeat,
    eq,
    playlist,
};

pub const Layout = struct {
    frame: Rect,
    titlebar: Rect,
    help_btn: Rect,
    shade_btn: Rect,
    close_btn: Rect,
    clock: Rect,
    marquee: Rect,
    info: Rect,
    vis: Rect,
    volume: Rect,
    balance: Rect,
    seek: Rect,
    prev: Rect,
    play: Rect,
    pause: Rect,
    stop: Rect,
    next: Rect,
    eject: Rect,
    shuffle: Rect,
    repeat: Rect,
    eq: Rect,
    playlist: Rect,

    /// Window-local coordinates, so the caller only has to place the frame.
    pub fn compute() Layout {
        const btn_w: u16 = 5;
        const btn_y: u16 = 13;
        const btn_x: u16 = 3;
        return .{
            .frame = .{ .x = 0, .y = 0, .w = width, .h = height },
            .titlebar = .{ .x = 0, .y = 0, .w = width, .h = 1 },
            // Grouped at the right edge, the way Winamp's titlebar buttons
            // sit together rather than being sprinkled along the bar.
            .help_btn = .{ .x = width - 8, .y = 0, .w = 1, .h = 1 },
            .shade_btn = .{ .x = width - 6, .y = 0, .w = 1, .h = 1 },
            .close_btn = .{ .x = width - 4, .y = 0, .w = 1, .h = 1 },

            .clock = .{ .x = 3, .y = 2, .w = lcd.clock_w, .h = lcd.digit_h },
            .marquee = .{ .x = 20, .y = 2, .w = 56, .h = 1 },
            .info = .{ .x = 20, .y = 4, .w = 56, .h = 1 },

            .vis = .{ .x = 3, .y = 6, .w = 26, .h = 4 },
            .volume = .{ .x = 38, .y = 6, .w = 18, .h = 1 },
            .balance = .{ .x = 64, .y = 6, .w = 11, .h = 1 },
            .eq = .{ .x = 62, .y = 9, .w = 6, .h = 1 },
            .playlist = .{ .x = 70, .y = 9, .w = 6, .h = 1 },

            .seek = .{ .x = 3, .y = 11, .w = width - 6, .h = 1 },

            .prev = .{ .x = btn_x + 0 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .play = .{ .x = btn_x + 1 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .pause = .{ .x = btn_x + 2 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .stop = .{ .x = btn_x + 3 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .next = .{ .x = btn_x + 4 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .eject = .{ .x = btn_x + 5 * (btn_w + 1), .y = btn_y, .w = btn_w, .h = 1 },
            .shuffle = .{ .x = 48, .y = 13, .w = 9, .h = 1 },
            .repeat = .{ .x = 59, .y = 13, .w = 8, .h = 1 },
        };
    }

    pub fn hitTest(l: Layout, p: Point) Hit {
        // Sliders first: they report a value, and some of them overlap the
        // generous click targets around them.
        if (l.seek.localize(p)) |q| {
            return .{ .seek = sliderValue(l.seek, q) };
        }
        if (l.volume.localize(p)) |q| {
            return .{ .volume = sliderValue(l.volume, q) };
        }
        if (l.balance.localize(p)) |q| {
            return .{ .balance = sliderValue(l.balance, q) * 2 - 1 };
        }

        if (l.close_btn.contains(p)) return .close;
        if (l.shade_btn.contains(p)) return .shade;
        if (l.help_btn.contains(p)) return .help;
        if (l.titlebar.contains(p)) return .titlebar;

        if (l.clock.contains(p)) return .time;
        if (l.vis.contains(p)) return .vis;

        if (l.prev.contains(p)) return .prev;
        if (l.play.contains(p)) return .play;
        if (l.pause.contains(p)) return .pause;
        if (l.stop.contains(p)) return .stop;
        if (l.next.contains(p)) return .next;
        if (l.eject.contains(p)) return .eject;
        if (l.shuffle.contains(p)) return .shuffle;
        if (l.repeat.contains(p)) return .repeat;
        if (l.eq.contains(p)) return .eq;
        if (l.playlist.contains(p)) return .playlist;

        return .none;
    }

    fn sliderValue(r: Rect, local: Point) f32 {
        const s: Slider = .{ .width = r.w };
        return s.valueAt(local.x);
    }
};

/// Everything the window needs in order to draw itself. Assembled by the app
/// each frame, so the window itself stays free of state.
pub const View = struct {
    theme: Theme,
    focused: bool = true,
    state: player_mod.State = .stopped,
    title: []const u8 = "",
    /// Seconds. What the clock shows; the app decides elapsed vs remaining.
    clock_secs: u32 = 0,
    show_remaining: bool = false,
    progress: f32 = 0,
    volume: f32 = 1,
    balance: f32 = 0,
    kbps: u32 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    shuffle: bool = false,
    repeat: bool = false,
    eq_open: bool = false,
    playlist_open: bool = false,
    /// Set while the colon should be lit; the app blinks it when paused.
    colon_lit: bool = true,
    /// Playlist position, as Winamp shows it in the titlebar.
    track_index: usize = 0,
    track_count: usize = 0,
    /// Drawn into the analyzer box. Null leaves it blank, which is what the
    /// window tests want and what happens before any audio has played.
    analyzer: ?*const vis.Analyzer = null,
};

pub fn draw(p: Painter, l: Layout, v: View, marquee: Marquee) void {
    const th = v.theme;
    const g = th.glyphs;

    p.fill(.{ .bg = .{ .rgb = th.bg } });
    drawFrame(p, l, v);

    // --- clock -------------------------------------------------------------
    const clock = p.sub(l.clock);
    clock.fill(th.onLcd(th.lcd_fg));
    lcd.drawClock(clock, 0, 0, v.clock_secs, th.onLcd(th.lcd_fg), th, v.colon_lit);

    // --- title marquee -----------------------------------------------------
    const state_mark = switch (v.state) {
        .playing => g.play,
        .paused => g.pause,
        .stopped => g.stop,
    };
    const mq = p.sub(l.marquee);
    _ = mq.text(0, 0, state_mark, th.onBg(th.text_bright));
    const title_x: u16 = 4;
    if (l.marquee.w > title_x) {
        marquee.draw(mq, title_x, 0, l.marquee.w - title_x, v.title, th.onBg(th.title_fg));
    }

    // --- kbps / kHz / channels --------------------------------------------
    const info = p.sub(l.info);
    var buf: [64]u8 = undefined;
    if (v.kbps > 0) {
        _ = info.text(0, 0, std.fmt.bufPrint(&buf, "{d: >4} kbps", .{v.kbps}) catch "", th.onBg(th.text));
    } else {
        _ = info.text(0, 0, "  -- kbps", th.onBg(th.text_dim));
    }
    if (v.sample_rate > 0) {
        const khz = (v.sample_rate + 500) / 1000;
        _ = info.text(13, 0, std.fmt.bufPrint(&buf, "{d: >3} kHz", .{khz}) catch "", th.onBg(th.text));
    } else {
        _ = info.text(13, 0, " -- kHz", th.onBg(th.text_dim));
    }
    _ = info.text(24, 0, switch (v.channels) {
        0 => "   --   ",
        1 => "  mono  ",
        else => " stereo ",
    }, th.onBg(if (v.channels == 0) th.text_dim else th.text));

    // --- visualizer box ----------------------------------------------------
    const vis_box = p.sub(l.vis);
    if (v.analyzer) |an| {
        an.draw(vis_box, th);
    } else {
        // Nothing playing yet: a quiet baseline, so the box reads as a
        // display at rest rather than as a hole in the window.
        vis_box.fill(th.onLcd(th.lcd_fg));
        vis_box.hline(0, l.vis.h - 1, l.vis.w, g.bars[1], th.onLcd(th.lcd_dim));
    }

    // --- volume and balance ------------------------------------------------
    _ = p.text(l.volume.x - 4, l.volume.y, "vol", th.onBg(th.text_dim));
    const vol: Slider = .{ .width = l.volume.w };
    vol.drawFill(
        p.sub(l.volume),
        0,
        0,
        v.volume,
        th,
        th.onBg(th.track),
        th.onBg(th.fill),
    );

    _ = p.text(l.balance.x - 4, l.balance.y, "bal", th.onBg(th.text_dim));
    const bal: Slider = .{ .width = l.balance.w };
    bal.drawTrack(
        p.sub(l.balance),
        0,
        0,
        (v.balance + 1) / 2,
        th,
        th.onBg(th.track),
        th.onBg(th.thumb),
    );

    // --- EQ / PL toggles ---------------------------------------------------
    drawButton(p, l.eq, "[EQ]", v.eq_open, th);
    drawButton(p, l.playlist, "[PL]", v.playlist_open, th);

    // --- seek bar ----------------------------------------------------------
    const seek: Slider = .{ .width = l.seek.w };
    const seekable = v.state != .stopped;
    seek.drawTrack(
        p.sub(l.seek),
        0,
        0,
        v.progress,
        th,
        th.onBg(th.track),
        th.onBg(if (seekable) th.thumb else th.text_dim),
    );

    // --- transport ---------------------------------------------------------
    drawButton(p, l.prev, g.prev, false, th);
    drawButton(p, l.play, g.play, v.state == .playing, th);
    drawButton(p, l.pause, g.pause, v.state == .paused, th);
    drawButton(p, l.stop, g.stop, v.state == .stopped, th);
    drawButton(p, l.next, g.next, false, th);
    drawButton(p, l.eject, g.eject, false, th);
    drawButton(p, l.shuffle, "shuffle", v.shuffle, th);
    drawButton(p, l.repeat, "repeat", v.repeat, th);
}

fn drawFrame(p: Painter, l: Layout, v: View) void {
    const th = v.theme;
    const g = th.glyphs;
    const frame_rgb = if (v.focused) th.frame_focus else th.frame;
    const fs = th.onBg(frame_rgb);
    const w = l.frame.w;
    const h = l.frame.h;

    p.set(0, 0, .{ .cp = g.tl, .style = fs });
    p.set(w - 1, 0, .{ .cp = g.tr, .style = fs });
    p.set(0, h - 1, .{ .cp = g.bl, .style = fs });
    p.set(w - 1, h - 1, .{ .cp = g.br, .style = fs });
    p.hline(1, 0, w - 2, g.h, fs);
    p.hline(1, h - 1, w - 2, g.h, fs);
    p.vline(0, 1, h - 2, g.v, fs);
    p.vline(w - 1, 1, h - 2, g.v, fs);

    // Titlebar: name on the left, playlist position in the middle, window
    // buttons on the right, as Winamp does.
    _ = p.text(2, 0, " tuiamp ", th.onBg(th.title_fg));
    if (v.track_count > 0 and w >= 40) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " {d}/{d} ", .{ v.track_index + 1, v.track_count }) catch "";
        _ = p.text(w / 2 - @as(u16, @intCast(s.len / 2)), 0, s, th.onBg(th.title_fg_dim));
    }
    // One block behind all three buttons, so they read as a group rather
    // than as three marks that happen to be near each other.
    p.fillRect(
        .{ .x = l.help_btn.x -| 1, .y = 0, .w = 8, .h = 1 },
        ' ',
        th.onBg(th.button),
    );
    // A literal "?" rather than a themed glyph: it is the one mark whose
    // meaning is the character itself, and every font has it.
    _ = p.text(l.help_btn.x, 0, help_mark, th.onBg(th.button));
    _ = p.text(l.shade_btn.x, 0, g.win_shade, th.onBg(th.button));
    _ = p.text(l.close_btn.x, 0, g.win_close, th.onBg(th.button));
}

/// The titlebar's help button. Not part of the glyph set — see `drawFrame`.
pub const help_mark = "?";

fn drawButton(p: Painter, r: Rect, label: []const u8, active: bool, th: Theme) void {
    const style = th.onBg(if (active) th.button_active else th.button);
    const sub = p.sub(r);
    sub.fill(.{ .bg = .{ .rgb = th.bg } });
    const label_w: u16 = @intCast(@import("widgets/marquee.zig").displayWidth(label));
    const pad: u16 = if (r.w > label_w) (r.w - label_w) / 2 else 0;
    _ = sub.text(pad, 0, label, style);
}

/// Windowshade mode, and the fallback for terminals too small for the full
/// layout. Unlike the main window this is width-elastic, because it has to
/// fit whatever space there is.
pub fn drawShade(p: Painter, v: View, marquee: Marquee) void {
    const th = v.theme;
    const g = th.glyphs;
    const w = p.size().x;
    if (w < min_shade_width or p.size().y < shade_height) return;

    p.fill(.{ .bg = .{ .rgb = th.bg } });

    // A shade-sized frame derived from the real width, so the right-hand
    // border lands on the last column rather than at column 79.
    var shade: Layout = .compute();
    shade.frame = .{ .x = 0, .y = 0, .w = w, .h = shade_height };
    shade.titlebar = .{ .x = 0, .y = 0, .w = w, .h = 1 };
    shade.help_btn = .{ .x = w - 8, .y = 0, .w = 1, .h = 1 };
    shade.shade_btn = .{ .x = w - 6, .y = 0, .w = 1, .h = 1 };
    shade.close_btn = .{ .x = w - 4, .y = 0, .w = 1, .h = 1 };
    drawFrame(p, shade, v);

    const mark = switch (v.state) {
        .playing => g.play,
        .paused => g.pause,
        .stopped => g.stop,
    };
    const clock_str = formatClock(v.clock_secs);

    // Content sits on the middle row, inside the side borders.
    const row: u16 = 1;
    _ = p.text(2, row, mark, th.onBg(th.text_bright));
    _ = p.text(6, row, &clock_str, th.onLcd(th.lcd_fg));
    const title_x: u16 = 13;
    if (w > title_x + 2) {
        marquee.draw(p, title_x, row, w - (title_x + 2), v.title, th.onBg(th.title_fg));
    }
}

/// `mm:ss`, clamped to two minute digits like Winamp's own readout.
fn formatClock(secs: u32) [5]u8 {
    var out: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>2}:{d:0>2}", .{
        @min(secs / 60, 99),
        secs % 60,
    }) catch {
        return .{ '-', '-', ':', '-', '-' };
    };
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "layout fits inside the window with no overlaps in the button row" {
    const l: Layout = .compute();
    const row = [_]Rect{ l.prev, l.play, l.pause, l.stop, l.next, l.eject, l.shuffle, l.repeat };
    for (row, 0..) |a, i| {
        try testing.expect(a.right() <= width);
        try testing.expect(a.bottom() <= height);
        for (row[i + 1 ..]) |b| {
            const disjoint = a.right() <= b.x or b.right() <= a.x;
            try testing.expect(disjoint);
        }
    }
}

test "every region stays inside the frame" {
    const l: Layout = .compute();
    inline for (@typeInfo(Layout).@"struct".fields) |f| {
        const r: Rect = @field(l, f.name);
        try testing.expect(r.right() <= width);
        try testing.expect(r.bottom() <= height);
    }
}

test "hitTest finds each control at its drawn position" {
    const l: Layout = .compute();

    try testing.expectEqual(Hit.play, l.hitTest(.{ .x = l.play.x + 2, .y = l.play.y }));
    try testing.expectEqual(Hit.stop, l.hitTest(.{ .x = l.stop.x, .y = l.stop.y }));
    try testing.expectEqual(Hit.eject, l.hitTest(.{ .x = l.eject.x + 4, .y = l.eject.y }));
    try testing.expectEqual(Hit.shuffle, l.hitTest(.{ .x = l.shuffle.x, .y = l.shuffle.y }));
    try testing.expectEqual(Hit.eq, l.hitTest(.{ .x = l.eq.x + 1, .y = l.eq.y }));
    try testing.expectEqual(Hit.time, l.hitTest(.{ .x = l.clock.x, .y = l.clock.y + 1 }));
    try testing.expectEqual(Hit.vis, l.hitTest(.{ .x = l.vis.x + 3, .y = l.vis.y + 2 }));
    try testing.expectEqual(Hit.close, l.hitTest(.{ .x = l.close_btn.x, .y = 0 }));
    try testing.expectEqual(Hit.shade, l.hitTest(.{ .x = l.shade_btn.x, .y = 0 }));
    try testing.expectEqual(Hit.help, l.hitTest(.{ .x = l.help_btn.x, .y = 0 }));
    try testing.expectEqual(Hit.titlebar, l.hitTest(.{ .x = 2, .y = 0 }));
    try testing.expectEqual(Hit.none, l.hitTest(.{ .x = 40, .y = 14 }));
}

test "the titlebar buttons do not overlap, and the title has room" {
    const l: Layout = .compute();
    const buttons = [_]Rect{ l.help_btn, l.shade_btn, l.close_btn };
    for (buttons, 0..) |a, i| {
        try testing.expect(a.right() <= width);
        for (buttons[i + 1 ..]) |b| {
            try testing.expect(a.right() <= b.x or b.right() <= a.x);
        }
    }
    // Left to right, so the cluster reads in the order it is drawn.
    try testing.expect(l.help_btn.x < l.shade_btn.x);
    try testing.expect(l.shade_btn.x < l.close_btn.x);
    // And the " 1/40 " readout in the middle of the bar cannot reach them.
    try testing.expect(width / 2 + 8 < l.help_btn.x);
}

test "the help button is drawn where hitTest reports it" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);

    const l: Layout = .compute();
    draw(s.painter(s.bounds()), l, .{ .theme = .classic }, .{});

    // A button the mouse can find but the eye cannot is worse than no
    // button, since the whole point of it is to be noticed.
    try testing.expectEqual(@as(u21, '?'), s.get(l.help_btn.x, 0).?.cp);
    try testing.expectEqual(Hit.help, l.hitTest(.{ .x = l.help_btn.x, .y = 0 }));
}

test "the windowshade titlebar carries the same buttons" {
    const gpa = testing.allocator;
    // Narrow enough to be the realistic worst case for the button cluster.
    for ([_]u16{ min_shade_width, 40, 80 }) |w| {
        var s = try screen.Screen.init(gpa, w, shade_height);
        defer s.deinit();
        s.clear(.plain);
        drawShade(s.painter(s.bounds()), .{ .theme = .classic }, .{});

        try testing.expectEqual(@as(u21, '?'), s.get(w - 8, 0).?.cp);
        try testing.expectEqual(
            try std.unicode.utf8Decode(Theme.classic.glyphs.win_close),
            s.get(w - 4, 0).?.cp,
        );
    }
}

test "clicking a slider's ends yields its extreme values" {
    const l: Layout = .compute();

    const seek_lo = l.hitTest(.{ .x = l.seek.x, .y = l.seek.y });
    try testing.expectApproxEqAbs(@as(f32, 0), seek_lo.seek, 0.001);
    const seek_hi = l.hitTest(.{ .x = l.seek.right() - 1, .y = l.seek.y });
    try testing.expectApproxEqAbs(@as(f32, 1), seek_hi.seek, 0.001);

    const vol_hi = l.hitTest(.{ .x = l.volume.right() - 1, .y = l.volume.y });
    try testing.expectApproxEqAbs(@as(f32, 1), vol_hi.volume, 0.001);

    // Balance is centred, so its midpoint must read as zero.
    const bal_mid = l.hitTest(.{ .x = l.balance.x + l.balance.w / 2, .y = l.balance.y });
    try testing.expectApproxEqAbs(@as(f32, 0), bal_mid.balance, 0.11);
    const bal_lo = l.hitTest(.{ .x = l.balance.x, .y = l.balance.y });
    try testing.expectApproxEqAbs(@as(f32, -1), bal_lo.balance, 0.001);
    const bal_hi = l.hitTest(.{ .x = l.balance.right() - 1, .y = l.balance.y });
    try testing.expectApproxEqAbs(@as(f32, 1), bal_hi.balance, 0.001);
}

/// Dump the window as plain text, for golden-style assertions.
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

test "draw produces a framed window and touches no cell outside it" {
    var s = try screen.Screen.init(testing.allocator, width + 4, height + 2);
    defer s.deinit();
    s.clear(.plain);

    const l: Layout = .compute();
    const origin: Rect = .{ .x = 2, .y = 1, .w = width, .h = height };
    draw(s.painter(origin), l, .{
        .theme = .classic,
        .state = .playing,
        .title = "Terra's Theme",
        .clock_secs = 95,
        .progress = 0.33,
        .volume = 0.1,
        .kbps = 192,
        .sample_rate = 44100,
        .channels = 2,
        .track_index = 2,
        .track_count = 40,
    }, .{});

    const text = try renderText(&s, testing.allocator);
    defer testing.allocator.free(text);

    // The frame corners landed where the origin says they should.
    try testing.expectEqual(@as(u21, '┌'), s.get(2, 1).?.cp);
    try testing.expectEqual(@as(u21, '┐'), s.get(2 + width - 1, 1).?.cp);
    try testing.expectEqual(@as(u21, '└'), s.get(2, 1 + height - 1).?.cp);
    try testing.expectEqual(@as(u21, '┘'), s.get(2 + width - 1, 1 + height - 1).?.cp);

    // Nothing bled into the margin around the window.
    for (0..s.rows) |y| {
        try testing.expectEqual(@as(u21, ' '), s.get(0, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(1, @intCast(y)).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(s.cols - 1, @intCast(y)).?.cp);
    }
    for (0..s.cols) |x| {
        try testing.expectEqual(@as(u21, ' '), s.get(@intCast(x), 0).?.cp);
        try testing.expectEqual(@as(u21, ' '), s.get(@intCast(x), s.rows - 1).?.cp);
    }

    // The things a user reads are actually on screen.
    try testing.expect(std.mem.indexOf(u8, text, "tuiamp") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Terra's Theme") != null);
    try testing.expect(std.mem.indexOf(u8, text, "192 kbps") != null);
    try testing.expect(std.mem.indexOf(u8, text, "44 kHz") != null);
    try testing.expect(std.mem.indexOf(u8, text, "stereo") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shuffle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3/40") != null);
}

test "ascii theme draws without any non-ASCII glyph" {
    var s = try screen.Screen.init(testing.allocator, width, height);
    defer s.deinit();
    s.clear(.plain);

    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .ascii,
        .state = .paused,
        .title = "A Track",
        .clock_secs = 61,
        .volume = 0.5,
        .kbps = 320,
        .sample_rate = 48000,
        .channels = 1,
    }, .{});

    const text = try renderText(&s, testing.allocator);
    defer testing.allocator.free(text);
    for (text) |b| try testing.expect(b < 0x80);
    try testing.expect(std.mem.indexOf(u8, text, "mono") != null);
}

test "shade mode stays within two rows" {
    var s = try screen.Screen.init(testing.allocator, width, height);
    defer s.deinit();
    s.clear(.plain);

    drawShade(s.painter(.{ .x = 0, .y = 0, .w = width, .h = shade_height }), .{
        .theme = .classic,
        .state = .playing,
        .title = "Shaded",
        .clock_secs = 7,
    }, .{});

    const text = try renderText(&s, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Shaded") != null);

    // Row 2 and below were never touched.
    var y: u16 = shade_height;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            try testing.expectEqual(@as(u21, ' '), s.get(x, y).?.cp);
        }
    }
}

test "stopped state shows a dim seek thumb and no crash with zero progress" {
    var s = try screen.Screen.init(testing.allocator, width, height);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), .compute(), .{ .theme = .classic, .state = .stopped }, .{});
    const text = try renderText(&s, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "-- kbps") != null);
}
