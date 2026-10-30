//! The event loop and window stack.
//!
//! Winamp is a set of small fixed windows the user shows, hides and collapses
//! independently, stacked vertically. That is what this holds: a stack of
//! windows centred in the terminal, each with its own visibility and shade
//! state, plus the focus that decides where keys go.
//!
//! The loop blocks in a single `poll` over stdin and a signalfd for SIGWINCH,
//! with a timeout that sets the frame rate. Folding resize into the poll set
//! means no signal handler has to touch shared state.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const geom = @import("../term/geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const screen_mod = @import("../term/screen.zig");
const Screen = screen_mod.Screen;
const input = @import("../term/input.zig");
const tty_mod = @import("../term/tty.zig");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const main_window = @import("main_window.zig");
const playlist_window = @import("playlist_window.zig");
const eq_window = @import("eq_window.zig");
const settings_window = @import("settings_window.zig");
const help = @import("help.zig");
const eq = @import("../audio/eq.zig");
const Marquee = @import("widgets/marquee.zig").Marquee;
const marquee_mod = @import("widgets/marquee.zig");
const Slider = @import("widgets/slider.zig").Slider;
const player_mod = @import("../audio/player.zig");
const Player = player_mod.Player;
const vis = @import("widgets/vis.zig");
const engine_mod = @import("../audio/engine.zig");
const list_mod = @import("../playlist/list.zig");
const List = list_mod.List;
const scan = @import("../playlist/scan.zig");
const config_mod = @import("../config.zig");

/// 25 frames per second: smooth enough for the marquee and the analyzer,
/// invisible in a CPU graph.
const frame_ms = 40;
/// The playlist grows into spare rows, but not without limit.
const max_playlist_rows: u16 = 24;

const Drag = union(enum) {
    none,
    seek,
    volume,
    balance,
    eq_preamp,
    /// Index into the EQ bands.
    eq_band: usize,
    /// The playlist scrollbar's thumb.
    playlist_scroll,
};
const Focus = enum { main, eq, playlist };

/// Everything needed to put a different theme on screen while running, which
/// is more than the theme itself: the picker has to be able to find the
/// others and parse them.
///
/// `arena` outlives the app, because a loaded theme's name and glyph strings
/// are borrowed from wherever it was parsed. Each theme is parsed at most
/// once per listing, so previewing is bounded rather than growing the arena
/// with every keypress.
pub const ThemeSource = struct {
    arena: Allocator,
    /// Null with `--no-config`, which also means no theme directory.
    config_dir: ?[]const u8,
    /// The name `resolved` came from, which is what gets written back to the
    /// config. The app holds a resolved theme, which no longer knows it.
    name: []const u8,
    resolved: Theme,
};

/// One keypress of a slider, in decibels. Matches the half-row resolution
/// the EQ window draws at, so every press visibly moves the thumb.
const eq_key_step: f32 = 1.5;

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    tty: *tty_mod.Tty,
    screen: Screen,
    parser: input.Parser = .{},
    player: *Player,
    list: *List,
    theme: Theme,
    /// Shared with the audio thread, which writes into it from the tap node.
    tap: *engine_mod.VisTap,
    /// Heap-allocated: it carries the FFT scratch and the smoothing state,
    /// which is several kilobytes and should not be copied around.
    analyzer: *vis.Analyzer,
    /// Reused each frame so the analyzer window is not a stack allocation
    /// in the render path.
    vis_window: *[vis.window]f32,
    /// Published to the audio thread whenever the user changes a control.
    eq_shared: *eq.Node.Shared,

    /// SIGWINCH as a file descriptor, so resize arrives through poll.
    winch_fd: posix.fd_t,

    /// Where a theme chosen at runtime is parsed, and where to look for the
    /// ones on disk.
    arena: Allocator,
    config_dir: ?[]const u8,
    theme_name: []const u8,
    themes: theme_mod.Catalog,

    quit: bool = false,
    needs_resize: bool = true,
    marquee: Marquee = .{},
    show_remaining: bool = false,
    shaded: bool = false,
    focus: Focus = .main,
    eq_open: bool = false,
    eq_settings: eq.Settings = .{},
    eq_auto: bool = false,
    eq_preset: usize = 0,
    /// 0 is the preamp; 1..10 are the bands.
    eq_cursor: usize = 0,
    playlist_open: bool = false,
    playlist_scroll: usize = 0,
    /// Set when the cursor moves, and cleared once the view has caught up.
    /// Without it the playlist view is recentred on the cursor every frame,
    /// which yanks the wheel and the scrollbar straight back where they
    /// started. Starts true so the first frame opens on the cursor.
    follow_cursor: bool = true,
    /// Null when the overlay is closed; `?` walks the pages and then closes.
    help_page: ?help.Page = null,
    settings_open: bool = false,
    settings_cursor: usize = 0,
    settings_scroll: usize = 0,
    /// What to put back if the picker is cancelled. The theme under the
    /// cursor is applied as you move, so there has to be a way home.
    theme_before_settings: ?struct { theme: Theme, name: []const u8 } = null,
    drag: Drag = .none,
    frames: u32 = 0,

    /// Where each window was last drawn, for routing mouse coordinates.
    main_origin: Rect = .empty,
    eq_origin: Rect = .empty,
    playlist_origin: Rect = .empty,
    /// Click position and frame, for detecting a double-click.
    last_click: ?struct { point: Point, frame: u32 } = null,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        tty: *tty_mod.Tty,
        player: *Player,
        list: *List,
        tap: *engine_mod.VisTap,
        eq_shared: *eq.Node.Shared,
        themes: ThemeSource,
        cfg: config_mod.Config,
    ) !App {
        const size = try tty.size();
        var sc = try Screen.init(gpa, size.cols, size.rows);
        errdefer sc.deinit();

        const analyzer = try gpa.create(vis.Analyzer);
        errdefer gpa.destroy(analyzer);
        analyzer.* = .{};

        const vis_window = try gpa.create([vis.window]f32);
        errdefer gpa.destroy(vis_window);

        // Block SIGWINCH for normal delivery and take it through a descriptor
        // instead; a handler would otherwise mutate state asynchronously.
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, .WINCH);
        posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
        const winch_fd = try posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);

        var m: Marquee = .{};
        m.separator = themes.resolved.glyphs.sep;

        var app: App = .{
            .gpa = gpa,
            .io = io,
            .tty = tty,
            .screen = sc,
            .player = player,
            .list = list,
            .theme = themes.resolved,
            .arena = themes.arena,
            .config_dir = themes.config_dir,
            .theme_name = themes.name,
            .themes = .init(gpa),
            .winch_fd = winch_fd,
            .marquee = m,
            .playlist_open = list.len() > 1,
            .tap = tap,
            .analyzer = analyzer,
            .vis_window = vis_window,
            .eq_shared = eq_shared,
        };
        app.applyConfig(cfg);
        return app;
    }

    /// Restore saved settings. Called once, before the first frame.
    fn applyConfig(a: *App, cfg: config_mod.Config) void {
        a.show_remaining = cfg.show_remaining;
        a.shaded = cfg.shaded;
        a.eq_open = cfg.eq_open;
        // An empty playlist has nothing to show, whatever the config says.
        a.playlist_open = cfg.playlist_open and a.list.len() > 0;

        a.list.setShuffle(cfg.shuffle);
        a.list.repeat = if (std.mem.eql(u8, cfg.repeat, "all"))
            .all
        else if (std.mem.eql(u8, cfg.repeat, "one"))
            .one
        else
            .off;

        a.analyzer.mode = if (std.mem.eql(u8, cfg.vis_mode, "oscilloscope"))
            .oscilloscope
        else if (std.mem.eql(u8, cfg.vis_mode, "off"))
            .off
        else
            .spectrum;

        a.eq_settings = cfg.eqSettings();
        a.eq_auto = cfg.eq_auto;
        a.eq_preset = @min(cfg.eq_preset, eq.presets.len - 1);
        a.publishEq();

        a.player.setVolume(cfg.volumeFraction());
        a.player.setBalance(cfg.balanceFraction());
    }

    /// Capture the current state for saving.
    pub fn currentConfig(a: *App) config_mod.Config {
        var cfg: config_mod.Config = .{
            .theme = a.theme_name,
            .show_remaining = a.show_remaining,
            .shaded = a.shaded,
            .eq_open = a.eq_open,
            .playlist_open = a.playlist_open,
            .shuffle = a.list.shuffle,
            .repeat = switch (a.list.repeat) {
                .off => "off",
                .all => "all",
                .one => "one",
            },
            .vis_mode = switch (a.analyzer.mode) {
                .spectrum => "spectrum",
                .oscilloscope => "oscilloscope",
                .off => "off",
            },
            .eq_auto = a.eq_auto,
            .eq_preset = @intCast(a.eq_preset),
        };
        cfg.setVolume(a.player.volume);
        cfg.setBalance(a.player.balance);
        cfg.setEqSettings(a.eq_settings);
        return cfg;
    }

    pub fn deinit(a: *App) void {
        _ = linux.close(a.winch_fd);
        a.themes.deinit();
        a.gpa.destroy(a.vis_window);
        a.gpa.destroy(a.analyzer);
        a.screen.deinit();
        a.* = undefined;
    }

    /// Begin playback at the first entry, skipping any that will not open.
    pub fn start(a: *App) void {
        if (a.list.isEmpty()) return;
        const first = a.list.currentIndex() orelse return;
        if (a.openIndex(first)) {
            a.player.play() catch {};
        } else {
            a.step(.forward);
        }
    }

    pub fn run(a: *App) !void {
        var out_buf: [1 << 16]u8 = undefined;
        var writer = std.Io.File.stdout().writer(a.io, &out_buf);

        while (!a.quit) {
            if (a.needs_resize) {
                const size = try a.tty.size();
                try a.screen.resize(size.cols, size.rows);
                a.screen.invalidate();
                a.needs_resize = false;
            }

            a.tick();
            a.draw();
            try a.screen.render(&writer.interface);
            try a.wait();
        }
    }

    // -- per-frame state ----------------------------------------------------

    fn tick(a: *App) void {
        a.frames +%= 1;

        if (a.player.consumeTrackEnded()) {
            // Record what we learned about this track before moving on.
            a.rememberDuration();
            a.step(.forward);
        }

        if (a.player.state == .playing) {
            const avail = main_window.Layout.compute().marquee.w -| 4;
            a.marquee.step(marquee_mod.displayWidth(a.currentTitle()), avail);
        }

        a.updateAnalyzer();
    }

    fn updateAnalyzer(a: *App) void {
        const columns = main_window.Layout.compute().vis.w;

        // A torn or not-yet-filled window is reported as "no audio", which
        // makes the display decay rather than show garbage. At 25fps a
        // skipped frame is invisible.
        const have = a.player.state == .playing and a.tap.readLatest(a.vis_window);
        const samples: []const f32 = if (have) a.vis_window else &.{};

        const rate = if (a.player.info.sample_rate > 0)
            a.player.info.sample_rate
        else
            a.player.engine.sampleRate();

        a.analyzer.update(samples, rate, columns);
    }

    fn currentTitle(a: *App) []const u8 {
        if (!a.player.hasTrack()) return "tuiamp";
        return a.player.info.title;
    }

    /// Fill in a duration the playlist did not know, now that the decoder
    /// has told us. This is why durations can be left unknown at scan time.
    fn rememberDuration(a: *App) void {
        const idx = a.list.currentIndex() orelse return;
        if (a.player.info.duration > 0) a.list.setDuration(idx, a.player.info.duration);
    }

    const Direction = enum { forward, backward };

    /// Move through the playlist and start playing. Entries that fail to open
    /// are skipped rather than stopping playback, because one unreadable file
    /// in a long playlist should not end the evening.
    fn step(a: *App, dir: Direction) void {
        var attempts: usize = 0;
        while (attempts <= a.list.len()) : (attempts += 1) {
            const next = switch (dir) {
                .forward => a.list.advance(),
                .backward => a.list.retreat(),
            } orelse break;

            if (a.openIndex(next)) {
                a.player.play() catch continue;
                return;
            }
        }
        a.player.stop();
    }

    /// Load an entry into the player. Returns false if it could not be read.
    fn openIndex(a: *App, index: usize) bool {
        if (index >= a.list.len()) return false;
        const entry = a.list.entries.items[index];
        // The playlist already knows the display title, so the marquee and
        // the list never disagree about what is playing.
        a.player.open(a.io, entry.path, entry.title) catch return false;
        a.marquee.reset();
        a.tap.reset();

        // The decoder knows the real duration; the playlist may not.
        if (a.player.info.duration > 0) a.list.setDuration(index, a.player.info.duration);
        return true;
    }

    /// Play the entry under the playlist cursor.
    fn playCursor(a: *App) void {
        const index = a.list.cursor;
        if (a.list.jumpTo(index) == null) return;
        if (a.openIndex(index)) {
            a.player.play() catch {};
        } else {
            // Unreadable: behave like the end of a track and move along.
            a.step(.forward);
        }
    }

    fn wait(a: *App) !void {
        var fds = [_]posix.pollfd{
            .{ .fd = a.tty.in, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = a.winch_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, frame_ms) catch 0;
        if (ready == 0) {
            // A poll timeout is the only evidence that a lone ESC was the
            // Escape key rather than the start of a sequence.
            if (a.parser.flushPending()) |e| a.handleEvent(e);
            return;
        }

        if (fds[1].revents & posix.POLL.IN != 0) {
            var sink: [128]u8 = undefined;
            _ = posix.read(a.winch_fd, &sink) catch 0;
            a.needs_resize = true;
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [1024]u8 = undefined;
            const n = posix.read(a.tty.in, &buf) catch 0;
            if (n == 0) {
                // stdin is closed, so no further input can arrive.
                a.quit = true;
                return;
            }
            a.parser.push(buf[0..n]);
            while (a.parser.next()) |e| a.handleEvent(e);
        }
    }

    // -- input --------------------------------------------------------------

    fn handleEvent(a: *App, e: input.Event) void {
        switch (e) {
            .key => |k| a.handleKey(k.key, k.mods),
            .mouse => |m| a.handleMouse(m),
            else => {},
        }
    }

    fn handleKey(a: *App, key: input.Key, mods: input.Mods) void {
        if (mods.ctrl) {
            switch (key) {
                .char => |ch| switch (ch) {
                    'c' => a.quit = true,
                    // Repaint from scratch, for when something else has
                    // written over the terminal.
                    'l' => a.screen.invalidate(),
                    // Winamp's preferences key.
                    'p' => a.toggleSettings(),
                    else => {},
                },
                else => {},
            }
            return;
        }

        // The settings dialog is modal: it wants the arrow keys, which
        // otherwise move the volume, and a stray `q` while picking a theme
        // should not quit the player.
        if (a.settings_open) {
            a.settingsKey(key);
            return;
        }

        if (mods.alt) {
            switch (key) {
                // Winamp's own window toggles.
                .char => |ch| switch (ch) {
                    'e' => a.togglePlaylist(),
                    'g' => a.toggleEq(),
                    else => {},
                },
                else => {},
            }
            return;
        }

        // Keys a focused window takes over. Winamp does the same: the arrows
        // move the playlist selection or an EQ slider when one of those has
        // focus, and the volume otherwise.
        if (a.focus == .playlist and a.playlist_open) {
            if (a.handlePlaylistKey(key, mods)) return;
        }
        if (a.focus == .eq and a.eq_open) {
            if (a.handleEqKey(key, mods)) return;
        }

        const p = a.player;
        switch (key) {
            .char => |ch| switch (ch) {
                'q' => a.quit = true,
                '?' => a.cycleHelp(),
                // The transport row, left to right.
                'z' => a.step(.backward),
                'x' => p.play() catch {},
                'c' => p.pause(),
                'v' => p.stop(),
                'b' => a.step(.forward),
                ' ' => p.togglePause() catch {},
                's' => a.list.setShuffle(!a.list.shuffle),
                'r' => a.list.repeat = switch (a.list.repeat) {
                    .off => .all,
                    .all => .one,
                    .one => .off,
                },
                't' => a.show_remaining = !a.show_remaining,
                'w' => a.shaded = !a.shaded,
                // Cycle the analyzer: spectrum, oscilloscope, off.
                'g' => a.analyzer.mode = a.analyzer.mode.next(),
                // Jump the playlist view to what is playing.
                'j' => a.revealCurrent(),
                else => {},
            },
            .tab => a.cycleFocus(),
            .up => p.nudgeVolume(0.05),
            .down => p.nudgeVolume(-0.05),
            .right => p.seekBy(5),
            .left => p.seekBy(-5),
            .page_up => p.seekBy(30),
            .page_down => p.seekBy(-30),
            .home => p.seekSeconds(0),
            .f => |n| if (n == 1) {
                a.cycleHelp();
            },
            // Escape closes the help if it is up, and otherwise quits.
            .escape => if (a.help_page != null) {
                a.help_page = null;
            } else {
                a.quit = true;
            },
            else => {},
        }
    }

    /// Returns true when the key was consumed by the playlist.
    fn handlePlaylistKey(a: *App, key: input.Key, mods: input.Mods) bool {
        const consumed = a.playlistKey(key, mods);
        // Any key the playlist took may have moved the cursor, so let the
        // view catch up with it on the next frame.
        if (consumed) a.follow_cursor = true;
        return consumed;
    }

    fn playlistKey(a: *App, key: input.Key, mods: input.Mods) bool {
        const count = a.list.len();
        if (count == 0) return false;
        const last = count - 1;
        const page = @max(a.playlistRows(), 1);

        switch (key) {
            .up => {
                if (mods.shift) {
                    // Shift-arrow moves the entry, not the cursor.
                    if (a.list.cursor > 0) {
                        a.list.move(a.list.cursor, a.list.cursor - 1);
                    }
                } else {
                    a.list.cursor -|= 1;
                }
                return true;
            },
            .down => {
                if (mods.shift) {
                    if (a.list.cursor < last) {
                        a.list.move(a.list.cursor, a.list.cursor + 1);
                    }
                } else {
                    a.list.cursor = @min(a.list.cursor + 1, last);
                }
                return true;
            },
            .page_up => {
                a.list.cursor -|= page;
                return true;
            },
            .page_down => {
                a.list.cursor = @min(a.list.cursor + page, last);
                return true;
            },
            .home => {
                a.list.cursor = 0;
                return true;
            },
            .end => {
                a.list.cursor = last;
                return true;
            },
            .enter => {
                a.playCursor();
                return true;
            },
            .delete => {
                a.list.remove(a.list.cursor);
                return true;
            },
            else => return false,
        }
    }

    /// Cycle through the windows that are actually open.
    /// Closed, then keys, then what it does, then closed again. One key for
    /// the whole overlay keeps it discoverable: there is nothing else to
    /// learn once you have found `?`.
    fn cycleHelp(a: *App) void {
        a.help_page = if (a.help_page) |page| page.next() else .keys;
    }

    const SettingsExit = enum { keep, cancel };

    fn toggleSettings(a: *App) void {
        if (a.settings_open) {
            a.closeSettings(.keep);
            return;
        }
        // One overlay at a time; two stacked dialogs is not a look Winamp
        // ever had.
        a.help_page = null;
        // Re-listed on every opening, so a theme file dropped in while
        // tuiamp is running turns up without a restart.
        a.themes.refresh(a.io, a.config_dir);
        a.settings_cursor = a.themes.indexOf(a.theme_name) orelse 0;
        a.settings_scroll = 0;
        a.theme_before_settings = .{ .theme = a.theme, .name = a.theme_name };
        a.settings_open = true;
    }

    fn closeSettings(a: *App, how: SettingsExit) void {
        if (how == .cancel) {
            if (a.theme_before_settings) |prev| a.applyTheme(prev.theme, prev.name);
        }
        a.theme_before_settings = null;
        a.settings_open = false;
    }

    fn settingsKey(a: *App, key: input.Key) void {
        const count = a.themes.len();
        switch (key) {
            .up => a.moveSettingsCursor(-1),
            .down => a.moveSettingsCursor(1),
            .page_up => a.moveSettingsCursor(-@as(i32, settings_window.list_rows)),
            .page_down => a.moveSettingsCursor(settings_window.list_rows),
            .home => a.setSettingsCursor(0),
            .end => a.setSettingsCursor(count -| 1),
            .enter => a.closeSettings(.keep),
            .escape => a.closeSettings(.cancel),
            else => {},
        }
    }

    fn moveSettingsCursor(a: *App, delta: i32) void {
        const current: i32 = @intCast(@min(a.settings_cursor, std.math.maxInt(i32)));
        a.setSettingsCursor(@intCast(@max(current + delta, 0)));
    }

    fn setSettingsCursor(a: *App, index: usize) void {
        const count = a.themes.len();
        if (count == 0) return;
        a.settings_cursor = @min(index, count - 1);
        a.previewTheme();
    }

    /// Put the theme under the cursor on screen straight away. A palette is
    /// the one setting whose name tells you nothing, and Winamp applied a
    /// skin the moment you picked it. A theme that fails to parse leaves the
    /// current one alone rather than blanking the player.
    fn previewTheme(a: *App) void {
        const t = a.themes.themeAt(
            a.arena,
            a.io,
            a.config_dir,
            a.settings_cursor,
        ) orelse return;
        a.applyTheme(t, a.themes.nameAt(a.settings_cursor));
    }

    fn applyTheme(a: *App, t: Theme, name: []const u8) void {
        a.theme = t;
        // The marquee borrows its separator from the glyph set.
        a.marquee.separator = t.glyphs.sep;
        // The catalog frees its names on the next listing, and this one is
        // kept until the config is written on exit, so take a copy in the
        // arena. Falling back to the original on failure is safe for the
        // frame being drawn and only risks a stale name in the config.
        a.theme_name = a.arena.dupe(u8, name) catch name;
    }

    fn cycleFocus(a: *App) void {
        const order = [_]Focus{ .main, .eq, .playlist };
        const current = for (order, 0..) |f, i| {
            if (f == a.focus) break i;
        } else 0;

        for (1..order.len + 1) |ahead| {
            const next = order[(current + ahead) % order.len];
            const open = switch (next) {
                .main => true,
                .eq => a.eq_open,
                .playlist => a.playlist_open,
            };
            if (open) {
                a.focus = next;
                return;
            }
        }
    }

    fn toggleEq(a: *App) void {
        a.eq_open = !a.eq_open;
        if (!a.eq_open and a.focus == .eq) a.focus = .main;
    }

    /// Hand the current settings to the audio thread.
    fn publishEq(a: *App) void {
        a.eq_settings.clampAll();
        a.eq_shared.publish(a.eq_settings);
    }

    fn eqGain(a: *App, control: usize) f32 {
        return if (control == 0) a.eq_settings.preamp_db else a.eq_settings.bands_db[control - 1];
    }

    fn setEqGain(a: *App, control: usize, db: f32) void {
        const clamped = std.math.clamp(db, -eq.gain_limit_db, eq.gain_limit_db);
        if (control == 0) {
            a.eq_settings.preamp_db = clamped;
        } else {
            a.eq_settings.bands_db[control - 1] = clamped;
        }
        a.publishEq();
    }

    /// The preset's name while the bands still match it, "custom" once they
    /// do not.
    fn eqPresetLabel(a: *App) []const u8 {
        const preset = eq.presets[a.eq_preset];
        if (eq.matchesPreset(a.eq_settings, preset)) return preset.name;
        return "custom";
    }

    fn cyclePreset(a: *App, backward: bool) void {
        const n = eq.presets.len;
        a.eq_preset = if (backward) (a.eq_preset + n - 1) % n else (a.eq_preset + 1) % n;
        a.eq_settings.bands_db = eq.presets[a.eq_preset].bands_db;
        a.publishEq();
    }

    /// Returns true when the key was consumed by the equalizer.
    fn handleEqKey(a: *App, key: input.Key, mods: input.Mods) bool {
        switch (key) {
            .left => {
                a.eq_cursor -|= 1;
                return true;
            },
            .right => {
                a.eq_cursor = @min(a.eq_cursor + 1, eq.band_count);
                return true;
            },
            .up => {
                a.setEqGain(a.eq_cursor, a.eqGain(a.eq_cursor) + eq_key_step);
                return true;
            },
            .down => {
                a.setEqGain(a.eq_cursor, a.eqGain(a.eq_cursor) - eq_key_step);
                return true;
            },
            .home => {
                a.eq_cursor = 0;
                return true;
            },
            .end => {
                a.eq_cursor = eq.band_count;
                return true;
            },
            .char => |ch| switch (ch) {
                'o' => {
                    a.eq_settings.enabled = !a.eq_settings.enabled;
                    a.publishEq();
                    return true;
                },
                'a' => {
                    a.eq_auto = !a.eq_auto;
                    return true;
                },
                'p' => {
                    a.cyclePreset(mods.shift);
                    return true;
                },
                '0' => {
                    if (mods.shift) {
                        a.eq_settings.reset();
                        a.eq_preset = 0;
                    } else {
                        a.setEqGain(a.eq_cursor, 0);
                    }
                    a.publishEq();
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    fn togglePlaylist(a: *App) void {
        a.playlist_open = !a.playlist_open;
        if (!a.playlist_open and a.focus == .playlist) a.focus = .main;
    }

    fn revealCurrent(a: *App) void {
        const idx = a.list.currentIndex() orelse return;
        a.list.cursor = idx;
        a.follow_cursor = true;
        if (!a.playlist_open) a.playlist_open = true;
    }

    fn handleMouse(a: *App, m: input.Mouse) void {
        // Modal, so the windows underneath do not take clicks meant for the
        // dialog — including the transport buttons.
        if (a.settings_open) {
            a.mouseSettings(m);
            return;
        }

        // The wheel is Winamp's volume control wherever the pointer sits,
        // except over the playlist, where it scrolls.
        if (m.button == .wheel_up or m.button == .wheel_down) {
            const over_playlist = a.playlist_open and
                a.playlist_origin.contains(.{ .x = m.x, .y = m.y });
            if (over_playlist) {
                const delta: usize = 3;
                if (m.button == .wheel_up) {
                    a.playlist_scroll -|= delta;
                } else {
                    a.playlist_scroll += delta;
                }
                // The wheel is the user saying where to look, so stop
                // following the cursor until they move it again.
                a.follow_cursor = false;
            } else if (m.button == .wheel_up) {
                a.player.nudgeVolume(0.05);
            } else {
                a.player.nudgeVolume(-0.05);
            }
            return;
        }

        switch (m.action) {
            .release => {
                a.drag = .none;
                return;
            },
            .drag => {
                a.continueDrag(m);
                return;
            },
            .motion => return,
            .press => {},
        }

        const point: Point = .{ .x = m.x, .y = m.y };
        if (a.playlist_open and a.playlist_origin.contains(point)) {
            a.pressPlaylist(point);
            return;
        }
        if (a.eq_open and a.eq_origin.contains(point)) {
            a.pressEq(point);
            return;
        }
        if (a.main_origin.contains(point)) a.pressMain(point);
    }

    fn mouseSettings(a: *App, m: input.Mouse) void {
        if (m.button == .wheel_up) {
            a.moveSettingsCursor(-1);
            return;
        }
        if (m.button == .wheel_down) {
            a.moveSettingsCursor(1);
            return;
        }
        if (m.action != .press) return;

        const r = settings_window.rect(a.screen.bounds());
        const local = r.localize(.{ .x = m.x, .y = m.y }) orelse return;
        switch (settings_window.hitTest(r, local, a.settings_scroll, a.themes.len())) {
            .close => a.closeSettings(.keep),
            .row => |index| a.setSettingsCursor(index),
            else => {},
        }
    }

    fn pressEq(a: *App, point: Point) void {
        a.focus = .eq;
        const l: eq_window.Layout = .compute();
        const local = a.eq_origin.localize(point) orelse return;

        switch (l.hitTest(local)) {
            .close, .shade => a.toggleEq(),
            .toggle_enabled => {
                a.eq_settings.enabled = !a.eq_settings.enabled;
                a.publishEq();
            },
            .toggle_auto => a.eq_auto = !a.eq_auto,
            .preset => a.cyclePreset(false),
            .preamp => |gain| {
                a.drag = .eq_preamp;
                a.eq_cursor = 0;
                a.setEqGain(0, gain);
            },
            .band => |b| {
                a.drag = .{ .eq_band = b.index };
                a.eq_cursor = b.index + 1;
                a.setEqGain(b.index + 1, b.gain_db);
            },
            else => {},
        }
    }

    fn pressMain(a: *App, point: Point) void {
        a.focus = .main;
        const l: main_window.Layout = .compute();
        const local = a.main_origin.localize(point) orelse return;

        switch (l.hitTest(local)) {
            .close => a.quit = true,
            .shade => a.shaded = !a.shaded,
            .time => a.show_remaining = !a.show_remaining,
            .vis => a.analyzer.mode = a.analyzer.mode.next(),
            .prev => a.step(.backward),
            .next => a.step(.forward),
            .play => a.player.play() catch {},
            .pause => a.player.pause(),
            .stop => a.player.stop(),
            .shuffle => a.list.setShuffle(!a.list.shuffle),
            .repeat => a.list.repeat = switch (a.list.repeat) {
                .off => .all,
                .all => .one,
                .one => .off,
            },
            .eq => a.toggleEq(),
            .playlist => a.togglePlaylist(),
            .seek => |v| {
                a.drag = .seek;
                a.player.seekFraction(v);
            },
            .volume => |v| {
                a.drag = .volume;
                a.player.setVolume(v);
            },
            .balance => |v| {
                a.drag = .balance;
                a.player.setBalance(v);
            },
            else => {},
        }
    }

    fn pressPlaylist(a: *App, point: Point) void {
        a.focus = .playlist;
        const l = playlist_window.Layout.compute(a.playlist_origin.w, a.playlist_origin.h);
        const local = a.playlist_origin.localize(point) orelse return;

        switch (l.hitTest(local, a.playlist_scroll, a.list.len())) {
            .close => a.togglePlaylist(),
            .shade => a.togglePlaylist(),
            .scrollbar => |target| {
                a.drag = .playlist_scroll;
                a.playlist_scroll = target;
                a.follow_cursor = false;
            },
            .row => |index| {
                const is_double = if (a.last_click) |c|
                    c.point.x == point.x and c.point.y == point.y and
                        a.frames -% c.frame < 10
                else
                    false;

                a.list.cursor = index;
                if (is_double) {
                    a.playCursor();
                    a.last_click = null;
                } else {
                    a.last_click = .{ .point = point, .frame = a.frames };
                }
            },
            else => {},
        }
    }

    /// Keep tracking a grabbed control even once the pointer has left it,
    /// which is what every real slider does.
    fn continueDrag(a: *App, m: input.Mouse) void {
        switch (a.drag) {
            .none => {},
            .seek, .volume, .balance => {
                const l: main_window.Layout = .compute();
                const rect = switch (a.drag) {
                    .seek => l.seek,
                    .volume => l.volume,
                    .balance => l.balance,
                    else => unreachable,
                };
                const win_x: i32 = @as(i32, m.x) - @as(i32, a.main_origin.x);
                const col = std.math.clamp(win_x - @as(i32, rect.x), 0, @as(i32, rect.w) - 1);
                const sl: Slider = .{ .width = rect.w };
                const value = sl.valueAt(@intCast(col));

                switch (a.drag) {
                    .seek => a.player.seekFraction(value),
                    .volume => a.player.setVolume(value),
                    .balance => a.player.setBalance(value * 2 - 1),
                    else => unreachable,
                }
            },
            // EQ sliders are vertical, so the row is what matters.
            .eq_preamp, .eq_band => {
                const win_y: i32 = @as(i32, m.y) - @as(i32, a.eq_origin.y);
                const l: eq_window.Layout = .compute();
                const rect = switch (a.drag) {
                    .eq_preamp => l.preamp,
                    .eq_band => |i| l.bands[@min(i, eq.band_count - 1)],
                    else => unreachable,
                };
                const row = std.math.clamp(win_y - @as(i32, rect.y), 0, @as(i32, rect.h) - 1);
                const gain = eq_window.gainForRow(@intCast(row));
                const control: usize = switch (a.drag) {
                    .eq_preamp => 0,
                    .eq_band => |i| i + 1,
                    else => unreachable,
                };
                a.setEqGain(control, gain);
            },
            // The scrollbar is vertical too, and its row maps straight onto
            // a scroll position, so the thumb follows the pointer exactly.
            .playlist_scroll => {
                const l = playlist_window.Layout.compute(
                    a.playlist_origin.w,
                    a.playlist_origin.h,
                );
                if (l.scrollbar.h == 0) return;
                const win_y: i32 = @as(i32, m.y) - @as(i32, a.playlist_origin.y);
                const row = std.math.clamp(
                    win_y - @as(i32, l.scrollbar.y),
                    0,
                    @as(i32, l.scrollbar.h) - 1,
                );
                a.playlist_scroll = playlist_window.scrollForThumbTop(
                    @intCast(row),
                    a.list.len(),
                    l.capacity(),
                    l.scrollbar.h,
                );
                a.follow_cursor = false;
            },
        }
    }

    // -- layout and drawing -------------------------------------------------

    fn playlistRows(a: *App) u16 {
        return a.playlist_origin.h -| playlist_window.chrome_rows;
    }

    fn draw(a: *App) void {
        a.screen.clear(.{ .bg = .{ .rgb = a.theme.bg } });

        const cols = a.screen.cols;
        const rows = a.screen.rows;

        // Below the main window's fixed size, fall back to the compact
        // windowshade view rather than clipping the full layout.
        const compact = cols < main_window.width or rows < main_window.height;
        const w = @min(main_window.width, cols);
        const main_h: u16 = if (compact or a.shaded)
            main_window.shade_height
        else
            main_window.height;

        if (w < main_window.min_shade_width or rows < main_h) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "need {d}x{d}", .{
                main_window.min_shade_width,
                main_window.shade_height,
            }) catch "too small";
            _ = a.screen.painter(a.screen.bounds()).text(0, 0, msg, a.theme.onBg(a.theme.text));
            a.main_origin = .empty;
            a.playlist_origin = .empty;
            return;
        }

        // Stack the windows the way Winamp does: main, equalizer, playlist.
        // The equalizer is a fixed size; the playlist takes whatever is left.
        // When there is not enough room, the playlist goes first and the
        // equalizer second, because the main window is the one you cannot do
        // without.
        var eq_h: u16 = 0;
        if (a.eq_open and !compact) {
            const spare = rows -| main_h;
            if (spare >= eq_window.height) eq_h = eq_window.height;
        }

        var pl_h: u16 = 0;
        if (a.playlist_open) {
            const spare = rows -| (main_h + eq_h + 1);
            if (spare >= playlist_window.min_height) {
                pl_h = @min(spare, max_playlist_rows);
            }
        }

        const total_h = main_h + eq_h + pl_h;
        const top = (rows - @min(total_h, rows)) / 2;
        const left = (cols - w) / 2;

        a.main_origin = .{ .x = left, .y = top, .w = w, .h = main_h };
        a.eq_origin = if (eq_h > 0)
            .{ .x = left, .y = top + main_h, .w = w, .h = eq_h }
        else
            .empty;
        a.playlist_origin = if (pl_h > 0)
            .{ .x = left, .y = top + main_h + eq_h, .w = w, .h = pl_h }
        else
            .empty;

        const mp = a.screen.painter(a.main_origin);
        const v = a.mainView(compact);
        if (compact or a.shaded) {
            main_window.drawShade(mp, v, a.marquee);
        } else {
            main_window.draw(mp, .compute(), v, a.marquee);
        }

        if (eq_h > 0) {
            eq_window.draw(a.screen.painter(a.eq_origin), .compute(), .{
                .theme = a.theme,
                .focused = a.focus == .eq,
                .settings = a.eq_settings,
                .auto = a.eq_auto,
                .preset_name = a.eqPresetLabel(),
                .cursor = a.eq_cursor,
            });
        }

        if (pl_h > 0) {
            // Settle the scroll before drawing. When the cursor has just
            // moved the view follows it, so keyboard navigation works
            // without the caller thinking about it; otherwise the view stays
            // where the user scrolled it to and is only held in range.
            const l = playlist_window.Layout.compute(w, pl_h);
            a.playlist_scroll = if (a.follow_cursor)
                playlist_window.scrollToShow(
                    a.playlist_scroll,
                    a.list.cursor,
                    a.list.len(),
                    l.capacity(),
                )
            else
                playlist_window.clampScroll(a.playlist_scroll, a.list.len(), l.capacity());
            a.follow_cursor = false;
            playlist_window.draw(a.screen.painter(a.playlist_origin), l, .{
                .theme = a.theme,
                .focused = a.focus == .playlist,
                .scroll = a.playlist_scroll,
            }, a.list);
        }

        // Last, so these sit over every window: that is what an overlay is.
        if (a.help_page) |page| {
            help.draw(a.screen.painter(help.rect(a.screen.bounds())), a.theme, page);
        }

        if (a.settings_open) {
            const r = settings_window.rect(a.screen.bounds());
            a.settings_scroll = playlist_window.scrollToShow(
                a.settings_scroll,
                a.settings_cursor,
                a.themes.len(),
                settings_window.rowsFor(r.h),
            );
            settings_window.draw(a.screen.painter(r), .{
                .theme = a.theme,
                .catalog = &a.themes,
                .cursor = a.settings_cursor,
                .scroll = a.settings_scroll,
            });
        }
    }

    fn mainView(a: *App, compact: bool) main_window.View {
        _ = compact;
        const p = a.player;
        const pos = p.position();
        const clock: u32 = if (a.show_remaining)
            @intFromFloat(@max(p.info.duration - pos, 0))
        else
            @intFromFloat(@max(pos, 0));

        return .{
            .theme = a.theme,
            .focused = a.focus == .main,
            .state = p.state,
            .title = a.currentTitle(),
            .clock_secs = clock,
            .show_remaining = a.show_remaining,
            .progress = p.progress(),
            .volume = p.volume,
            .balance = p.balance,
            .kbps = p.info.kbps,
            .sample_rate = p.info.sample_rate,
            .channels = p.info.channels,
            .shuffle = a.list.shuffle,
            .repeat = a.list.repeat != .off,
            .eq_open = a.eq_open,
            .playlist_open = a.playlist_open,
            // Winamp blinks the colon while paused.
            .colon_lit = p.state != .paused or (a.frames / 12) % 2 == 0,
            .track_index = a.list.currentIndex() orelse 0,
            .track_count = a.list.len(),
            .analyzer = a.analyzer,
        };
    }
};

comptime {
    // `scan` is used by main.zig rather than here; keep the import honest.
    _ = scan;
}
