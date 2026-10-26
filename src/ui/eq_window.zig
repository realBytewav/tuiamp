//! Winamp's graphic equalizer window.
//!
//! Eleven vertical sliders — preamp, then ten bands — above a frequency
//! scale, with the on/auto toggles and the current preset along the top.
//!
//! Each slider gets half-block resolution: nine rows is only nine positions
//! across 24dB, which would make the control feel notchy, so the thumb is
//! placed on one of eighteen sub-rows instead.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Theme = @import("theme.zig").Theme;
const eq = @import("../audio/eq.zig");

pub const width: u16 = 80;
pub const height: u16 = 14;
pub const shade_height: u16 = 3;

/// Slider geometry.
const slider_rows: u16 = 9;
/// Sub-rows above or below centre, so the full travel is ±12dB.
const sub_steps: i32 = 8;
const slider_w: u16 = 5;
const bar_w: u16 = 3;

const scale_x: u16 = 2;
const preamp_x: u16 = 7;
const bands_x: u16 = 14;
const sliders_y: u16 = 3;

/// Which control a point lands on. `band` indexes `eq.band_frequencies`.
pub const Hit = union(enum) {
    none,
    titlebar,
    shade,
    close,
    toggle_enabled,
    toggle_auto,
    preset,
    preamp: f32,
    band: struct { index: usize, gain_db: f32 },
};

pub const Layout = struct {
    frame: Rect,
    titlebar: Rect,
    shade_btn: Rect,
    close_btn: Rect,
    on_btn: Rect,
    auto_btn: Rect,
    preset_btn: Rect,
    preamp: Rect,
    bands: [eq.band_count]Rect,
    labels: Rect,

    pub fn compute() Layout {
        var bands: [eq.band_count]Rect = undefined;
        for (&bands, 0..) |*r, i| {
            r.* = .{
                .x = bands_x + @as(u16, @intCast(i)) * slider_w,
                .y = sliders_y,
                .w = bar_w,
                .h = slider_rows,
            };
        }
        return .{
            .frame = .{ .x = 0, .y = 0, .w = width, .h = height },
            .titlebar = .{ .x = 0, .y = 0, .w = width, .h = 1 },
            .shade_btn = .{ .x = width - 6, .y = 0, .w = 1, .h = 1 },
            .close_btn = .{ .x = width - 4, .y = 0, .w = 1, .h = 1 },
            .on_btn = .{ .x = 2, .y = 1, .w = 6, .h = 1 },
            .auto_btn = .{ .x = 10, .y = 1, .w = 8, .h = 1 },
            .preset_btn = .{ .x = 21, .y = 1, .w = 22, .h = 1 },
            .preamp = .{ .x = preamp_x, .y = sliders_y, .w = bar_w, .h = slider_rows },
            .bands = bands,
            .labels = .{ .x = 0, .y = sliders_y + slider_rows, .w = width, .h = 1 },
        };
    }

    pub fn hitTest(l: Layout, p: Point) Hit {
        if (l.close_btn.contains(p)) return .close;
        if (l.shade_btn.contains(p)) return .shade;
        if (l.titlebar.contains(p)) return .titlebar;
        if (l.on_btn.contains(p)) return .toggle_enabled;
        if (l.auto_btn.contains(p)) return .toggle_auto;
        if (l.preset_btn.contains(p)) return .preset;

        // Sliders get a column of slack either side, so the gaps between
        // them are not dead space the mouse falls into.
        if (hitSlider(l.preamp, p)) |gain| return .{ .preamp = gain };
        for (l.bands, 0..) |r, i| {
            if (hitSlider(r, p)) |gain| {
                return .{ .band = .{ .index = i, .gain_db = gain } };
            }
        }
        return .none;
    }

    fn hitSlider(r: Rect, p: Point) ?f32 {
        const widened: Rect = .{ .x = r.x -| 1, .y = r.y, .w = r.w + 2, .h = r.h };
        const q = widened.localize(p) orelse return null;
        return gainForRow(q.y);
    }
};

/// Decibel value for a click on row `row` of a slider.
pub fn gainForRow(row: u16) f32 {
    const centre: f32 = @floatFromInt(slider_rows / 2);
    const offset = centre - @as(f32, @floatFromInt(row));
    const gain = offset / centre * eq.gain_limit_db;
    return std.math.clamp(gain, -eq.gain_limit_db, eq.gain_limit_db);
}

/// Sub-row offset from centre for a gain, positive upward.
fn subOffsetForGain(gain_db: f32) i32 {
    const clamped = std.math.clamp(gain_db, -eq.gain_limit_db, eq.gain_limit_db);
    const scaled = clamped / eq.gain_limit_db * @as(f32, @floatFromInt(sub_steps));
    return @intFromFloat(@round(scaled));
}

pub const View = struct {
    theme: Theme,
    focused: bool = false,
    settings: eq.Settings = .{},
    auto: bool = false,
    preset_name: []const u8 = "Flat",
    /// Highlighted control: 0 is the preamp, 1..10 are the bands.
    cursor: usize = 0,
};

pub fn draw(p: Painter, l: Layout, v: View) void {
    const th = v.theme;
    p.fill(.{ .bg = .{ .rgb = th.bg } });
    drawFrame(p, l, v);

    // Toggles and preset.
    drawButton(p, l.on_btn, if (v.settings.enabled) "[ ON ]" else "[ off]", v.settings.enabled, th);
    drawButton(p, l.auto_btn, if (v.auto) "[ AUTO ]" else "[ auto ]", v.auto, th);
    var buf: [48]u8 = undefined;
    const preset = std.fmt.bufPrint(&buf, "preset: {s}", .{v.preset_name}) catch "preset:";
    _ = p.text(l.preset_btn.x, l.preset_btn.y, preset, th.onBg(th.text));

    // Decibel scale down the left.
    const centre_row = sliders_y + slider_rows / 2;
    _ = p.text(scale_x, sliders_y, "+12", th.onBg(th.text_dim));
    _ = p.text(scale_x, centre_row, "  0", th.onBg(th.text_dim));
    _ = p.text(scale_x, sliders_y + slider_rows - 1, "-12", th.onBg(th.text_dim));

    drawSlider(p, l.preamp, v.settings.preamp_db, v.cursor == 0, th);
    for (l.bands, 0..) |r, i| {
        drawSlider(p, r, v.settings.bands_db[i], v.cursor == i + 1, th);
    }

    // Frequency scale.
    _ = p.text(preamp_x - 1, l.labels.y, " pre ", th.onBg(th.text_dim));
    for (l.bands, 0..) |r, i| {
        const hz = eq.band_frequencies[i];
        const label = if (hz >= 1000)
            std.fmt.bufPrint(&buf, "{d}k", .{@as(u32, @intFromFloat(hz)) / 1000}) catch ""
        else
            std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(hz))}) catch "";
        const pad: u16 = if (bar_w > label.len) (bar_w - @as(u16, @intCast(label.len))) / 2 else 0;
        _ = p.text(r.x + pad, l.labels.y, label, th.onBg(th.text_dim));
    }

    // A reminder that switching the EQ on changes nothing while it is flat.
    if (v.settings.enabled and v.settings.isFlat()) {
        _ = p.text(l.preset_btn.x, height - 2, "(flat: no change)", th.onBg(th.text_dim));
    }
}

fn drawSlider(p: Painter, r: Rect, gain_db: f32, selected: bool, th: Theme) void {
    const g = th.glyphs;
    const centre_row: i32 = @intCast(slider_rows / 2);
    const offset = subOffsetForGain(gain_db);

    const track_style = th.onBg(th.track);
    const fill_rgb = if (selected) th.thumb else th.fill;
    const fill_style = th.onBg(fill_rgb);

    // The groove, with a tick at zero so centre is findable at a glance.
    var row: u16 = 0;
    while (row < r.h) : (row += 1) {
        const cp: u21 = if (@as(i32, row) == centre_row) g.h else g.v;
        var col: u16 = 0;
        while (col < r.w) : (col += 1) {
            p.set(r.x + col, r.y + row, .{ .cp = cp, .style = track_style });
        }
    }

    // Fill from centre toward the thumb, in half-row steps.
    const centre_sub = centre_row * 2 + 1;
    const target_sub = centre_sub - offset * 2;
    const lo = @min(centre_sub, target_sub);
    const hi = @max(centre_sub, target_sub);

    var sub = lo;
    while (sub <= hi) : (sub += 1) {
        if (sub < 0) continue;
        const cell_row: u16 = @intCast(@divFloor(sub, 2));
        if (cell_row >= r.h) continue;
        const upper = @mod(sub, 2) == 0;

        var col: u16 = 0;
        while (col < r.w) : (col += 1) {
            const at = p.screen.get(p.rect.x + r.x + col, p.rect.y + r.y + cell_row);
            const already_half = at != null and
                (at.?.cp == g.scope_hi or at.?.cp == g.scope_lo);
            const cp: u21 = if (already_half)
                g.scope
            else if (upper)
                g.scope_hi
            else
                g.scope_lo;
            p.set(r.x + col, r.y + cell_row, .{ .cp = cp, .style = fill_style });
        }
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

    _ = p.text(2, 0, " Equalizer ", th.onBg(th.title_fg));
    p.fillRect(.{ .x = l.shade_btn.x - 1, .y = 0, .w = 6, .h = 1 }, ' ', th.onBg(th.button));
    _ = p.text(l.shade_btn.x, 0, g.win_shade, th.onBg(th.button));
    _ = p.text(l.close_btn.x, 0, g.win_close, th.onBg(th.button));
}

fn drawButton(p: Painter, r: Rect, label: []const u8, active: bool, th: Theme) void {
    _ = p.text(r.x, r.y, label, th.onBg(if (active) th.button_active else th.button));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "layout stays inside the frame and the sliders do not overlap" {
    const l: Layout = .compute();
    try testing.expect(l.preamp.right() < l.bands[0].x);
    for (l.bands, 0..) |a, i| {
        try testing.expect(a.right() <= width);
        try testing.expect(a.bottom() <= height);
        for (l.bands[i + 1 ..]) |b| {
            try testing.expect(a.right() <= b.x or b.right() <= a.x);
        }
    }
    try testing.expect(l.labels.bottom() < height);
}

test "gainForRow spans the full range with zero in the middle" {
    try testing.expectApproxEqAbs(eq.gain_limit_db, gainForRow(0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), gainForRow(slider_rows / 2), 0.001);
    try testing.expectApproxEqAbs(-eq.gain_limit_db, gainForRow(slider_rows - 1), 0.001);
    // Monotonically decreasing downward.
    var prev: f32 = 100;
    for (0..slider_rows) |r| {
        const g = gainForRow(@intCast(r));
        try testing.expect(g < prev);
        prev = g;
    }
}

test "subOffsetForGain is symmetric and clamped" {
    try testing.expectEqual(@as(i32, 0), subOffsetForGain(0));
    try testing.expectEqual(sub_steps, subOffsetForGain(eq.gain_limit_db));
    try testing.expectEqual(-sub_steps, subOffsetForGain(-eq.gain_limit_db));
    try testing.expectEqual(sub_steps, subOffsetForGain(99));
    try testing.expectEqual(-sub_steps, subOffsetForGain(-99));
    try testing.expectEqual(-subOffsetForGain(6), subOffsetForGain(-6));
    // Half-row resolution means 1.5dB is distinguishable from zero.
    try testing.expect(subOffsetForGain(1.5) != 0);
}

test "hitTest finds the controls, including between the sliders" {
    const l: Layout = .compute();

    try testing.expectEqual(Hit.close, l.hitTest(.{ .x = l.close_btn.x, .y = 0 }));
    try testing.expectEqual(Hit.toggle_enabled, l.hitTest(.{ .x = l.on_btn.x + 1, .y = 1 }));
    try testing.expectEqual(Hit.toggle_auto, l.hitTest(.{ .x = l.auto_btn.x, .y = 1 }));
    try testing.expectEqual(Hit.preset, l.hitTest(.{ .x = l.preset_btn.x + 3, .y = 1 }));

    // Top of band 0 is full boost.
    const top = l.hitTest(.{ .x = l.bands[0].x, .y = sliders_y });
    try testing.expectEqual(@as(usize, 0), top.band.index);
    try testing.expectApproxEqAbs(eq.gain_limit_db, top.band.gain_db, 0.001);

    // Bottom of the last band is full cut.
    const last = eq.band_count - 1;
    const bottom = l.hitTest(.{ .x = l.bands[last].x, .y = sliders_y + slider_rows - 1 });
    try testing.expectEqual(last, bottom.band.index);
    try testing.expectApproxEqAbs(-eq.gain_limit_db, bottom.band.gain_db, 0.001);

    // The preamp is its own control.
    const pre = l.hitTest(.{ .x = l.preamp.x + 1, .y = sliders_y + slider_rows / 2 });
    try testing.expectApproxEqAbs(@as(f32, 0), pre.preamp, 0.001);

    // The gap between two bands still grabs a slider rather than nothing.
    const gap_x = l.bands[0].right();
    try testing.expect(l.hitTest(.{ .x = gap_x, .y = sliders_y }) != .none);

    // Well away from everything is nothing.
    try testing.expectEqual(Hit.none, l.hitTest(.{ .x = width - 2, .y = height - 2 }));
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

test "draw shows the scale, the toggles and every band label" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);

    var settings: eq.Settings = .{ .enabled = true };
    settings.bands_db = eq.presetByName("Rock").?.bands_db;

    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .classic,
        .settings = settings,
        .preset_name = "Rock",
    });

    const text = try renderText(&s, gpa);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Equalizer") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[ ON ]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "preset: Rock") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+12") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-12") != null);
    try testing.expect(std.mem.indexOf(u8, text, "60") != null);
    try testing.expect(std.mem.indexOf(u8, text, "16k") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pre") != null);
}

test "an enabled but flat EQ says so" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .classic,
        .settings = .{ .enabled = true },
    });
    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "(flat: no change)") != null);
}

test "extreme settings draw inside the slider area" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();

    for ([_]f32{ -eq.gain_limit_db, -6, 0, 6, eq.gain_limit_db, 99, -99 }) |g| {
        s.clear(.plain);
        draw(s.painter(s.bounds()), .compute(), .{
            .theme = .classic,
            .settings = .{ .enabled = true, .preamp_db = g, .bands_db = @splat(g) },
        });
        // The frame survived, so nothing drew over it.
        try testing.expectEqual(@as(u21, '\u{2502}'), s.get(0, 5).?.cp);
        try testing.expectEqual(@as(u21, '\u{2502}'), s.get(width - 1, 5).?.cp);
        try testing.expectEqual(@as(u21, '\u{2514}'), s.get(0, height - 1).?.cp);
    }
}

test "the ascii theme draws the equalizer without non-ASCII glyphs" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);
    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .ascii,
        .settings = .{ .enabled = true, .preamp_db = 6, .bands_db = @splat(-3) },
    });
    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    for (text) |b| try testing.expect(b < 0x80);
}
