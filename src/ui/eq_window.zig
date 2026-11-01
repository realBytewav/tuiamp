//! Winamp's graphic equalizer window.
//!
//! Eleven vertical sliders — preamp, then ten bands — above a frequency
//! scale, with the on/auto toggles and the current preset along the top.
//!
//! Nine rows is nine positions across 24dB, which makes the control feel
//! notchy. The gain is an f32 and the biquads take whatever they are given,
//! so that coarseness is the display's alone — and worth some trouble to be
//! rid of. Each cell is split into eighths with block glyphs, which puts 32
//! steps either side of centre, about a third of a decibel each.
//!
//! Filling upward is what block glyphs do naturally. Downward is the
//! awkward half: Unicode grows eighths up from the bottom of a cell
//! (`▁▂▃`), but going down from the top it has only `▔` and `▀`. So the
//! downward fill draws the same upward glyph with the foreground and
//! background swapped, painting the complement. A theme whose `bars` are a
//! symbolic ladder rather than real blocks has no complement to paint and
//! says so with `glyphs.block_fill`; those keep the old half-row fill.
//!
//! The centre row is never filled. The zero tick lives there, and reserving
//! it keeps the travel symmetric and leaves every partial cell anchored to
//! an edge a block glyph can actually draw from.
//!
//! A third of a decibel is also not readable off a bar, so the titlebar
//! carries the exact value — which is where Winamp put it while you dragged.

const std = @import("std");
const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen = @import("../term/screen.zig");
const Painter = screen.Painter;
const Style = screen.Style;
const Rgb = screen.Rgb;
const Theme = @import("theme.zig").Theme;
const eq = @import("../audio/eq.zig");

pub const width: u16 = 80;
pub const height: u16 = 14;
pub const shade_height: u16 = 3;

/// Slider geometry.
const slider_rows: u16 = 9;
/// Rows of fill either side of the centre tick, which stays empty.
const fill_rows: u16 = slider_rows / 2;
/// Sub-rows above or below centre, so the full travel is ±12dB: eighths of
/// a cell, over the rows that can be filled.
const sub_steps: i32 = fill_rows * 8;
/// Decibels per displayed step, which is what the fine controls aim at.
pub const display_step_db: f32 = eq.gain_limit_db / @as(f32, @floatFromInt(sub_steps));
/// The same, for a theme that cannot do eighths: half a row.
const half_steps: i32 = fill_rows * 2;
const slider_w: u16 = 5;
const bar_w: u16 = 3;

const scale_x: u16 = 2;
/// Clear of " Equalizer " on the titlebar, and well clear of the buttons.
const readout_x: u16 = 15;
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

/// Decibel value for a click on row `row` of a slider. This is the coarse
/// half of the mouse: a press on the track jumps here, in 3dB rows, and the
/// drag that follows is relative and fine from wherever it landed.
pub fn gainForRow(row: u16) f32 {
    const centre: f32 = @floatFromInt(slider_rows / 2);
    const offset = centre - @as(f32, @floatFromInt(row));
    const gain = offset / centre * eq.gain_limit_db;
    return std.math.clamp(gain, -eq.gain_limit_db, eq.gain_limit_db);
}

/// The row a slider's fill ends on, which is where its thumb appears to be.
/// Pressing there means "take hold of this value"; pressing anywhere else on
/// the track means "go to this row".
pub fn rowForGain(gain_db: f32) u16 {
    const centre_row: u16 = slider_rows / 2;
    const offset = subOffsetForGain(gain_db);
    if (offset == 0) return centre_row;
    const mag: u16 = @intCast(@abs(offset));
    // The outermost filled eighth, counted from the top of the track.
    const tip: u16 = if (offset > 0)
        centre_row * 8 - mag
    else
        (centre_row + 1) * 8 + mag - 1;
    return @min(tip / 8, slider_rows - 1);
}

/// Sub-row offset from centre for a gain, positive upward.
fn subOffsetForGain(gain_db: f32) i32 {
    return offsetForGain(gain_db, sub_steps);
}

/// The same in half-rows, for the themes that fill that way.
fn halfOffsetForGain(gain_db: f32) i32 {
    return offsetForGain(gain_db, half_steps);
}

fn offsetForGain(gain_db: f32, steps: i32) i32 {
    const clamped = std.math.clamp(gain_db, -eq.gain_limit_db, eq.gain_limit_db);
    const scaled = clamped / eq.gain_limit_db * @as(f32, @floatFromInt(steps));
    return @intFromFloat(@round(scaled));
}

/// Gain of one control: 0 is the preamp, 1..band_count the bands. The
/// windows address them by that one index, so the mapping lives here rather
/// than in each caller.
pub fn gainOf(s: eq.Settings, control: usize) f32 {
    if (control == 0) return s.preamp_db;
    return s.bands_db[@min(control - 1, eq.band_count - 1)];
}

/// `60 Hz: +4.3 dB`, for the titlebar. Writes into `buf`, which wants 24
/// bytes for the longest of them.
pub fn gainReadout(buf: []u8, control: usize, gain_db: f32) []const u8 {
    // Below a tenth of a step there is nothing to report but zero, and zero
    // should not be shown as negative because of a rounding crumb.
    const sign: u8 = if (gain_db <= -display_step_db / 10) '-' else '+';
    const mag = @abs(gain_db);
    if (control == 0) {
        return std.fmt.bufPrint(buf, "preamp: {c}{d:.1} dB", .{ sign, mag }) catch "";
    }
    const i = @min(control - 1, eq.band_count - 1);
    const hz: u32 = @intFromFloat(eq.band_frequencies[i]);
    return std.fmt.bufPrint(buf, "{d} Hz: {c}{d:.1} dB", .{ hz, sign, mag }) catch "";
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

    // The exact value of whichever control the cursor is on. Winamp wrote it
    // into the titlebar while a slider was being dragged; here the cursor is
    // always somewhere, so it is always worth saying.
    var readout_buf: [24]u8 = undefined;
    const readout = gainReadout(&readout_buf, v.cursor, gainOf(v.settings, v.cursor));
    _ = p.text(readout_x, 0, readout, th.onBg(th.title_fg_dim));

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
    // It goes beside the preset, not under the sliders: the row below them
    // is the frequency scale, and this used to be drawn straight over it.
    if (v.settings.enabled and v.settings.isFlat()) {
        _ = p.text(l.preset_btn.right() + 2, l.preset_btn.y, "(flat: no change)", th.onBg(th.text_dim));
    }
}

fn drawSlider(p: Painter, r: Rect, gain_db: f32, selected: bool, th: Theme) void {
    const g = th.glyphs;
    const centre_row: u16 = slider_rows / 2;
    const fill_rgb = if (selected) th.thumb else th.fill;

    // The groove, with a tick at zero so centre is findable at a glance.
    // The tick also carries the cursor: a selected slider sitting at 0dB has
    // nothing filled, and would otherwise look like every other one.
    const track_style = th.onBg(th.track);
    const tick_style = th.onBg(if (selected) fill_rgb else th.track);
    var row: u16 = 0;
    while (row < r.h) : (row += 1) {
        const centred = row == centre_row;
        const cp: u21 = if (centred) g.h else g.v;
        const style = if (centred) tick_style else track_style;
        var col: u16 = 0;
        while (col < r.w) : (col += 1) {
            p.set(r.x + col, r.y + row, .{ .cp = cp, .style = style });
        }
    }

    if (!g.block_fill) return drawHalfFill(p, r, gain_db, fill_rgb, th);

    const offset = subOffsetForGain(gain_db);
    // Nothing is filled at zero; the tick is the mark.
    if (offset == 0) return;

    const up = offset > 0;
    const mag: u16 = @intCast(@abs(offset));
    // Eighths measured from the top of the slider. The centre row is
    // skipped, so an upward fill ends at its top edge and a downward one
    // starts below its bottom edge.
    const lo: u16 = if (up) centre_row * 8 - mag else (centre_row + 1) * 8;
    const hi: u16 = lo + mag;

    const up_style: Style = .{ .fg = .{ .rgb = fill_rgb }, .bg = .{ .rgb = th.bg } };
    // Swapped, so what the glyph leaves blank is what reads as filled, and
    // the painted eighths sit at the top of the cell instead of the bottom.
    const down_style: Style = .{ .fg = .{ .rgb = th.bg }, .bg = .{ .rgb = fill_rgb } };

    var e: u16 = lo;
    while (e < hi) {
        const cell_row = e / 8;
        const end = @min((cell_row + 1) * 8, hi);
        const eighths = end - e;
        if (cell_row < r.h) {
            const cp: u21 = if (up) g.bars[eighths] else g.bars[8 - eighths];
            var col: u16 = 0;
            while (col < r.w) : (col += 1) {
                p.set(r.x + col, r.y + cell_row, .{
                    .cp = cp,
                    .style = if (up) up_style else down_style,
                });
            }
        }
        e = end;
    }
}

/// Half-row fill, for themes whose `bars` are a density ladder rather than
/// real blocks. Coarser — 1.5dB a step — but it needs only the three scope
/// glyphs, and those every theme has to mean something by.
fn drawHalfFill(p: Painter, r: Rect, gain_db: f32, fill_rgb: Rgb, th: Theme) void {
    const g = th.glyphs;
    const centre_row: i32 = @intCast(slider_rows / 2);
    const offset = halfOffsetForGain(gain_db);
    const fill_style = th.onBg(fill_rgb);

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
    // A third of a decibel a step, so a fine adjustment of half a decibel
    // always lands somewhere new. The point of the whole exercise is that
    // the display is no longer the thing limiting the control.
    try testing.expect(display_step_db < 0.4);
    var k: i32 = 1;
    while (k <= 24) : (k += 1) {
        const db = @as(f32, @floatFromInt(k)) * 0.5;
        try testing.expect(subOffsetForGain(db) > subOffsetForGain(db - 0.5));
        try testing.expect(subOffsetForGain(-db) < subOffsetForGain(-db + 0.5));
    }
}

test "rowForGain finds the row the fill ends on" {
    const centre = slider_rows / 2;
    try testing.expectEqual(centre, rowForGain(0));
    // The extremes are the first and last rows, and nothing goes past them.
    try testing.expectEqual(@as(u16, 0), rowForGain(eq.gain_limit_db));
    try testing.expectEqual(slider_rows - 1, rowForGain(-eq.gain_limit_db));
    try testing.expectEqual(@as(u16, 0), rowForGain(99));
    try testing.expectEqual(slider_rows - 1, rowForGain(-99));
    // The smallest boost that draws anything is already off the tick row,
    // so a press on the tick never grabs a slider that has moved.
    try testing.expect(rowForGain(display_step_db) < centre);
    try testing.expect(rowForGain(-display_step_db) > centre);

    // It has to agree with what is drawn, or a press on the visible tip of
    // the bar would miss it.
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    const th: Theme = .classic;
    const l: Layout = .compute();
    for ([_]f32{ 0, 0.5, 1.5, 3, 7.5, eq.gain_limit_db, -0.5, -3, -eq.gain_limit_db }) |db| {
        s.clear(.plain);
        draw(s.painter(s.bounds()), l, .{ .theme = th, .settings = .{ .preamp_db = db } });
        const row = rowForGain(db);
        const cell = s.get(l.preamp.x, l.preamp.y + row).?;
        if (db == 0) {
            try testing.expectEqual(th.glyphs.h, cell.cp);
        } else {
            // Something of the fill is in that cell: either its glyph or,
            // for the downward half, its colour.
            const filled = cell.cp != th.glyphs.v and cell.cp != th.glyphs.h;
            const coloured = cell.style.bg.eql(.{ .rgb = th.fill });
            try testing.expect(filled or coloured);
        }
    }
}

test "gainOf picks out the preamp and the bands" {
    var settings: eq.Settings = .{ .preamp_db = -3 };
    settings.bands_db[0] = 1;
    settings.bands_db[eq.band_count - 1] = 2;
    try testing.expectEqual(@as(f32, -3), gainOf(settings, 0));
    try testing.expectEqual(@as(f32, 1), gainOf(settings, 1));
    try testing.expectEqual(@as(f32, 2), gainOf(settings, eq.band_count));
    // Past the end clamps rather than reading off it.
    try testing.expectEqual(@as(f32, 2), gainOf(settings, eq.band_count + 7));
}

test "the readout names the control and its exact value" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("preamp: +0.0 dB", gainReadout(&buf, 0, 0));
    try testing.expectEqualStrings("60 Hz: +4.5 dB", gainReadout(&buf, 1, 4.5));
    try testing.expectEqualStrings("600 Hz: -7.0 dB", gainReadout(&buf, 4, -7));
    try testing.expectEqualStrings(
        "16000 Hz: -12.0 dB",
        gainReadout(&buf, eq.band_count, -eq.gain_limit_db),
    );
    // The values a click cannot reach are the ones worth printing.
    try testing.expectEqualStrings("170 Hz: +0.5 dB", gainReadout(&buf, 2, 0.5));
    // A rounding crumb below zero is still zero, not "-0.0".
    try testing.expectEqualStrings("preamp: +0.0 dB", gainReadout(&buf, 0, -0.001));
    // And nothing reads off the end of the band table.
    _ = gainReadout(&buf, 99, 0);
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

/// Eighths of fill drawn in a slider's first column, positive for a boost.
/// The tests read the cells back rather than trusting the arithmetic that
/// put them there: the downward half is drawn as the *complement* of a
/// glyph with the colours swapped, which is exactly the sort of trick that
/// looks right in the code and wrong on screen.
fn drawnEighths(s: *const screen.Screen, r: Rect, th: Theme) i32 {
    const centre_row = slider_rows / 2;
    var total: i32 = 0;
    for (0..r.h) |row| {
        if (row == centre_row) continue;
        const cell = s.get(r.x, r.y + @as(u16, @intCast(row))).?;
        const inverted = cell.style.bg.eql(.{ .rgb = th.fill }) or
            cell.style.bg.eql(.{ .rgb = th.thumb });
        var painted: i32 = 0;
        for (th.glyphs.bars, 0..) |g, level| {
            if (g != cell.cp) continue;
            painted = if (inverted) 8 - @as(i32, @intCast(level)) else @intCast(level);
            break;
        }
        total += if (row < centre_row) painted else -painted;
    }
    return total;
}

test "the fill mirrors about the centre row and never covers its tick" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();

    const th: Theme = .classic;
    const l: Layout = .compute();
    const centre_y = l.preamp.y + slider_rows / 2;

    for ([_]f32{ 0.5, 1.5, 3, 7.5, eq.gain_limit_db }) |db| {
        s.clear(.plain);
        draw(s.painter(s.bounds()), l, .{ .theme = th, .settings = .{ .preamp_db = db } });
        const boost = drawnEighths(&s, l.preamp, th);
        try testing.expectEqual(th.glyphs.h, s.get(l.preamp.x, centre_y).?.cp);
        try testing.expect(boost > 0);

        s.clear(.plain);
        draw(s.painter(s.bounds()), l, .{ .theme = th, .settings = .{ .preamp_db = -db } });
        const cut = drawnEighths(&s, l.preamp, th);
        try testing.expectEqual(th.glyphs.h, s.get(l.preamp.x, centre_y).?.cp);
        try testing.expectEqual(boost, -cut);
    }

    // Full travel is the whole of both halves, and no more.
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{
        .theme = th,
        .settings = .{ .preamp_db = eq.gain_limit_db },
    });
    try testing.expectEqual(sub_steps, drawnEighths(&s, l.preamp, th));
}

test "every fine step is visible on the slider, not just in the number" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();

    const th: Theme = .classic;
    const l: Layout = .compute();

    // Half a decibel is what shift+arrow and a wheel notch move. If the
    // drawing cannot show one, the control is still notchy however precise
    // the value behind it has become — which was the whole complaint.
    var prev: i32 = std.math.minInt(i32);
    var db: f32 = -eq.gain_limit_db;
    while (db <= eq.gain_limit_db) : (db += 0.5) {
        s.clear(.plain);
        draw(s.painter(s.bounds()), l, .{ .theme = th, .settings = .{ .preamp_db = db } });
        const drawn = drawnEighths(&s, l.preamp, th);
        try testing.expect(drawn > prev);
        prev = drawn;
    }
}

test "a selected slider is visible even sitting at zero" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();

    const th: Theme = .classic;
    const l: Layout = .compute();
    const centre_y = l.preamp.y + slider_rows / 2;

    // Nothing is filled at 0dB, so the zero tick has to carry the cursor.
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = th, .cursor = 0 });
    try testing.expect(s.get(l.preamp.x, centre_y).?.style.fg.eql(.{ .rgb = th.thumb }));

    // And a slider the cursor is not on stays in the track colour.
    s.clear(.plain);
    draw(s.painter(s.bounds()), l, .{ .theme = th, .cursor = 1 });
    try testing.expect(s.get(l.preamp.x, centre_y).?.style.fg.eql(.{ .rgb = th.track }));
}

test "a theme without block glyphs still fills, at half-row resolution" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();

    // ascii's bars are a density ladder, so inverting one would paint
    // nonsense; it takes the scope-glyph path instead.
    try testing.expect(!Theme.ascii.glyphs.block_fill);
    s.clear(.plain);
    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .ascii,
        .settings = .{ .enabled = true, .preamp_db = 6, .bands_db = @splat(-6) },
    });
    const text = try renderText(&s, gpa);
    defer gpa.free(text);
    // scope_lo, which nothing else in this window draws.
    try testing.expect(std.mem.indexOf(u8, text, "_") != null);
}

test "draw shows the scale, the toggles and every band label" {
    const gpa = testing.allocator;
    var s = try screen.Screen.init(gpa, width, height);
    defer s.deinit();
    s.clear(.plain);

    var settings: eq.Settings = .{ .enabled = true };
    settings.bands_db = eq.presetByName("Rock").?.bands_db;
    settings.bands_db[1] = 4.5;

    draw(s.painter(s.bounds()), .compute(), .{
        .theme = .classic,
        .settings = settings,
        .preset_name = "Rock",
        .cursor = 2,
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
    // The titlebar reports what the cursor is on, to a decimal the bar
    // itself could never be read to.
    try testing.expect(std.mem.indexOf(u8, text, "170 Hz: +4.5 dB") != null);
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
    // It used to be drawn on `height - 2`, which is the frequency scale's
    // own row, so the notice ate the labels behind it.
    for ([_][]const u8{ "pre", "60", "170", "1k", "16k" }) |label| {
        try testing.expect(std.mem.indexOf(u8, text, label) != null);
    }
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
