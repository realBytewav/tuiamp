//! Palettes and glyph sets. A "skin" in tuiamp is a `Theme`.
//!
//! M6 loads these from ZON files; for now the two built-ins establish the
//! shape, and `ascii` proves the glyph indirection actually works by having
//! to survive without any box-drawing or block characters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const screen = @import("../term/screen.zig");
const Rgb = screen.Rgb;
const Style = screen.Style;

pub const Glyphs = struct {
    /// Nine levels of vertical fill, from empty to full. The visualizer
    /// quantizes bar heights into these.
    bars: [9]u21,
    /// Nine levels of left-to-right fill, for horizontal meters.
    hbars: [9]u21,
    /// Window frame: horizontal, vertical, and the four corners.
    h: u21,
    v: u21,
    tl: u21,
    tr: u21,
    bl: u21,
    br: u21,
    /// Slider track and thumb.
    track: u21,
    thumb: u21,
    /// Visualizer peak cap.
    peak: u21,
    /// Oscilloscope trace: a full cell, and the upper and lower halves, so
    /// the scope gets twice the vertical resolution of the box it lives in.
    scope: u21,
    scope_hi: u21,
    scope_lo: u21,
    /// LCD colon, drawn between the minute and second digits.
    colon: u21,
    /// Titlebar buttons: windowshade and close.
    win_shade: []const u8,
    win_close: []const u8,
    /// Separates the title from its repeat when the marquee wraps.
    sep: []const u8,
    /// Single-glyph marker for the playing entry in the playlist. Separate
    /// from the transport faces because those carry their own padding and
    /// must never be sliced — they are multi-byte.
    now_playing: []const u8,
    /// Transport button faces, in Winamp's order.
    prev: []const u8,
    play: []const u8,
    pause: []const u8,
    stop: []const u8,
    next: []const u8,
    eject: []const u8,

    pub const unicode: Glyphs = .{
        .bars = .{ ' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' },
        .hbars = .{ ' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█' },
        .h = '─',
        .v = '│',
        .tl = '┌',
        .tr = '┐',
        .bl = '└',
        .br = '┘',
        .track = '─',
        .thumb = '█',
        .peak = '▁',
        .scope = '█',
        .scope_hi = '▀',
        .scope_lo = '▄',
        .colon = '▪',
        .win_shade = "▁",
        .win_close = "✕",
        .sep = " ••• ",
        .now_playing = "▶",
        .prev = "|◀◀",
        .play = " ▶ ",
        .pause = " ❚❚",
        .stop = " ■ ",
        .next = "▶▶|",
        .eject = " ⏏ ",
    };

    pub const ascii: Glyphs = .{
        .bars = .{ ' ', '.', '.', ':', ':', '|', '|', '#', '#' },
        .hbars = .{ ' ', ' ', '.', '.', '-', '-', '=', '=', '#' },
        .h = '-',
        .v = '|',
        .tl = '+',
        .tr = '+',
        .bl = '+',
        .br = '+',
        .track = '-',
        .thumb = '#',
        .peak = '_',
        .scope = '#',
        .scope_hi = '-',
        .scope_lo = '_',
        .colon = ':',
        .win_shade = "_",
        .win_close = "x",
        .sep = " *** ",
        .now_playing = ">",
        .prev = "|<<",
        .play = " > ",
        .pause = " ||",
        .stop = "[ ]",
        .next = ">>|",
        .eject = " ^ ",
    };
};

pub const Theme = struct {
    name: []const u8,

    /// Window chrome.
    bg: Rgb,
    frame: Rgb,
    frame_focus: Rgb,
    title_bg: Rgb,
    title_fg: Rgb,
    title_fg_dim: Rgb,

    /// The readout panel: time, kbps, kHz, mono/stereo.
    lcd_bg: Rgb,
    lcd_fg: Rgb,
    lcd_dim: Rgb,

    /// General text.
    text: Rgb,
    text_dim: Rgb,
    text_bright: Rgb,

    /// Playlist.
    list_current: Rgb,
    list_sel_bg: Rgb,
    list_sel_fg: Rgb,

    /// Sliders and buttons.
    track: Rgb,
    fill: Rgb,
    thumb: Rgb,
    button: Rgb,
    button_active: Rgb,

    /// Visualizer gradient, sampled bottom to top, plus the peak-cap colour.
    vis_lo: Rgb,
    vis_mid: Rgb,
    vis_hi: Rgb,
    vis_peak: Rgb,

    glyphs: Glyphs,

    /// Winamp's base skin: green phosphor on near-black, blue-grey chrome.
    pub const classic: Theme = .{
        .name = "classic",
        .bg = .hex(0x1c1c20),
        .frame = .hex(0x3f3f46),
        .frame_focus = .hex(0x6e6e78),
        .title_bg = .hex(0x2b2b33),
        .title_fg = .hex(0x00e000),
        .title_fg_dim = .hex(0x4a7a4a),
        .lcd_bg = .hex(0x000000),
        .lcd_fg = .hex(0x00ff00),
        .lcd_dim = .hex(0x006000),
        .text = .hex(0x00d000),
        .text_dim = .hex(0x3f7f3f),
        .text_bright = .hex(0xc8ffc8),
        .list_current = .hex(0xffffff),
        .list_sel_bg = .hex(0x0000c6),
        .list_sel_fg = .hex(0xffffff),
        .track = .hex(0x37373f),
        .fill = .hex(0x00a000),
        .thumb = .hex(0xc8ffc8),
        .button = .hex(0x9a9aa4),
        .button_active = .hex(0xffffff),
        .vis_lo = .hex(0x00ff00),
        .vis_mid = .hex(0xffff00),
        .vis_hi = .hex(0xff2000),
        .vis_peak = .hex(0xc8c8c8),
        .glyphs = .unicode,
    };

    /// For terminals or fonts where block and box glyphs are not trustworthy.
    pub const ascii: Theme = blk: {
        var t = Theme.classic;
        t.name = "ascii";
        t.glyphs = .ascii;
        break :blk t;
    };

    pub fn byName(name: []const u8) ?Theme {
        const eq = std.mem.eql;
        if (eq(u8, name, "classic")) return .classic;
        if (eq(u8, name, "ascii")) return .ascii;
        return null;
    }

    /// Sample the visualizer gradient; `t` is 0 at the bottom of the box and
    /// 1 at the top.
    pub fn visColor(th: Theme, t: f32) Rgb {
        return if (t < 0.5)
            th.vis_lo.mix(th.vis_mid, t * 2)
        else
            th.vis_mid.mix(th.vis_hi, (t - 0.5) * 2);
    }

    pub fn onBg(th: Theme, fg: Rgb) Style {
        return .{ .fg = .{ .rgb = fg }, .bg = .{ .rgb = th.bg } };
    }

    pub fn onLcd(th: Theme, fg: Rgb) Style {
        return .{ .fg = .{ .rgb = fg }, .bg = .{ .rgb = th.lcd_bg } };
    }
};

test "visColor spans the gradient monotonically in red" {
    const th = Theme.classic;
    try std.testing.expectEqual(th.vis_lo.r, th.visColor(0).r);
    try std.testing.expectEqual(th.vis_hi.r, th.visColor(1).r);
    try std.testing.expect(th.visColor(0.25).r < th.visColor(0.75).r);
}

test "ascii theme keeps the palette but swaps glyphs" {
    try std.testing.expectEqual(Theme.classic.lcd_fg.g, Theme.ascii.lcd_fg.g);
    try std.testing.expectEqual(@as(u21, '#'), Theme.ascii.glyphs.thumb);
    try std.testing.expectEqual(@as(u21, '█'), Theme.classic.glyphs.thumb);
}

test "byName round-trips the built-ins" {
    try std.testing.expectEqualStrings("classic", Theme.byName("classic").?.name);
    try std.testing.expectEqualStrings("ascii", Theme.byName("ascii").?.name);
    try std.testing.expect(Theme.byName("nope") == null);
}

// --- loading from disk -----------------------------------------------------

/// The on-disk schema, kept separate from `Theme` so the file format can be
/// pleasant to write by hand: colours are hex integers and glyphs are
/// strings rather than codepoint numbers.
pub const File = struct {
    name: []const u8 = "custom",

    bg: u24,
    frame: u24,
    frame_focus: u24,
    title_bg: u24,
    title_fg: u24,
    title_fg_dim: u24,
    lcd_bg: u24,
    lcd_fg: u24,
    lcd_dim: u24,
    text: u24,
    text_dim: u24,
    text_bright: u24,
    list_current: u24,
    list_sel_bg: u24,
    list_sel_fg: u24,
    track: u24,
    fill: u24,
    thumb: u24,
    button: u24,
    button_active: u24,
    vis_lo: u24,
    vis_mid: u24,
    vis_hi: u24,
    vis_peak: u24,

    glyphs: GlyphFile,

    pub const GlyphFile = struct {
        /// Nine strings, empty to full.
        bars: [9][]const u8,
        hbars: [9][]const u8,
        h: []const u8,
        v: []const u8,
        tl: []const u8,
        tr: []const u8,
        bl: []const u8,
        br: []const u8,
        track: []const u8,
        thumb: []const u8,
        peak: []const u8,
        scope: []const u8,
        scope_hi: []const u8,
        scope_lo: []const u8,
        colon: []const u8,
        win_shade: []const u8,
        win_close: []const u8,
        sep: []const u8,
        now_playing: []const u8,
        prev: []const u8,
        play: []const u8,
        pause: []const u8,
        stop: []const u8,
        next: []const u8,
        eject: []const u8,
    };
};

/// Max size of a theme file. Anything larger is not one.
const max_theme_bytes = 256 << 10;

/// First codepoint of `s`, or `fallback` when it is empty or malformed. A
/// theme that misspells one glyph should lose that glyph, not fail to load.
fn firstCodepoint(s: []const u8, fallback: u21) u21 {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    return it.nextCodepoint() orelse fallback;
}

/// Convert a parsed file into a usable theme. Strings are borrowed from the
/// arena the file was parsed into, so that arena must outlive the theme.
pub fn fromFile(f: File) Theme {
    const d = Theme.classic.glyphs;
    var bars: [9]u21 = undefined;
    var hbars: [9]u21 = undefined;
    for (f.glyphs.bars, 0..) |s, i| bars[i] = firstCodepoint(s, d.bars[i]);
    for (f.glyphs.hbars, 0..) |s, i| hbars[i] = firstCodepoint(s, d.hbars[i]);

    return .{
        .name = f.name,
        .bg = .hex(f.bg),
        .frame = .hex(f.frame),
        .frame_focus = .hex(f.frame_focus),
        .title_bg = .hex(f.title_bg),
        .title_fg = .hex(f.title_fg),
        .title_fg_dim = .hex(f.title_fg_dim),
        .lcd_bg = .hex(f.lcd_bg),
        .lcd_fg = .hex(f.lcd_fg),
        .lcd_dim = .hex(f.lcd_dim),
        .text = .hex(f.text),
        .text_dim = .hex(f.text_dim),
        .text_bright = .hex(f.text_bright),
        .list_current = .hex(f.list_current),
        .list_sel_bg = .hex(f.list_sel_bg),
        .list_sel_fg = .hex(f.list_sel_fg),
        .track = .hex(f.track),
        .fill = .hex(f.fill),
        .thumb = .hex(f.thumb),
        .button = .hex(f.button),
        .button_active = .hex(f.button_active),
        .vis_lo = .hex(f.vis_lo),
        .vis_mid = .hex(f.vis_mid),
        .vis_hi = .hex(f.vis_hi),
        .vis_peak = .hex(f.vis_peak),
        .glyphs = .{
            .bars = bars,
            .hbars = hbars,
            .h = firstCodepoint(f.glyphs.h, d.h),
            .v = firstCodepoint(f.glyphs.v, d.v),
            .tl = firstCodepoint(f.glyphs.tl, d.tl),
            .tr = firstCodepoint(f.glyphs.tr, d.tr),
            .bl = firstCodepoint(f.glyphs.bl, d.bl),
            .br = firstCodepoint(f.glyphs.br, d.br),
            .track = firstCodepoint(f.glyphs.track, d.track),
            .thumb = firstCodepoint(f.glyphs.thumb, d.thumb),
            .peak = firstCodepoint(f.glyphs.peak, d.peak),
            .scope = firstCodepoint(f.glyphs.scope, d.scope),
            .scope_hi = firstCodepoint(f.glyphs.scope_hi, d.scope_hi),
            .scope_lo = firstCodepoint(f.glyphs.scope_lo, d.scope_lo),
            .colon = firstCodepoint(f.glyphs.colon, d.colon),
            .win_shade = f.glyphs.win_shade,
            .win_close = f.glyphs.win_close,
            .sep = f.glyphs.sep,
            .now_playing = f.glyphs.now_playing,
            .prev = f.glyphs.prev,
            .play = f.glyphs.play,
            .pause = f.glyphs.pause,
            .stop = f.glyphs.stop,
            .next = f.glyphs.next,
            .eject = f.glyphs.eject,
        },
    };
}

pub fn parseTheme(arena: Allocator, source: [:0]const u8) ?Theme {
    // `File` has a lot of fields, and the ZON parser unrolls over all of
    // them at comptime.
    @setEvalBranchQuota(20_000);
    const f = std.zon.parse.fromSliceAlloc(File, arena, source, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    }) catch return null;
    return fromFile(f);
}

pub fn loadThemeFile(arena: Allocator, io: Io, path: []const u8) ?Theme {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_theme_bytes)) catch
        return null;
    const source = arena.allocSentinel(u8, bytes.len, 0) catch return null;
    @memcpy(source, bytes);
    return parseTheme(arena, source);
}

/// Resolve `name` to a theme: an explicit path if it looks like one, then a
/// file in the user's theme directory, then a built-in. Returns null only
/// when the user named something that does not exist, so the caller can say
/// so rather than silently falling back.
pub fn resolve(
    arena: Allocator,
    io: Io,
    config_dir: ?[]const u8,
    name: []const u8,
) ?Theme {
    // Anything with a separator or a .zon suffix is a path.
    if (std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.endsWith(u8, name, ".zon"))
    {
        return loadThemeFile(arena, io, name);
    }

    if (config_dir) |dir| {
        const path = std.fs.path.join(arena, &.{ dir, "themes", name }) catch null;
        if (path) |p| {
            const with_ext = std.fmt.allocPrint(arena, "{s}.zon", .{p}) catch null;
            if (with_ext) |wp| {
                if (loadThemeFile(arena, io, wp)) |t| return t;
            }
        }
    }

    return Theme.byName(name);
}

test "firstCodepoint handles empty and multibyte input" {
    try std.testing.expectEqual(@as(u21, 'x'), firstCodepoint("xyz", '?'));
    try std.testing.expectEqual(@as(u21, 0x2588), firstCodepoint("\u{2588}", '?'));
    try std.testing.expectEqual(@as(u21, '?'), firstCodepoint("", '?'));
}

test "a theme file parses into a usable theme" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\.{
        \\    .name = "amber",
        \\    .bg = 0x101008, .frame = 0x333322, .frame_focus = 0x665544,
        \\    .title_bg = 0x1a1a10, .title_fg = 0xffb000, .title_fg_dim = 0x805800,
        \\    .lcd_bg = 0x000000, .lcd_fg = 0xffb000, .lcd_dim = 0x6a4a00,
        \\    .text = 0xffb000, .text_dim = 0x7a5500, .text_bright = 0xffe0a0,
        \\    .list_current = 0xffffff, .list_sel_bg = 0x663300, .list_sel_fg = 0xffffff,
        \\    .track = 0x332200, .fill = 0xcc8800, .thumb = 0xffe0a0,
        \\    .button = 0xaa8844, .button_active = 0xffffff,
        \\    .vis_lo = 0xffb000, .vis_mid = 0xffd060, .vis_hi = 0xff4000,
        \\    .vis_peak = 0xffffff,
        \\    .glyphs = .{
        \\        .bars = .{ " ", "_", "_", "-", "-", "=", "=", "#", "#" },
        \\        .hbars = .{ " ", " ", ".", ".", "-", "-", "=", "=", "#" },
        \\        .h = "-", .v = "|", .tl = "+", .tr = "+", .bl = "+", .br = "+",
        \\        .track = "-", .thumb = "#", .peak = "^",
        \\        .scope = "#", .scope_hi = "-", .scope_lo = "_",
        \\        .colon = ":", .win_shade = "_", .win_close = "x",
        \\        .sep = " ** ", .now_playing = ">",
        \\        .prev = "|<<", .play = " > ", .pause = " ||",
        \\        .stop = "[ ]", .next = ">>|", .eject = " ^ ",
        \\    },
        \\}
    ;
    const t = parseTheme(arena, source).?;

    try std.testing.expectEqualStrings("amber", t.name);
    try std.testing.expectEqual(@as(u8, 0xff), t.lcd_fg.r);
    try std.testing.expectEqual(@as(u8, 0xb0), t.lcd_fg.g);
    try std.testing.expectEqual(@as(u21, '#'), t.glyphs.thumb);
    try std.testing.expectEqual(@as(u21, '^'), t.glyphs.peak);
    try std.testing.expectEqualStrings(" ** ", t.glyphs.sep);
    // The gradient still works on a loaded palette.
    try std.testing.expectEqual(t.vis_lo.r, t.visColor(0).r);
}

test "a malformed theme file is rejected rather than half-applied" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(parseTheme(arena, "not zon") == null);
    try std.testing.expect(parseTheme(arena, ".{}") == null);
    // Missing the glyph table.
    try std.testing.expect(parseTheme(arena, ".{ .name = \"x\", .bg = 0 }") == null);
}

test "resolve falls back to the built-ins" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "classic",
        resolve(arena, std.testing.io, null, "classic").?.name,
    );
    try std.testing.expectEqualStrings(
        "ascii",
        resolve(arena, std.testing.io, "/nonexistent", "ascii").?.name,
    );
    // A name that is neither a file nor a built-in resolves to nothing, so
    // the caller can report it.
    try std.testing.expect(resolve(arena, std.testing.io, null, "nope") == null);
    try std.testing.expect(resolve(arena, std.testing.io, null, "/no/such/theme.zon") == null);
}

test "resolve loads a theme file from the user's theme directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "themes");

    const minimal =
        \\.{
        \\    .name = "mono",
        \\    .bg = 0, .frame = 1, .frame_focus = 2, .title_bg = 3, .title_fg = 4,
        \\    .title_fg_dim = 5, .lcd_bg = 6, .lcd_fg = 7, .lcd_dim = 8, .text = 9,
        \\    .text_dim = 10, .text_bright = 11, .list_current = 12,
        \\    .list_sel_bg = 13, .list_sel_fg = 14, .track = 15, .fill = 16,
        \\    .thumb = 17, .button = 18, .button_active = 19, .vis_lo = 20,
        \\    .vis_mid = 21, .vis_hi = 22, .vis_peak = 23,
        \\    .glyphs = .{
        \\        .bars = .{ " ", "a", "b", "c", "d", "e", "f", "g", "h" },
        \\        .hbars = .{ " ", "a", "b", "c", "d", "e", "f", "g", "h" },
        \\        .h = "-", .v = "|", .tl = "+", .tr = "+", .bl = "+", .br = "+",
        \\        .track = "-", .thumb = "#", .peak = "^", .scope = "#",
        \\        .scope_hi = "-", .scope_lo = "_", .colon = ":",
        \\        .win_shade = "_", .win_close = "x", .sep = " - ",
        \\        .now_playing = ">", .prev = "<<", .play = ">", .pause = "||",
        \\        .stop = "[]", .next = ">>", .eject = "^",
        \\    },
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/mono.zon", .data = minimal });

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = resolve(arena, io, root, "mono").?;
    try std.testing.expectEqualStrings("mono", t.name);
    try std.testing.expectEqual(@as(u21, '#'), t.glyphs.thumb);
}

test "the theme files shipped in themes/ parse and match the built-ins" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Embedded rather than read from disk, so the test does not depend on
    // the working directory and cannot silently skip.
    const sources = [_][:0]const u8{
        @embedFile("../themes/classic.zon"),
        @embedFile("../themes/ascii.zon"),
    };
    const builtins = [_]Theme{ .classic, .ascii };

    for (sources, builtins) |source, builtin| {
        const loaded = parseTheme(arena, source) orelse return error.ThemeFailedToParse;
        try std.testing.expectEqualStrings(builtin.name, loaded.name);
        // A shipped file drifting from the built-in it documents would be a
        // quiet lie, so check every colour and glyph.
        try std.testing.expectEqual(builtin.bg, loaded.bg);
        try std.testing.expectEqual(builtin.lcd_fg, loaded.lcd_fg);
        try std.testing.expectEqual(builtin.list_sel_bg, loaded.list_sel_bg);
        try std.testing.expectEqual(builtin.vis_hi, loaded.vis_hi);
        try std.testing.expectEqual(builtin.glyphs.bars, loaded.glyphs.bars);
        try std.testing.expectEqual(builtin.glyphs.hbars, loaded.glyphs.hbars);
        try std.testing.expectEqual(builtin.glyphs.thumb, loaded.glyphs.thumb);
        try std.testing.expectEqual(builtin.glyphs.colon, loaded.glyphs.colon);
        try std.testing.expectEqualStrings(builtin.glyphs.sep, loaded.glyphs.sep);
        try std.testing.expectEqualStrings(builtin.glyphs.prev, loaded.glyphs.prev);
        try std.testing.expectEqualStrings(builtin.glyphs.eject, loaded.glyphs.eject);
    }
}
