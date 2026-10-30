//! Palettes and glyph sets. A "skin" in tuiamp is a `Theme`.
//!
//! Every built-in theme is defined exactly once, in a ZON file under
//! `src/themes/`, and imported at comptime. Those same files are installed
//! to `share/tuiamp/themes/`, so what a user copies to start their own theme
//! is literally the theme that shipped — there is no second copy in Zig that
//! could drift from it.
//!
//! `ascii` proves the glyph indirection works by having to survive with no
//! box-drawing or block characters at all. Every other theme omits the glyph
//! table and inherits the box-drawing set, because a theme is usually just a
//! palette.

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
    pub const classic: Theme = builtin(@import("../themes/classic.zon"));
    /// For terminals or fonts where block and box glyphs are not trustworthy.
    pub const ascii: Theme = builtin(@import("../themes/ascii.zon"));
    /// Amber phosphor, monochrome on purpose.
    pub const amber: Theme = builtin(@import("../themes/amber.zon"));
    pub const gruvbox: Theme = builtin(@import("../themes/gruvbox.zon"));
    /// Synthwave: cyan and magenta, turned up.
    pub const neon: Theme = builtin(@import("../themes/neon.zon"));
    pub const nord: Theme = builtin(@import("../themes/nord.zon"));
    /// The one light theme, for a light terminal.
    pub const paper: Theme = builtin(@import("../themes/paper.zon"));

    /// Every theme compiled in, in the order `--help` and the picker list
    /// them: the two originals first, then the rest alphabetically. The
    /// catalog sorts its own listing, so this order is only about reading.
    ///
    /// Adding a theme is a file under `src/themes/` plus two lines here.
    pub const builtins = [_]Theme{ classic, ascii, amber, gruvbox, neon, nord, paper };

    /// The ZON sources of `builtins`, in the same order, for the test that
    /// checks the runtime parser agrees with the comptime import. A theme
    /// that works built in but fails when copied into a user's theme
    /// directory would be a nasty thing to ship.
    const builtin_sources = [_][:0]const u8{
        @embedFile("../themes/classic.zon"),
        @embedFile("../themes/ascii.zon"),
        @embedFile("../themes/amber.zon"),
        @embedFile("../themes/gruvbox.zon"),
        @embedFile("../themes/neon.zon"),
        @embedFile("../themes/nord.zon"),
        @embedFile("../themes/paper.zon"),
    };

    comptime {
        // The two lists are written by hand and must stay in step.
        std.debug.assert(builtins.len == builtin_sources.len);
    }

    pub fn byName(name: []const u8) ?Theme {
        for (builtins) |t| {
            if (std.mem.eql(u8, name, t.name)) return t;
        }
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

test "every built-in is reachable by its own name, exactly once" {
    // Otherwise the picker offers a theme that cannot be selected, or two
    // entries resolve to the same palette.
    for (Theme.builtins) |t| {
        const found = Theme.byName(t.name) orelse return error.UnknownBuiltin;
        try std.testing.expectEqualStrings(t.name, found.name);
        try std.testing.expectEqual(t.bg, found.bg);

        var seen: usize = 0;
        for (Theme.builtins) |other| {
            if (std.mem.eql(u8, other.name, t.name)) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
    try std.testing.expect(Theme.byName("nope") == null);
    // The first entry is the default a fresh config asks for.
    try std.testing.expectEqualStrings("classic", Theme.builtins[0].name);
}

test "no built-in is unreadable: every colour pair that must differ, does" {
    // A palette whose selection bar matches its background, or whose dim
    // text matches the page, is invisible rather than subtle. These are the
    // pairs that carry meaning on their own.
    for (Theme.builtins) |t| {
        try std.testing.expect(!std.meta.eql(t.bg, t.list_sel_bg));
        try std.testing.expect(!std.meta.eql(t.list_sel_bg, t.list_sel_fg));
        try std.testing.expect(!std.meta.eql(t.bg, t.text));
        try std.testing.expect(!std.meta.eql(t.bg, t.text_dim));
        try std.testing.expect(!std.meta.eql(t.bg, t.frame));
        try std.testing.expect(!std.meta.eql(t.frame, t.frame_focus));
        try std.testing.expect(!std.meta.eql(t.lcd_bg, t.lcd_fg));
        try std.testing.expect(!std.meta.eql(t.track, t.thumb));
        // The analyzer has to climb: three identical stops is not a gradient.
        try std.testing.expect(!std.meta.eql(t.vis_lo, t.vis_hi));
    }
}

test "every built-in orders its three text levels away from the background" {
    // The windows lean on a dim/plain/bright hierarchy, and the rule that
    // makes it work is distance from the page, not absolute brightness:
    // dim sits nearest the background, bright furthest. Asserting a large
    // gap instead would reject real palettes — Nord's body text is already
    // near-white, so its emphasis can only be a little brighter, and that
    // is Nord rather than a mistake.
    for (Theme.builtins) |t| {
        const back = luma(t.bg);
        const dim = @abs(luma(t.text_dim) - back);
        const plain = @abs(luma(t.text) - back);
        const bright = @abs(luma(t.text_bright) - back);

        try std.testing.expect(dim + 0.03 < plain);
        try std.testing.expect(plain + 0.03 < bright);
        // And plain text has to stand off the page at all.
        try std.testing.expect(plain > 0.25);
    }
}

/// Rough perceptual brightness, 0 to 1. Only used to assert that palettes
/// separate their text levels; nothing draws with it.
fn luma(c: Rgb) f32 {
    const r: f32 = @floatFromInt(c.r);
    const g: f32 = @floatFromInt(c.g);
    const b: f32 = @floatFromInt(c.b);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
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

    /// Omit it to inherit `Glyphs.unicode`. Most themes are a palette and
    /// nothing else, and 25 lines of identical box-drawing in every file is
    /// 25 lines that can be got wrong.
    glyphs: ?GlyphFile = null,

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

/// A built-in, converted at comptime. The ZON parser the runtime path uses
/// is not involved: `@import` of a `.zon` file coerces straight to `File`.
fn builtin(comptime f: File) Theme {
    @setEvalBranchQuota(100_000);
    return fromFile(f);
}

/// Convert a parsed file into a usable theme. Strings are borrowed from the
/// arena the file was parsed into, so that arena must outlive the theme.
pub fn fromFile(f: File) Theme {
    // `Glyphs.unicode` rather than `Theme.classic.glyphs`: classic is itself
    // built by this function, so reaching for it here would be a cycle.
    const d = Glyphs.unicode;
    const gf = f.glyphs orelse return paletteOnly(f, d);

    var bars: [9]u21 = undefined;
    var hbars: [9]u21 = undefined;
    for (gf.bars, 0..) |s, i| bars[i] = firstCodepoint(s, d.bars[i]);
    for (gf.hbars, 0..) |s, i| hbars[i] = firstCodepoint(s, d.hbars[i]);

    var t = paletteOnly(f, d);
    t.glyphs = .{
        .bars = bars,
        .hbars = hbars,
        .h = firstCodepoint(gf.h, d.h),
        .v = firstCodepoint(gf.v, d.v),
        .tl = firstCodepoint(gf.tl, d.tl),
        .tr = firstCodepoint(gf.tr, d.tr),
        .bl = firstCodepoint(gf.bl, d.bl),
        .br = firstCodepoint(gf.br, d.br),
        .track = firstCodepoint(gf.track, d.track),
        .thumb = firstCodepoint(gf.thumb, d.thumb),
        .peak = firstCodepoint(gf.peak, d.peak),
        .scope = firstCodepoint(gf.scope, d.scope),
        .scope_hi = firstCodepoint(gf.scope_hi, d.scope_hi),
        .scope_lo = firstCodepoint(gf.scope_lo, d.scope_lo),
        .colon = firstCodepoint(gf.colon, d.colon),
        .win_shade = gf.win_shade,
        .win_close = gf.win_close,
        .sep = gf.sep,
        .now_playing = gf.now_playing,
        .prev = gf.prev,
        .play = gf.play,
        .pause = gf.pause,
        .stop = gf.stop,
        .next = gf.next,
        .eject = gf.eject,
    };
    return t;
}

/// The colours, with `glyphs` left at the inherited set.
fn paletteOnly(f: File, g: Glyphs) Theme {
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
        .glyphs = g,
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

test "the runtime parser agrees with the comptime import, for every theme" {
    // The built-ins come from `@import`; a user's copy comes from
    // `parseTheme`. A theme that works one way and not the other would be a
    // nasty thing to ship, since copying a shipped theme out of
    // share/tuiamp/themes is the documented way to start your own.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (Theme.builtin_sources, Theme.builtins) |source, want| {
        const got = parseTheme(arena, source) orelse return error.ThemeFailedToParse;
        try std.testing.expectEqualStrings(want.name, got.name);

        inline for (@typeInfo(Theme).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "name")) continue;
            if (comptime std.mem.eql(u8, f.name, "glyphs")) continue;
            try std.testing.expectEqual(@field(want, f.name), @field(got, f.name));
        }

        try std.testing.expectEqual(want.glyphs.bars, got.glyphs.bars);
        try std.testing.expectEqual(want.glyphs.hbars, got.glyphs.hbars);
        try std.testing.expectEqual(want.glyphs.thumb, got.glyphs.thumb);
        try std.testing.expectEqual(want.glyphs.colon, got.glyphs.colon);
        try std.testing.expectEqualStrings(want.glyphs.sep, got.glyphs.sep);
        try std.testing.expectEqualStrings(want.glyphs.prev, got.glyphs.prev);
        try std.testing.expectEqualStrings(want.glyphs.eject, got.glyphs.eject);
    }
}

test "a theme with no glyph table inherits the box-drawing set" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // amber ships without a `.glyphs` block, so it must come out with
    // classic's glyphs and its own colours.
    const t = parseTheme(arena, Theme.builtin_sources[2]).?;
    try std.testing.expectEqualStrings("amber", t.name);
    try std.testing.expectEqual(Theme.classic.glyphs.thumb, t.glyphs.thumb);
    try std.testing.expectEqual(Theme.classic.glyphs.tl, t.glyphs.tl);
    try std.testing.expectEqualStrings(Theme.classic.glyphs.prev, t.glyphs.prev);
    try std.testing.expect(!std.meta.eql(t.bg, Theme.classic.bg));
}

// --- the catalog -----------------------------------------------------------

/// Every theme the user could choose: the built-ins, plus each `.zon` file in
/// `<config_dir>/themes/`. One entry per name — a file shadows a built-in it
/// shares a name with, which is what `resolve` does too, so the list never
/// offers the same name twice.
///
/// Names are owned here and freed on the next `refresh`, so a caller that
/// keeps one past that point must copy it. Resolved themes borrow the arena
/// passed to `themeAt`, which has to outlive them.
pub const Catalog = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        name: []u8,
        /// Filled in the first time this theme is asked for. Parsing the
        /// whole directory up front would read every file to draw one list,
        /// and the user is going to look at two of them.
        theme: ?Theme = null,
    };

    /// A theme directory with more files than this is not a theme directory,
    /// and a picker is not the place to find that out slowly.
    pub const max_themes = 128;

    pub fn init(gpa: Allocator) Catalog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Catalog) void {
        c.clear();
        c.entries.deinit(c.gpa);
        c.* = undefined;
    }

    fn clear(c: *Catalog) void {
        for (c.entries.items) |e| c.gpa.free(e.name);
        c.entries.clearRetainingCapacity();
    }

    pub fn len(c: Catalog) usize {
        return c.entries.items.len;
    }

    pub fn nameAt(c: Catalog, i: usize) []const u8 {
        return c.entries.items[i].name;
    }

    pub fn indexOf(c: Catalog, name: []const u8) ?usize {
        for (c.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    /// Rebuild the list, so a theme dropped into the directory while tuiamp
    /// is running turns up without a restart. Best effort throughout: an
    /// unreadable directory just means the built-ins, because failing to
    /// list themes should never be worse than having none to list.
    pub fn refresh(c: *Catalog, io: Io, config_dir: ?[]const u8) void {
        c.clear();
        for (Theme.builtins) |t| c.add(t.name);
        if (config_dir) |dir| c.addDirectory(io, dir);
        std.mem.sort(Entry, c.entries.items, {}, lessByName);
    }

    /// Resolve entry `i`, remembering the result so flipping up and down the
    /// list parses each theme once rather than once per keypress.
    pub fn themeAt(
        c: *Catalog,
        arena: Allocator,
        io: Io,
        config_dir: ?[]const u8,
        i: usize,
    ) ?Theme {
        if (i >= c.entries.items.len) return null;
        const e = &c.entries.items[i];
        if (e.theme) |t| return t;
        const t = resolve(arena, io, config_dir, e.name) orelse return null;
        e.theme = t;
        return t;
    }

    /// Add one name if it is new and there is room. Public so a caller can
    /// build a list without a filesystem behind it.
    pub fn add(c: *Catalog, name: []const u8) void {
        if (name.len == 0 or c.entries.items.len >= max_themes) return;
        if (c.indexOf(name) != null) return;
        const owned = c.gpa.dupe(u8, name) catch return;
        c.entries.append(c.gpa, .{ .name = owned }) catch c.gpa.free(owned);
    }

    fn addDirectory(c: *Catalog, io: Io, config_dir: []const u8) void {
        const path = std.fs.path.join(c.gpa, &.{ config_dir, "themes" }) catch return;
        defer c.gpa.free(path);

        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        // `entry.name` is only valid until the next call, and `add` copies.
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
            c.add(entry.name[0 .. entry.name.len - ".zon".len]);
        }
    }

    fn lessByName(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

test "the catalog lists the built-ins with no theme directory" {
    const gpa = std.testing.allocator;
    var c: Catalog = .init(gpa);
    defer c.deinit();

    c.refresh(std.testing.io, null);
    try std.testing.expectEqual(Theme.builtins.len, c.len());

    // Alphabetical, so the list does not reorder itself between openings.
    var i: usize = 1;
    while (i < c.len()) : (i += 1) {
        try std.testing.expect(std.mem.lessThan(u8, c.nameAt(i - 1), c.nameAt(i)));
    }
    // Every built-in is offered, wherever it sorts to.
    for (Theme.builtins) |t| {
        const at = c.indexOf(t.name) orelse return error.BuiltinMissingFromCatalog;
        try std.testing.expectEqualStrings(t.name, c.nameAt(at));
    }
    try std.testing.expectEqual(@as(?usize, null), c.indexOf("no-such-theme"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const classic_at = c.indexOf("classic").?;
    const t = c.themeAt(arena, std.testing.io, null, classic_at).?;
    try std.testing.expectEqualStrings("classic", t.name);
    // Out of range is null rather than a crash.
    try std.testing.expect(c.themeAt(arena, std.testing.io, null, 99) == null);
}

test "the catalog picks up theme files and does not list a name twice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "themes");

    const minimal =
        \\.{
        \\    .name = "lagoon",
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
        \\        .track = "-", .thumb = "@", .peak = "^", .scope = "#",
        \\        .scope_hi = "-", .scope_lo = "_", .colon = ":",
        \\        .win_shade = "_", .win_close = "x", .sep = " - ",
        \\        .now_playing = ">", .prev = "<<", .play = ">", .pause = "||",
        \\        .stop = "[]", .next = ">>", .eject = "^",
        \\    },
        \\}
    ;
    // One new name, and one that shadows a built-in rather than doubling it.
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/lagoon.zon", .data = minimal });
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/ascii.zon", .data = minimal });
    // Anything that is not a theme file is ignored.
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/notes.txt", .data = "hello" });

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var c: Catalog = .init(gpa);
    defer c.deinit();
    c.refresh(io, root);

    // The built-ins plus exactly one new name.
    try std.testing.expectEqual(Theme.builtins.len + 1, c.len());
    try std.testing.expect(c.indexOf("lagoon") != null);
    try std.testing.expect(c.indexOf("notes") == null);
    try std.testing.expect(c.indexOf("ascii") != null);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The new file resolves, and the one shadowing "ascii" wins over the
    // built-in, exactly as passing --theme ascii would.
    const lagoon = c.themeAt(arena, io, root, c.indexOf("lagoon").?).?;
    try std.testing.expectEqualStrings("lagoon", lagoon.name);
    const shadowed = c.themeAt(arena, io, root, c.indexOf("ascii").?).?;
    try std.testing.expectEqual(@as(u21, '@'), shadowed.glyphs.thumb);
    try std.testing.expect(!std.meta.eql(shadowed.bg, Theme.ascii.bg));
    // An unshadowed built-in still comes from the built-in.
    const classic = c.themeAt(arena, io, root, c.indexOf("classic").?).?;
    try std.testing.expectEqual(Theme.classic.bg, classic.bg);

    // Refreshing twice is stable rather than accumulating.
    c.refresh(io, root);
    try std.testing.expectEqual(Theme.builtins.len + 1, c.len());
}

test "a refresh that finds nothing still leaves the built-ins" {
    const gpa = std.testing.allocator;
    var c: Catalog = .init(gpa);
    defer c.deinit();
    c.refresh(std.testing.io, "/definitely/not/here");
    try std.testing.expectEqual(Theme.builtins.len, c.len());
}
