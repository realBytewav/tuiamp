//! Transport state and the currently-loaded track.
//!
//! miniaudio's `ma_sound` has no notion of "paused" distinct from "stopped" —
//! `ma_sound_stop` just halts the data source where it stands. Winamp draws
//! three distinct states and binds separate keys to pause and stop, so the
//! distinction lives here: pause halts in place, stop halts and rewinds.
//!
//! The player holds up to *two* tracks: the one playing, and the one armed to
//! take over from it. A join between them is a single instant on the engine's
//! global clock — the outgoing track is told to stop there and the incoming
//! one to start there — so the audio thread performs the handover with sample
//! accuracy and the UI only has to notice, afterwards, that it happened.
//! Nothing about the join depends on a frame of the UI loop arriving on time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const Sound = engine_mod.Sound;
const tags_mod = @import("../meta/tags.zig");

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

/// Silence an encoder wrote into the file itself, in samples at the file's own
/// rate. Zero for formats that store exactly what they were given.
pub const Trim = struct {
    /// Dead samples at the head, skipped when the track is loaded.
    delay: u32 = 0,
    /// Dead samples at the tail, which the next track starts over the top of.
    padding: u32 = 0,
};

/// One loaded track and everything owned on its behalf.
///
/// The sound is heap-allocated and never moved for as long as it is loaded:
/// `ma_sound_init_*` registers the sound's own address in the engine's node
/// graph, so copying or relocating it leaves the graph pointing at freed
/// memory and the audio thread walks a dangling node. Every miniaudio node
/// has this constraint, which is why this struct holds a pointer rather than
/// the sound itself and can therefore be moved around freely.
const Loaded = struct {
    sound: *Sound,
    /// Owned; `info.path` aliases it.
    path: []u8,
    /// Owned; `info.title` aliases it.
    title: []u8,
    info: TrackInfo,
    trim: Trim = .{},
    /// Engine frame at which this track hands over. Zero when nothing is
    /// armed to take over from it.
    join: u64 = 0,

    fn destroy(t: *Loaded, gpa: Allocator) void {
        t.sound.deinit();
        gpa.destroy(t.sound);
        gpa.free(t.path);
        gpa.free(t.title);
    }
};

pub const Player = struct {
    gpa: Allocator,
    engine: *Engine,
    /// The track being played.
    current: ?Loaded = null,
    /// The track scheduled to follow it, already open and already started —
    /// but silent until its instant arrives.
    next: ?Loaded = null,
    state: State = .stopped,

    /// 0.0 .. 1.0.
    volume: f32 = 1.0,
    /// -1.0 fully left .. +1.0 fully right.
    balance: f32 = 0,

    pub fn init(gpa: Allocator, engine: *Engine) Player {
        return .{ .gpa = gpa, .engine = engine };
    }

    pub fn deinit(p: *Player) void {
        p.dropNext();
        p.closeTrack();
        p.* = undefined;
    }

    /// What is playing. Default-valued when nothing is loaded, so callers can
    /// read it without unwrapping.
    pub fn info(p: *const Player) TrackInfo {
        const t = p.current orelse return .{};
        return t.info;
    }

    fn closeTrack(p: *Player) void {
        if (p.current) |*t| t.destroy(p.gpa);
        p.current = null;
        p.state = .stopped;
    }

    /// Build a track without disturbing whatever is already loaded.
    fn load(
        p: *Player,
        io: std.Io,
        path: []const u8,
        display_title: ?[]const u8,
    ) !Loaded {
        const pathz = try p.gpa.dupeZ(u8, path);
        defer p.gpa.free(pathz);

        const sound = try p.gpa.create(Sound);
        errdefer p.gpa.destroy(sound);
        sound.* = .{};
        try sound.initFile(p.engine, pathz);
        errdefer sound.deinit();

        const owned_path = try p.gpa.dupe(u8, path);
        errdefer p.gpa.free(owned_path);
        const owned_title = if (display_title) |t|
            try p.gpa.dupe(u8, t)
        else blk: {
            var tags = tags_mod.read(p.gpa, io, path);
            defer tags.deinit(p.gpa);
            break :blk try tags.displayTitle(p.gpa, path);
        };
        errdefer p.gpa.free(owned_title);

        const fmt = sound.sourceFormat();
        const duration = sound.lengthSeconds();
        return .{
            .sound = sound,
            .path = owned_path,
            .title = owned_title,
            .info = .{
                .path = owned_path,
                .title = owned_title,
                .duration = duration,
                .sample_rate = fmt.sample_rate,
                .channels = fmt.channels,
                .kbps = averageKbps(io, path, duration),
            },
        };
    }

    /// `display_title` is what the marquee shows. Pass null to derive it
    /// from the file's tags.
    pub fn open(
        p: *Player,
        io: std.Io,
        path: []const u8,
        display_title: ?[]const u8,
    ) !void {
        // Build the new track before tearing down the old one, so a failed
        // load leaves the current track playing rather than killing it.
        const loaded = try p.load(io, path, display_title);

        p.disarmNext();
        p.closeTrack();
        p.current = loaded;
        p.applyMix();
    }

    fn applyMix(p: *Player) void {
        // Volume is the engine master rather than the sound's own, for two
        // reasons: it is what a master volume means, and miniaudio applies
        // it on the endpoint's output bus, which is downstream of the
        // visualizer tap. Setting it per-sound would instead make the
        // analyzer go flat whenever the user turned the volume down.
        p.engine.setVolume(p.volume);
        // Both tracks: an armed one is about to be heard and must already be
        // panned the same way, or the balance would jump at the join.
        if (p.current) |t| t.sound.setPan(p.balance);
        if (p.next) |t| t.sound.setPan(p.balance);
    }

    pub fn hasTrack(p: *const Player) bool {
        return p.current != null;
    }

    pub fn play(p: *Player) !void {
        const t = p.current orelse return;
        try t.sound.start();
        p.state = .playing;
    }

    pub fn pause(p: *Player) void {
        const t = p.current orelse return;
        if (p.state != .playing) return;
        // An armed instant is absolute: it would arrive while we sat paused
        // and start the next track over the top of a halted one.
        p.disarmNext();
        t.sound.stop();
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
        const t = p.current orelse return;
        p.disarmNext();
        t.sound.stop();
        t.sound.seekToFrame(t.trim.delay) catch {};
        p.state = .stopped;
    }

    pub fn position(p: *Player) f32 {
        const t = p.current orelse return 0;
        if (p.state == .stopped) return 0;
        return t.sound.cursorSeconds();
    }

    /// 0 when the duration is unknown, so callers can draw an empty seek bar
    /// rather than dividing by zero.
    pub fn progress(p: *Player) f32 {
        const duration = p.info().duration;
        if (duration <= 0) return 0;
        return std.math.clamp(p.position() / duration, 0, 1);
    }

    /// Seconds left of the current track, which is what decides when the next
    /// one is worth loading.
    pub fn remaining(p: *Player) f32 {
        const duration = p.info().duration;
        if (duration <= 0) return 0;
        return @max(duration - p.position(), 0);
    }

    pub fn seekSeconds(p: *Player, secs: f32) void {
        const t = p.current orelse return;
        const rate = p.engine.sampleRate();
        if (rate == 0) return;
        // Seeking moves the end of the track, so any instant computed from
        // where it used to be is now wrong.
        p.disarmNext();
        const clamped = std.math.clamp(secs, 0, @max(t.info.duration - 0.05, 0));
        const frame: u64 = @intFromFloat(clamped * @as(f32, @floatFromInt(rate)));
        t.sound.seekToFrame(frame) catch {};
    }

    pub fn seekBy(p: *Player, delta: f32) void {
        p.seekSeconds(p.position() + delta);
    }

    pub fn seekFraction(p: *Player, frac: f32) void {
        p.seekSeconds(std.math.clamp(frac, 0, 1) * p.info().duration);
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

    // -- the join -----------------------------------------------------------

    pub fn hasNextArmed(p: *const Player) bool {
        return p.next != null;
    }

    /// The engine frame the current track should hand over at: now, plus
    /// whatever is left of it. Null when the length is not knowable, which is
    /// what makes a stream unarmable.
    fn joinFrames(p: *Player, t: Loaded) ?u64 {
        const total = t.sound.lengthFrames();
        if (total == 0) return null;

        const src_rate = t.info.sample_rate;
        const engine_rate = p.engine.sampleRate();
        if (src_rate == 0 or engine_rate == 0) return null;

        // The encoder's trailing padding is silence, so the successor starts
        // over the top of it rather than after it.
        const end = total -| @as(u64, t.trim.padding);
        const left_src = end -| t.sound.cursorFrames();

        // Widened, because frames times a sample rate overflows u64 for a
        // long enough track.
        const left_engine = @as(u128, left_src) * engine_rate / src_rate;
        return p.engine.timeFrames() + @as(u64, @intCast(left_engine));
    }

    /// Load `path` and schedule it to take over the instant the current track
    /// ends. The successor is started here, but stays silent until then.
    ///
    /// Errors leave the current track playing and nothing armed, so a caller
    /// can treat failure as "not gapless this time" rather than as a fault.
    pub fn armNext(
        p: *Player,
        io: std.Io,
        path: []const u8,
        display_title: ?[]const u8,
    ) !void {
        if (p.state != .playing) return error.NotPlaying;
        if (p.next != null) return error.AlreadyArmed;
        const cur = p.current orelse return error.NoTrack;
        const join = p.joinFrames(cur) orelse return error.LengthUnknown;

        var loaded = try p.load(io, path, display_title);
        errdefer loaded.destroy(p.gpa);

        loaded.sound.setStartTimeFrames(join);
        try loaded.sound.start();

        // Only now that the successor is certain to play do we tell the
        // outgoing track to stop there. Its stop time *is* the join, so the
        // two can never be audible at once: if the arithmetic above were ever
        // wrong, the symptom is a clipped tail, not two tracks together.
        p.current.?.sound.setStopTimeFrames(join);
        p.current.?.join = join;
        p.next = loaded;
        p.applyMix();
    }

    /// Give up on an armed successor and put the current track back to
    /// playing out to its own end. Idempotent.
    pub fn disarmNext(p: *Player) void {
        p.dropNext();
        if (p.current) |*t| {
            // Or it would fall silent at an instant nothing is taking over.
            t.sound.clearSchedule();
            t.join = 0;
        }
    }

    fn dropNext(p: *Player) void {
        if (p.next) |*t| {
            t.sound.stop();
            t.destroy(p.gpa);
        }
        p.next = null;
    }

    /// True once per join, after the audio thread has already made it: the
    /// armed track is now the one being heard, so the caller should move the
    /// playlist to match. Bookkeeping only — it issues no audio call.
    pub fn consumeHandoff(p: *Player) bool {
        if (p.state != .playing) return false;
        if (p.next == null or p.current == null) return false;

        const cur = &p.current.?;
        const reached = cur.join != 0 and p.engine.timeFrames() >= cur.join;
        // `atEnd` as well as the clock, because with no padding to trim the
        // two coincide and either may be observed first.
        if (!reached and !cur.sound.atEnd()) return false;

        cur.destroy(p.gpa);
        p.current = p.next;
        p.next = null;
        p.state = .playing;
        p.applyMix();
        return true;
    }

    /// True once per track when playback runs off the end, so the caller can
    /// advance the playlist. Clears the playing state as a side effect.
    pub fn consumeTrackEnded(p: *Player) bool {
        const t = p.current orelse return false;
        if (p.state != .playing) return false;
        // A handover takes precedence: the successor is already being heard,
        // so the playlist must follow it rather than open anything.
        if (p.next != null) return false;
        if (!t.sound.atEnd()) return false;
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

const tone = @import("tone.zig");
const eq_mod = @import("eq.zig");

/// A player wired to a no-device engine through the real effect chain, with a
/// scratch directory to put tracks in.
///
/// Everything here is read back from the node graph's output, because that is
/// the only vantage point that can tell silence from sound: the visualizer
/// taps upstream of the master volume, so it cannot.
const Rig = struct {
    gpa: Allocator,
    engine: *Engine,
    tap: *engine_mod.VisTap,
    eq_shared: *eq_mod.Node.Shared,
    player: Player,
    tmp: testing.TmpDir,
    root: [:0]u8,

    const rate: u32 = 48000;

    fn init() !Rig {
        const gpa = testing.allocator;

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(root);

        const engine = try gpa.create(Engine);
        errdefer gpa.destroy(engine);
        engine.* = .{};
        try engine.initCapture(2, rate);
        errdefer engine.deinit();

        const tap = try gpa.create(engine_mod.VisTap);
        errdefer gpa.destroy(tap);
        tap.* = .{};
        try engine.installTap(tap);

        const eq_shared = try gpa.create(eq_mod.Node.Shared);
        errdefer gpa.destroy(eq_shared);
        eq_shared.* = .{};
        try engine.installEq(eq_shared);

        return .{
            .gpa = gpa,
            .engine = engine,
            .tap = tap,
            .eq_shared = eq_shared,
            .player = Player.init(gpa, engine),
            .tmp = tmp,
            .root = root,
        };
    }

    fn deinit(r: *Rig) void {
        // Sounds first: a node must not outlive the graph it is attached to.
        r.player.deinit();
        r.engine.deinit();
        r.gpa.destroy(r.engine);
        r.gpa.destroy(r.tap);
        r.gpa.destroy(r.eq_shared);
        r.gpa.free(r.root);
        r.tmp.cleanup();
    }

    fn writeTone(r: *Rig, name: []const u8, frames: u32, hz: f32) !void {
        try tone.writeWav(r.gpa, testing.io, r.tmp.dir, name, .{
            .frames = frames,
            .rate = rate,
            .hz = hz,
        });
    }

    /// Caller frees.
    fn path(r: *Rig, name: []const u8) ![]u8 {
        return std.fs.path.join(r.gpa, &.{ r.root, name });
    }

    /// Pull one block and report the RMS of what a sound card would have been
    /// handed. The engine's clock only advances here, which is what makes
    /// every scheduled instant in these tests deterministic.
    fn level(r: *Rig, frames: u32) !f32 {
        const buf = try r.gpa.alloc(f32, frames * 2);
        defer r.gpa.free(buf);
        @memset(buf, 0);
        const got = r.engine.read(buf, frames);
        return tone.rms(buf[0 .. got * 2]);
    }
};

/// 40 ms — the cadence `App.run` polls at, and so the resolution at which the
/// old open-it-once-it-ends behaviour could notice a track had finished.
const poll_block: u32 = Rig.rate * 40 / 1000;

const Seam = struct {
    /// Quietest block across the seam, as a fraction of the steady level.
    floor: f32,
    /// Loudest, by the same measure. Above 1 means two tracks at once.
    ceiling: f32,
};

/// Play one full-scale tone into another and measure every block across the
/// seam. `arm` chooses between a scheduled join and the behaviour the player
/// had before there was one: notice at a poll boundary, then open the file.
///
/// Note this *understates* the old gap, because opening a file costs nothing
/// in wall-clock terms here. What it does reproduce is the poll latency —
/// a track that runs dry between two polls is silence until the next one.
fn measureSeam(arm: bool) !Seam {
    var rig = try Rig.init();
    defer rig.deinit();

    // Deliberately not a whole number of blocks: a track that happens to end
    // exactly on a poll boundary would be joined perfectly by luck.
    const track_frames: u32 = poll_block * 12 + poll_block / 2;
    try rig.writeTone("a.wav", track_frames, 440);
    try rig.writeTone("b.wav", track_frames, 660);

    const a_path = try rig.path("a.wav");
    defer rig.gpa.free(a_path);
    const b_path = try rig.path("b.wav");
    defer rig.gpa.free(b_path);

    rig.player.setVolume(1.0);
    try rig.player.open(testing.io, a_path, "A");
    try rig.player.play();

    // The graph starts cold; discard the first blocks, then take the level
    // the rest is measured against from the one after.
    _ = try rig.level(poll_block);
    _ = try rig.level(poll_block);
    const steady = try rig.level(poll_block);

    if (arm) try rig.player.armNext(testing.io, b_path, "B");

    var floor: f32 = std.math.floatMax(f32);
    var ceiling: f32 = 0;
    // Enough to cross the seam and settle well inside the second track, but
    // short of its end, so no trailing silence of its own gets measured.
    for (0..16) |_| {
        const got = try rig.level(poll_block);
        floor = @min(floor, got);
        ceiling = @max(ceiling, got);

        if (rig.player.consumeHandoff()) continue;
        if (rig.player.consumeTrackEnded()) {
            try rig.player.open(testing.io, b_path, "B");
            try rig.player.play();
        }
    }

    // Asserted here rather than returned: the title is owned by the player,
    // which this function's `defer` is about to tear down.
    try testing.expectEqualStrings("B", rig.player.info().title);

    return .{
        .floor = floor / steady,
        .ceiling = ceiling / steady,
    };
}

test "an armed successor joins on with no silence and no overlap" {
    const seam = try measureSeam(true);

    // Full-scale sine on both sides of the join, so every block across it
    // must still be full-scale. This is the whole claim.
    try testing.expect(seam.floor > 0.9);
    // And no block is louder than one track, which is what two tracks
    // playing over each other would look like.
    try testing.expect(seam.ceiling < 1.2);
}

test "without an armed successor the same two tracks have a measurable gap" {
    const seam = try measureSeam(false);

    // The counterpart of the test above: proof that it is able to fail, and
    // a measure of what was wrong before. The dip is the part of a poll
    // period that the first track did not fill.
    try testing.expect(seam.floor < 0.8);
}

test "a scheduled join is better than no join" {
    // Stated comparatively as well, because the two thresholds above are
    // chosen constants and this relationship is the thing that matters.
    const armed = try measureSeam(true);
    const bare = try measureSeam(false);
    try testing.expect(armed.floor > bare.floor);
}

/// Open a track, play it, and arm a successor. Returns the rig for the caller
/// to interfere with.
fn armedRig(rig: *Rig) !void {
    const half: u32 = Rig.rate / 2;
    try rig.writeTone("a.wav", half, 440);
    try rig.writeTone("b.wav", half, 660);

    const a_path = try rig.path("a.wav");
    defer rig.gpa.free(a_path);
    const b_path = try rig.path("b.wav");
    defer rig.gpa.free(b_path);

    rig.player.setVolume(1.0);
    try rig.player.open(testing.io, a_path, "A");
    try rig.player.play();
    _ = try rig.level(1024);
    try rig.player.armNext(testing.io, b_path, "B");
    try testing.expect(rig.player.hasNextArmed());
}

test "pausing drops the armed successor, so it cannot start over a halted track" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    rig.player.pause();
    try testing.expect(!rig.player.hasNextArmed());

    // Nothing comes out while paused, however long the armed instant was.
    for (0..20) |_| try testing.expect(try rig.level(poll_block) < 0.001);
}

test "seeking drops the armed successor, because it moved the end of the track" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    rig.player.seekBy(-0.1);
    try testing.expect(!rig.player.hasNextArmed());
}

test "stopping drops the armed successor" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    rig.player.stop();
    try testing.expect(!rig.player.hasNextArmed());
}

test "a disarmed successor never becomes audible, and the track still ends" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    rig.player.disarmNext();
    try testing.expect(!rig.player.hasNextArmed());

    // The first track plays out to its own end and then there is silence:
    // disarming must also have taken back the stop time it was given.
    var ended = false;
    var quiet_at_end = false;
    for (0..20) |_| {
        const got = try rig.level(poll_block);
        if (rig.player.consumeTrackEnded()) ended = true;
        if (ended) quiet_at_end = got < 0.3;
    }
    try testing.expect(ended);
    try testing.expect(quiet_at_end);
    try testing.expectEqualStrings("A", rig.player.info().title);
}

test "the handover reports once, and only once" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    var handoffs: u32 = 0;
    for (0..40) |_| {
        _ = try rig.level(poll_block);
        if (rig.player.consumeHandoff()) handoffs += 1;
    }
    try testing.expectEqual(@as(u32, 1), handoffs);
    try testing.expectEqualStrings("B", rig.player.info().title);
    try testing.expect(!rig.player.hasNextArmed());
}

test "a track that ended under a handover does not also report as ended" {
    var rig = try Rig.init();
    defer rig.deinit();
    try armedRig(&rig);

    // `consumeTrackEnded` driving the playlist as well would advance it twice
    // and open a file over the track that just started playing itself.
    //
    // Checked in the opposite order to `App.tick`, which looks for the
    // handover first: the guard has to hold whichever is asked first. The
    // loop stops at the join, because the successor reaching its *own* end
    // later on is an ordinary track ending and does report.
    var ends: u32 = 0;
    var joined = false;
    var blocks: u32 = 0;
    while (!joined and blocks < 40) : (blocks += 1) {
        _ = try rig.level(poll_block);
        if (rig.player.consumeTrackEnded()) ends += 1;
        if (rig.player.consumeHandoff()) joined = true;
    }
    try testing.expect(joined);
    try testing.expectEqual(@as(u32, 0), ends);
}

test "arming is refused when there is nothing playing to arm behind" {
    var rig = try Rig.init();
    defer rig.deinit();

    const half: u32 = Rig.rate / 2;
    try rig.writeTone("a.wav", half, 440);
    const a_path = try rig.path("a.wav");
    defer rig.gpa.free(a_path);

    try testing.expectError(error.NotPlaying, rig.player.armNext(testing.io, a_path, "A"));

    try rig.player.open(testing.io, a_path, "A");
    try testing.expectError(error.NotPlaying, rig.player.armNext(testing.io, a_path, "A"));

    try rig.player.play();
    try rig.player.armNext(testing.io, a_path, "A");
    try testing.expectError(error.AlreadyArmed, rig.player.armNext(testing.io, a_path, "A"));
}

test "a successor that cannot be opened leaves the current track alone" {
    var rig = try Rig.init();
    defer rig.deinit();

    const half: u32 = Rig.rate / 2;
    try rig.writeTone("a.wav", half, 440);
    const a_path = try rig.path("a.wav");
    defer rig.gpa.free(a_path);

    rig.player.setVolume(1.0);
    try rig.player.open(testing.io, a_path, "A");
    try rig.player.play();
    _ = try rig.level(1024);

    const missing = try rig.path("nope.wav");
    defer rig.gpa.free(missing);
    try testing.expectError(error.SoundInitFailed, rig.player.armNext(testing.io, missing, "B"));

    try testing.expect(!rig.player.hasNextArmed());
    // Still playing, still audible, still itself.
    try testing.expectEqual(State.playing, rig.player.state);
    try testing.expect(try rig.level(1024) > 0.3);
    try testing.expectEqualStrings("A", rig.player.info().title);
}
