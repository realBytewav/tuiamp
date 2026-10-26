//! tuiamp — Winamp, but the "win" is a TUI.

const std = @import("std");

const engine_mod = @import("audio/engine.zig");
const player_mod = @import("audio/player.zig");
const tty_mod = @import("term/tty.zig");
const App = @import("ui/app.zig").App;
const Theme = @import("ui/theme.zig").Theme;
const List = @import("playlist/list.zig").List;
const eq = @import("audio/eq.zig");
const theme_mod = @import("ui/theme.zig");
const config_mod = @import("config.zig");
const scan = @import("playlist/scan.zig");

/// Restore the terminal before unwinding, so a crash never leaves the user
/// without a cursor or an echo.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, first_trace_addr: ?usize) noreturn {
        tty_mod.restoreActive();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.f);

const usage =
    \\tuiamp — Winamp, but the "win" is a TUI
    \\
    \\usage: tuiamp [options] <file|directory|playlist>...
    \\
    \\options:
    \\  --volume <0-100>   starting volume (overrides the saved one)
    \\  --theme <name>     classic, ascii, a name under
    \\                     ~/.config/tuiamp/themes/, or a path to a .zon file
    \\  --no-config        do not read or write ~/.config/tuiamp/config.zon
    \\  --devices          list the audio devices and exit
    \\  -h, --help         this text
    \\
    \\keys:
    \\  z x c v b   prev / play / pause / stop / next
    \\  space       play-pause             tab      switch window focus
    \\  left/right  seek 5s                up/down  volume
    \\  s shuffle   r repeat               j        jump to playing track
    \\  t elapsed/remaining                w        windowshade
    \\  g cycle the analyzer               q        quit
    \\  alt+e playlist                     alt+g    equalizer
    \\
    \\playlist (when focused):
    \\  up/down select   shift+up/down reorder   enter play   del remove
    \\
    \\equalizer (when focused):
    \\  left/right select band   up/down adjust   o on/off
    \\  p next preset            0 reset band     shift+0 reset all
    \\
    \\mouse: drag the seek, volume, balance and equalizer sliders; click the
    \\       transport buttons; double-click a playlist row to play it; the
    \\       wheel sets volume, or scrolls the playlist.
    \\
;

const Options = struct {
    /// Null means "whatever the config file says".
    volume: ?f32 = null,
    theme_name: ?[]const u8 = null,
    help: bool = false,
    no_config: bool = false,
    list_devices: bool = false,
    /// Indices into argv are not kept; paths are added as they are parsed.
    any_paths: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;

    // A seed that varies per run, so shuffle is not the same every time.
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));

    var list = List.init(gpa, seed);
    defer list.deinit();

    const opts = parseArgs(init.minimal.args, io, &list, err) catch {
        try err.flush();
        return 2;
    };

    if (opts.help) {
        try err.writeAll(usage);
        try err.flush();
        return 0;
    }
    if (opts.list_devices) {
        var out_buf: [8192]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &out_buf);
        try engine_mod.Engine.listDevices(&stdout.interface);
        try stdout.interface.flush();
        return 0;
    }
    if (!opts.any_paths) {
        try err.writeAll(usage);
        try err.flush();
        return 2;
    }
    if (list.isEmpty()) {
        try err.writeAll("tuiamp: nothing playable found\n");
        try err.flush();
        return 1;
    }

    // Settings and any loaded theme borrow this arena for the whole run.
    const arena = init.arena.allocator();
    const config_dir = if (opts.no_config)
        null
    else
        config_mod.configDir(arena, init.environ_map);

    var cfg: config_mod.Config = if (config_dir) |dir|
        config_mod.load(arena, io, dir)
    else
        .{};

    // The command line wins over the saved settings.
    if (opts.volume) |v| cfg.setVolume(v);
    const theme_name = opts.theme_name orelse cfg.theme;
    const theme = theme_mod.resolve(arena, io, config_dir, theme_name) orelse {
        try err.print("tuiamp: unknown theme '{s}'\n", .{theme_name});
        try err.flush();
        return 2;
    };
    cfg.theme = theme_name;

    var engine: engine_mod.Engine = .{};
    engine.init() catch |e| {
        // Say which half failed. A missing backend is almost always
        // libasound not being dlopen-able, and that is worth naming: the
        // alternative used to be a player that ran silently.
        switch (e) {
            error.NoAudioBackend => try err.writeAll(
                \\tuiamp: no audio backend available
                \\
                \\miniaudio loads libasound.so.2 with dlopen at runtime. If it is not
                \\on the loader path there is nothing to play through. Try:
                \\
                \\  env LD_LIBRARY_PATH=/run/current-system/sw/lib tuiamp ...
                \\
                \\Run `tuiamp --devices` to see what is visible.
                \\
            ),
            else => try err.writeAll("tuiamp: could not open an audio device\n"),
        }
        try err.flush();
        return 1;
    };
    defer engine.deinit();

    // The tap outlives every sound and is written to from the audio thread,
    // so it is allocated once and never moved.
    const tap = try gpa.create(engine_mod.VisTap);
    defer gpa.destroy(tap);
    tap.* = .{};
    // A failure here only costs the visualizer, so it is not fatal.
    engine.installTap(tap) catch {};

    // The EQ's cross-thread mailbox, likewise allocated once and never
    // moved, since the audio node holds a pointer to it.
    const eq_shared = try gpa.create(eq.Node.Shared);
    defer gpa.destroy(eq_shared);
    eq_shared.* = .{};
    engine.installEq(eq_shared) catch {};

    var player = player_mod.Player.init(gpa, &engine);
    defer player.deinit();

    var tty = tty_mod.Tty.init() catch {
        try err.writeAll("tuiamp: stdin is not a terminal\n");
        try err.flush();
        return 1;
    };
    try tty.enter();
    defer tty.deinit();

    var app = try App.init(gpa, io, &tty, &player, &list, tap, eq_shared, theme, cfg);
    defer app.deinit();

    app.start();
    try app.run();

    if (config_dir) |dir| config_mod.save(gpa, io, dir, app.currentConfig(theme_name));
    return 0;
}

fn parseArgs(
    args: std.process.Args,
    io: std.Io,
    list: *List,
    err: *std.Io.Writer,
) !Options {
    var opts: Options = .{};
    var it = args.iterate();
    _ = it.skip();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--volume")) {
            const v = it.next() orelse {
                try err.writeAll("tuiamp: --volume needs a value\n");
                return error.BadArgs;
            };
            const pct = std.fmt.parseInt(u8, v, 10) catch {
                try err.print("tuiamp: bad volume '{s}'\n", .{v});
                return error.BadArgs;
            };
            opts.volume = @as(f32, @floatFromInt(@min(pct, 100))) / 100.0;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            opts.theme_name = it.next() orelse {
                try err.writeAll("tuiamp: --theme needs a name\n");
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            opts.no_config = true;
        } else if (std.mem.eql(u8, arg, "--devices")) {
            opts.list_devices = true;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try err.print("tuiamp: unknown option '{s}'\n", .{arg});
            return error.BadArgs;
        } else {
            opts.any_paths = true;
            // A path that yields nothing is reported but does not abort the
            // rest: `tuiamp a.mp3 missing/ b.mp3` should still play a and b.
            const added = scan.addPath(list, io, arg) catch 0;
            if (added == 0) try err.print("tuiamp: nothing to add from '{s}'\n", .{arg});
        }
    }
    return opts;
}
