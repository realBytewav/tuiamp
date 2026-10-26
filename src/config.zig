//! Settings that survive between runs.
//!
//! Stored as ZON at `$XDG_CONFIG_HOME/tuiamp/config.zon` (or
//! `~/.config/tuiamp/config.zon`). Missing or unreadable files are not an
//! error: the defaults are the same thing a first run would produce, and a
//! config that fails to parse should cost the user their settings, not their
//! music player.
//!
//! Everything here is plain data with an obvious text representation, so the
//! file stays hand-editable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const eq = @import("audio/eq.zig");

pub const dir_name = "tuiamp";
pub const file_name = "config.zon";
/// A config file larger than this is not a config file.
const max_bytes = 1 << 20;

pub const Config = struct {
    /// Percent, so the file reads sensibly.
    volume: u8 = 80,
    /// -100 (left) to 100 (right).
    balance: i8 = 0,
    theme: []const u8 = "classic",

    show_remaining: bool = false,
    shaded: bool = false,
    eq_open: bool = false,
    playlist_open: bool = true,

    shuffle: bool = false,
    /// "off", "all" or "one".
    repeat: []const u8 = "off",
    /// "spectrum", "oscilloscope" or "off".
    vis_mode: []const u8 = "spectrum",

    eq_enabled: bool = false,
    eq_auto: bool = false,
    eq_preamp_db: f32 = 0,
    eq_bands_db: [eq.band_count]f32 = @splat(0),
    eq_preset: u8 = 0,

    pub fn volumeFraction(c: Config) f32 {
        return @as(f32, @floatFromInt(@min(c.volume, 100))) / 100;
    }

    pub fn balanceFraction(c: Config) f32 {
        return std.math.clamp(@as(f32, @floatFromInt(c.balance)) / 100, -1, 1);
    }

    pub fn setVolume(c: *Config, v: f32) void {
        c.volume = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 100));
    }

    pub fn setBalance(c: *Config, v: f32) void {
        c.balance = @intFromFloat(@round(std.math.clamp(v, -1, 1) * 100));
    }

    pub fn eqSettings(c: Config) eq.Settings {
        var s: eq.Settings = .{
            .enabled = c.eq_enabled,
            .preamp_db = c.eq_preamp_db,
            .bands_db = c.eq_bands_db,
        };
        s.clampAll();
        return s;
    }

    pub fn setEqSettings(c: *Config, s: eq.Settings) void {
        c.eq_enabled = s.enabled;
        c.eq_preamp_db = s.preamp_db;
        c.eq_bands_db = s.bands_db;
    }
};

/// Parsed values borrow the arena, which the caller owns.
pub fn parse(arena: Allocator, source: [:0]const u8) Config {
    return std.zon.parse.fromSliceAlloc(Config, arena, source, null, .{
        // A config written by a newer version should still load here.
        .ignore_unknown_fields = true,
        .free_on_error = false,
    }) catch .{};
}

pub fn serialize(c: Config, writer: *std.Io.Writer) !void {
    try std.zon.stringify.serialize(c, .{ .whitespace = true }, writer);
    try writer.writeAll("\n");
}

/// `$XDG_CONFIG_HOME/tuiamp` or `~/.config/tuiamp`. Null when neither
/// variable is set, which is the case in a bare container.
pub fn configDir(arena: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, dir_name }) catch null;
    }
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fs.path.join(arena, &.{ home, ".config", dir_name }) catch null;
}

pub fn load(arena: Allocator, io: Io, dir: []const u8) Config {
    const path = std.fs.path.joinZ(arena, &.{ dir, file_name }) catch return .{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch
        return .{};

    // The ZON parser wants a sentinel-terminated source.
    const source = arena.allocSentinel(u8, bytes.len, 0) catch return .{};
    @memcpy(source, bytes);
    return parse(arena, source);
}

/// Best effort: a player that cannot write its config should still exit
/// cleanly.
pub fn save(gpa: Allocator, io: Io, dir: []const u8, c: Config) void {
    saveFallible(gpa, io, dir, c) catch {};
}

fn saveFallible(gpa: Allocator, io: Io, dir: []const u8, c: Config) !void {
    try Io.Dir.cwd().createDirPath(io, dir);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try serialize(c, &out.writer);

    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "defaults are sensible" {
    const c: Config = .{};
    try testing.expectApproxEqAbs(@as(f32, 0.8), c.volumeFraction(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.balanceFraction(), 0.001);
    try testing.expectEqualStrings("classic", c.theme);
    try testing.expect(!c.eq_enabled);
}

test "volume and balance round-trip through their stored form" {
    var c: Config = .{};
    for ([_]f32{ 0, 0.1, 0.5, 0.95, 1 }) |v| {
        c.setVolume(v);
        try testing.expectApproxEqAbs(v, c.volumeFraction(), 0.005);
    }
    for ([_]f32{ -1, -0.5, 0, 0.33, 1 }) |v| {
        c.setBalance(v);
        try testing.expectApproxEqAbs(v, c.balanceFraction(), 0.005);
    }
    // Out-of-range values are clamped, not wrapped.
    c.setVolume(5);
    try testing.expectEqual(@as(u8, 100), c.volume);
    c.setBalance(-9);
    try testing.expectEqual(@as(i8, -100), c.balance);
}

test "EQ settings survive the round trip and stay in range" {
    var c: Config = .{};
    var s: eq.Settings = .{ .enabled = true, .preamp_db = 99 };
    s.bands_db[3] = -99;
    c.setEqSettings(s);

    const back = c.eqSettings();
    try testing.expect(back.enabled);
    try testing.expectEqual(eq.gain_limit_db, back.preamp_db);
    try testing.expectEqual(-eq.gain_limit_db, back.bands_db[3]);
}

test "serialize then parse is lossless" {
    const gpa = testing.allocator;
    var original: Config = .{
        .volume = 35,
        .balance = -20,
        .theme = "ascii",
        .show_remaining = true,
        .shaded = true,
        .eq_open = true,
        .playlist_open = false,
        .shuffle = true,
        .repeat = "one",
        .vis_mode = "oscilloscope",
        .eq_enabled = true,
        .eq_preamp_db = -3.5,
        .eq_preset = 7,
    };
    original.eq_bands_db[0] = 9;
    original.eq_bands_db[9] = -4.5;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try serialize(original, &out.writer);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try arena.dupeZ(u8, out.written());
    const back = parse(arena, source);

    try testing.expectEqual(original.volume, back.volume);
    try testing.expectEqual(original.balance, back.balance);
    try testing.expectEqualStrings(original.theme, back.theme);
    try testing.expectEqual(original.show_remaining, back.show_remaining);
    try testing.expectEqual(original.shaded, back.shaded);
    try testing.expectEqual(original.playlist_open, back.playlist_open);
    try testing.expectEqual(original.shuffle, back.shuffle);
    try testing.expectEqualStrings(original.repeat, back.repeat);
    try testing.expectEqualStrings(original.vis_mode, back.vis_mode);
    try testing.expectEqual(original.eq_enabled, back.eq_enabled);
    try testing.expectApproxEqAbs(original.eq_preamp_db, back.eq_preamp_db, 0.001);
    try testing.expectEqual(original.eq_preset, back.eq_preset);
    try testing.expectApproxEqAbs(@as(f32, 9), back.eq_bands_db[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -4.5), back.eq_bands_db[9], 0.001);
}

test "a broken or partial config falls back to defaults" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Garbage.
    const broken = parse(arena, "this is not zon at all {{{");
    try testing.expectEqual(@as(u8, 80), broken.volume);

    // Empty.
    try testing.expectEqual(@as(u8, 80), parse(arena, "").volume);

    // Only some fields set: the rest keep their defaults.
    const partial = parse(arena, ".{ .volume = 25 }");
    try testing.expectEqual(@as(u8, 25), partial.volume);
    try testing.expectEqualStrings("classic", partial.theme);

    // A field this version does not know about is ignored rather than fatal.
    const future = parse(arena, ".{ .volume = 10, .some_future_option = true }");
    try testing.expectEqual(@as(u8, 10), future.volume);
}

test "configDir honours XDG_CONFIG_HOME, then HOME" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    try testing.expectEqual(@as(?[]const u8, null), configDir(arena, &env));

    try env.put("HOME", "/home/someone");
    try testing.expectEqualStrings("/home/someone/.config/tuiamp", configDir(arena, &env).?);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    try testing.expectEqualStrings("/xdg/tuiamp", configDir(arena, &env).?);

    // An empty XDG value falls through rather than producing "/tuiamp".
    try env.put("XDG_CONFIG_HOME", "");
    try testing.expectEqualStrings("/home/someone/.config/tuiamp", configDir(arena, &env).?);
}

test "save then load round-trips through the filesystem" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "cfg" });
    defer gpa.free(dir);

    var c: Config = .{ .volume = 42, .theme = "ascii", .shuffle = true };
    c.eq_bands_db[2] = 7.5;
    save(gpa, io, dir, c);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const back = load(arena_state.allocator(), io, dir);

    try testing.expectEqual(@as(u8, 42), back.volume);
    try testing.expectEqualStrings("ascii", back.theme);
    try testing.expect(back.shuffle);
    try testing.expectApproxEqAbs(@as(f32, 7.5), back.eq_bands_db[2], 0.001);
}

test "loading from a directory that does not exist gives defaults" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const c = load(arena_state.allocator(), testing.io, "/definitely/not/here");
    try testing.expectEqual(@as(u8, 80), c.volume);
}
