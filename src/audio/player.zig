//! Transport state and the currently-loaded track.
//!
//! miniaudio's `ma_sound` has no notion of "paused" distinct from "stopped" —
//! `ma_sound_stop` just halts the data source where it stands. Winamp draws
//! three distinct states and binds separate keys to pause and stop, so the
//! distinction lives here: pause halts in place, stop halts and rewinds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const Sound = engine_mod.Sound;

pub const State = enum { stopped, playing, paused };

pub const TrackInfo = struct {
    /// Owned by the Player.
    path: []const u8 = "",
    /// Display title. Falls back to the filename until M4 parses tags.
    title: []const u8 = "",
    duration: f32 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    /// Average bitrate in kbps, derived from file size and duration. Exact
    /// per-frame bitrate for VBR files is an M4 concern.
    kbps: u32 = 0,
};

pub const Player = struct {
    gpa: Allocator,
    engine: *Engine,
    /// Heap-allocated, and never moved for as long as it is loaded.
    ///
    /// `ma_sound_init_*` registers the sound's own address in the engine's
    /// node graph, so copying or relocating the struct leaves the graph
    /// pointing at freed memory and the audio thread walks a dangling node.
    /// Every miniaudio node has this constraint, so the EQ and visualizer
    /// taps will need the same treatment.
    sound: ?*Sound = null,
    state: State = .stopped,
    info: TrackInfo = .{},

    /// 0.0 .. 1.0.
    volume: f32 = 1.0,
    /// -1.0 fully left .. +1.0 fully right.
    balance: f32 = 0,

    path_owned: ?[]u8 = null,
    title_owned: ?[]u8 = null,

    pub fn init(gpa: Allocator, engine: *Engine) Player {
        return .{ .gpa = gpa, .engine = engine };
    }

    pub fn deinit(p: *Player) void {
        p.closeTrack();
        p.* = undefined;
    }

    fn closeTrack(p: *Player) void {
        if (p.sound) |s| {
            s.deinit();
            p.gpa.destroy(s);
            p.sound = null;
        }
        if (p.path_owned) |b| p.gpa.free(b);
        if (p.title_owned) |b| p.gpa.free(b);
        p.path_owned = null;
        p.title_owned = null;
        p.info = .{};
        p.state = .stopped;
    }

    /// `display_title` is what the marquee shows. Pass null to derive it
    /// from the file's tags.
    pub fn open(
        p: *Player,
        io: std.Io,
        path: []const u8,
        display_title: ?[]const u8,
    ) !void {
        // Build the new sound before tearing down the old one, so a failed
        // load leaves the current track playing rather than killing it. It is
        // allocated rather than built on the stack because the node graph
        // keeps its address.
        const pathz = try p.gpa.dupeZ(u8, path);
        defer p.gpa.free(pathz);

        const next = try p.gpa.create(Sound);
        errdefer p.gpa.destroy(next);
        next.* = .{};
        try next.initFile(p.engine, pathz);
        errdefer next.deinit();

        const owned_path = try p.gpa.dupe(u8, path);
        errdefer p.gpa.free(owned_path);
        const owned_title = if (display_title) |t|
            try p.gpa.dupe(u8, t)
        else blk: {
            var tags = @import("../meta/tags.zig").read(p.gpa, io, path);
            defer tags.deinit(p.gpa);
            break :blk try tags.displayTitle(p.gpa, path);
        };
        errdefer p.gpa.free(owned_title);

        p.closeTrack();

        p.sound = next;
        p.path_owned = owned_path;
        p.title_owned = owned_title;

        const fmt = next.sourceFormat();
        const duration = next.lengthSeconds();
        p.info = .{
            .path = owned_path,
            .title = owned_title,
            .duration = duration,
            .sample_rate = fmt.sample_rate,
            .channels = fmt.channels,
            .kbps = averageKbps(io, path, duration),
        };

        p.applyMix();
    }

    fn applyMix(p: *Player) void {
        // Volume is the engine master rather than the sound's own, for two
        // reasons: it is what a master volume means, and miniaudio applies
        // it on the endpoint's output bus, which is downstream of the
        // visualizer tap. Setting it per-sound would instead make the
        // analyzer go flat whenever the user turned the volume down.
        p.engine.setVolume(p.volume);
        const s = p.sound orelse return;
        s.setPan(p.balance);
    }

    pub fn hasTrack(p: *const Player) bool {
        return p.sound != null;
    }

    pub fn play(p: *Player) !void {
        const s = p.sound orelse return;
        try s.start();
        p.state = .playing;
    }

    pub fn pause(p: *Player) void {
        const s = p.sound orelse return;
        if (p.state != .playing) return;
        s.stop();
        p.state = .paused;
    }

    pub fn togglePause(p: *Player) !void {
        switch (p.state) {
            .playing => p.pause(),
            .paused => try p.play(),
            .stopped => try p.play(),
        }
    }

    pub fn stop(p: *Player) void {
        const s = p.sound orelse return;
        s.stop();
        s.seekToFrame(0) catch {};
        p.state = .stopped;
    }

    pub fn position(p: *Player) f32 {
        const s = p.sound orelse return 0;
        if (p.state == .stopped) return 0;
        return s.cursorSeconds();
    }

    /// 0 when the duration is unknown, so callers can draw an empty seek bar
    /// rather than dividing by zero.
    pub fn progress(p: *Player) f32 {
        if (p.info.duration <= 0) return 0;
        return std.math.clamp(p.position() / p.info.duration, 0, 1);
    }

    pub fn seekSeconds(p: *Player, secs: f32) void {
        const s = p.sound orelse return;
        const rate = p.engine.sampleRate();
        if (rate == 0) return;
        const clamped = std.math.clamp(secs, 0, @max(p.info.duration - 0.05, 0));
        const frame: u64 = @intFromFloat(clamped * @as(f32, @floatFromInt(rate)));
        s.seekToFrame(frame) catch {};
    }

    pub fn seekBy(p: *Player, delta: f32) void {
        p.seekSeconds(p.position() + delta);
    }

    pub fn seekFraction(p: *Player, frac: f32) void {
        p.seekSeconds(std.math.clamp(frac, 0, 1) * p.info.duration);
    }

    pub fn setVolume(p: *Player, v: f32) void {
        p.volume = std.math.clamp(v, 0, 1);
        p.applyMix();
    }

    /// Re-apply the mix without a track loaded, so a volume chosen on the
    /// command line is in effect before the first sound exists.
    pub fn applyInitialMix(p: *Player) void {
        p.engine.setVolume(p.volume);
    }

    pub fn nudgeVolume(p: *Player, delta: f32) void {
        p.setVolume(p.volume + delta);
    }

    pub fn setBalance(p: *Player, b: f32) void {
        p.balance = std.math.clamp(b, -1, 1);
        p.applyMix();
    }

    /// True once per track when playback runs off the end, so the caller can
    /// advance the playlist. Clears the playing state as a side effect.
    pub fn consumeTrackEnded(p: *Player) bool {
        const s = p.sound orelse return false;
        if (p.state != .playing) return false;
        if (!s.atEnd()) return false;
        p.state = .stopped;
        return true;
    }
};

/// Filename without directory or extension. A stand-in for real tags.
pub fn titleFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

fn averageKbps(io: std.Io, path: []const u8, duration: f32) u32 {
    if (duration <= 0) return 0;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    const bits = @as(f64, @floatFromInt(st.size)) * 8;
    const kbps = bits / @as(f64, duration) / 1000.0;
    if (kbps <= 0 or kbps > 100_000) return 0;
    return @intFromFloat(@round(kbps));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "titleFromPath strips directory and extension" {
    try testing.expectEqualStrings("Dancing Mad", titleFromPath("/music/x/Dancing Mad.mp3"));
    try testing.expectEqualStrings("track", titleFromPath("track.flac"));
    try testing.expectEqualStrings("no-ext", titleFromPath("/a/b/no-ext"));
    // A leading dot is part of the name, not an extension separator.
    try testing.expectEqualStrings(".hidden", titleFromPath("/a/.hidden"));
    // Dots inside the name are kept; only the last one splits.
    try testing.expectEqualStrings("a.b", titleFromPath("a.b.mp3"));
    try testing.expectEqualStrings("", titleFromPath(""));
}
