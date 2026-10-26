//! Thin Zig surface over miniaudio's high-level engine.
//!
//! The engine owns the device thread and a resource-manager job thread, so
//! file decoding happens off the audio callback. Everything here is called
//! from the UI thread only.

const std = @import("std");
const c = @import("../c.zig").c;
const tap_mod = @import("tap.zig");
const eq_mod = @import("eq.zig");

/// About 170ms of audio at 48kHz: far more than the analyzer's window, which
/// is what keeps the lock-free read from ever being lapped in practice.
pub const VisTap = tap_mod.Tap(8192);

pub const Error = error{
    NoAudioBackend,
    EngineInitFailed,
    SoundInitFailed,
    SeekFailed,
    StartFailed,
    NodeInitFailed,
    AttachFailed,
};

fn check(result: c.ma_result, e: Error) Error!void {
    if (result != c.MA_SUCCESS) return e;
}

/// Owns the device and the node graph.
///
/// Must live at a stable address for as long as it is initialized: the node
/// graph inside it holds pointers to its own members.
pub const Engine = struct {
    raw: c.ma_engine = undefined,
    /// Created explicitly rather than letting the engine make its own, so
    /// the backend list can exclude the null device.
    ctx: c.ma_context = undefined,
    ctx_ready: bool = false,
    initialized: bool = false,
    /// Inserted ahead of the endpoint so the visualizer sees exactly what
    /// the device is about to play, after every effect in the chain.
    tap_node: TapNode = undefined,
    tap_ready: bool = false,
    /// Ahead of the tap, so the analyzer shows the equalized signal and the
    /// user can see the EQ working.
    eq_node: eq_mod.Node = undefined,
    eq_ready: bool = false,

    /// Every backend miniaudio knows about except the null one, in its own
    /// priority order.
    ///
    /// The null backend is deliberately excluded. It consumes frames at the
    /// right rate and reports success, so falling back to it produces a
    /// player whose clock advances and whose analyzer dances while making no
    /// sound at all — which is indistinguishable from a bug until you think
    /// to check. Better to fail loudly and say why.
    const real_backends = blk: {
        var list: [c.ma_backend_null]c.ma_backend = undefined;
        for (0..c.ma_backend_null) |i| list[i] = @intCast(i);
        break :blk list;
    };

    /// Which devices the engine is allowed to open.
    pub const Backend = enum {
        /// Any real backend, in miniaudio's priority order.
        auto,
        /// miniaudio's null device: consumes frames at the correct rate and
        /// makes no sound. Only ever selected when asked for by name, so it
        /// cannot become a silent fallback, but reachable so the interface
        /// can be driven on a machine with no sound card.
        null_device,
    };

    pub fn init(self: *Engine) Error!void {
        return self.initBackend(.auto);
    }

    pub fn initBackend(self: *Engine, backend: Backend) Error!void {
        const list: []const c.ma_backend = switch (backend) {
            .auto => &real_backends,
            .null_device => &[_]c.ma_backend{c.ma_backend_null},
        };
        try check(
            c.ma_context_init(list.ptr, @intCast(list.len), null, &self.ctx),
            error.NoAudioBackend,
        );
        self.ctx_ready = true;
        errdefer {
            _ = c.ma_context_uninit(&self.ctx);
            self.ctx_ready = false;
        }

        var cfg = c.ma_engine_config_init();
        cfg.pContext = &self.ctx;
        // Let miniaudio pick the device's native rate; the decoder resamples.
        cfg.noAutoStart = c.MA_FALSE;
        try check(c.ma_engine_init(&cfg, &self.raw), error.EngineInitFailed);
        self.initialized = true;
    }

    /// Name of the device actually opened, for display and for diagnosing
    /// "why can I not hear anything".
    pub fn deviceName(self: *Engine) []const u8 {
        if (!self.initialized) return "none";
        const device = c.ma_engine_get_device(&self.raw);
        if (device == null) return "none";
        const name: [*:0]const u8 = @ptrCast(&device.*.playback.name);
        const span = std.mem.span(name);
        return if (span.len == 0) "unknown" else span;
    }

    /// An engine with no device, driven by `read` instead of a sound card.
    ///
    /// This is how the output path gets tested: everything downstream of the
    /// visualizer tap — the endpoint's own master volume above all — is
    /// invisible to the analyzer, so the only way to check what a listener
    /// would actually hear is to read the graph's output directly.
    pub fn initCapture(self: *Engine, channel_count: u32, sample_rate: u32) Error!void {
        var cfg = c.ma_engine_config_init();
        cfg.noDevice = c.MA_TRUE;
        cfg.channels = channel_count;
        cfg.sampleRate = sample_rate;
        try check(c.ma_engine_init(&cfg, &self.raw), error.EngineInitFailed);
        self.initialized = true;
    }

    /// Pull interleaved f32 frames from the graph, exactly as a device would.
    /// Only valid on an engine created with `initCapture`.
    pub fn read(self: *Engine, out: []f32, frames: u64) u64 {
        var read_frames: c.ma_uint64 = 0;
        _ = c.ma_engine_read_pcm_frames(&self.raw, out.ptr, frames, &read_frames);
        return read_frames;
    }

    /// Install the visualizer tap. Optional: without it the engine still
    /// plays, the analyzer just has nothing to show.
    pub fn installTap(self: *Engine, tap: *VisTap) Error!void {
        if (!self.initialized or self.tap_ready) return;
        try self.tap_node.init(self, tap);
        self.tap_ready = true;
    }

    /// Install the equalizer ahead of the tap. Must be called after
    /// `installTap`, so the EQ has something to feed.
    pub fn installEq(self: *Engine, shared: *eq_mod.Node.Shared) !void {
        if (!self.initialized or self.eq_ready) return;
        try self.eq_node.init(
            c.ma_engine_get_node_graph(&self.raw),
            self.sink(),
            shared,
            self.channels(),
            self.sampleRate(),
        );
        self.eq_ready = true;
    }

    /// Where newly created sounds should send their output: the head of the
    /// effect chain, whichever parts of it exist.
    fn sink(self: *Engine) *anyopaque {
        if (self.eq_ready) return &self.eq_node.base;
        if (self.tap_ready) return &self.tap_node.base;
        return c.ma_engine_get_endpoint(&self.raw).?;
    }

    pub fn deinit(self: *Engine) void {
        if (!self.initialized) return;
        // Nodes must go before the graph that owns them, and downstream
        // nodes must outlive the ones feeding them.
        if (self.eq_ready) {
            self.eq_node.deinit();
            self.eq_ready = false;
        }
        if (self.tap_ready) {
            self.tap_node.deinit();
            self.tap_ready = false;
        }
        c.ma_engine_uninit(&self.raw);
        self.initialized = false;
        if (self.ctx_ready) {
            _ = c.ma_context_uninit(&self.ctx);
            self.ctx_ready = false;
        }
    }

    /// Print the backends and devices miniaudio can see, and which one would
    /// be chosen. Diagnostic for machines with several sound cards.
    pub fn listDevices(w: *std.Io.Writer, backend: Backend) !void {
        const list: []const c.ma_backend = switch (backend) {
            .auto => &real_backends,
            .null_device => &[_]c.ma_backend{c.ma_backend_null},
        };
        var ctx: c.ma_context = undefined;
        if (c.ma_context_init(list.ptr, @intCast(list.len), null, &ctx) != c.MA_SUCCESS) {
            try w.writeAll("no usable audio backend\n");
            try w.writeAll("  (on Linux this usually means libasound.so.2 could not be\n");
            try w.writeAll("   dlopened: check LD_LIBRARY_PATH)\n");
            return;
        }
        defer _ = c.ma_context_uninit(&ctx);

        try w.print("backend: {s}\n\n", .{std.mem.span(c.ma_get_backend_name(ctx.backend))});

        var playback: [*c]c.ma_device_info = undefined;
        var playback_count: c.ma_uint32 = 0;
        var capture: [*c]c.ma_device_info = undefined;
        var capture_count: c.ma_uint32 = 0;
        if (c.ma_context_get_devices(
            &ctx,
            &playback,
            &playback_count,
            &capture,
            &capture_count,
        ) != c.MA_SUCCESS) {
            try w.writeAll("could not enumerate devices\n");
            return;
        }

        try w.print("playback devices ({d}):\n", .{playback_count});
        for (0..playback_count) |i| {
            const d = playback[i];
            const name: [*:0]const u8 = @ptrCast(&d.name);
            try w.print("  {s} {s}\n", .{
                if (d.isDefault != 0) "*" else " ",
                std.mem.span(name),
            });
        }
        try w.writeAll("\n* is the one tuiamp will open.\n");
    }

    pub fn sampleRate(self: *Engine) u32 {
        return c.ma_engine_get_sample_rate(&self.raw);
    }

    pub fn channels(self: *Engine) u32 {
        return c.ma_engine_get_channels(&self.raw);
    }

    /// 0.0 .. 1.0 (linear amplitude).
    pub fn setVolume(self: *Engine, v: f32) void {
        _ = c.ma_engine_set_volume(&self.raw, v);
    }

    pub fn backendName(self: *Engine) []const u8 {
        const device = c.ma_engine_get_device(&self.raw);
        if (device == null) return "none";
        const ctx = device.*.pContext;
        if (ctx == null) return "none";
        return std.mem.span(c.ma_get_backend_name(ctx.*.backend));
    }
};

/// A node that observes the audio passing through it without changing it.
///
/// `MA_NODE_FLAG_PASSTHROUGH` makes miniaudio point the output buffer at the
/// input buffer and still fire the callback, which is exactly what a tap
/// wants: zero copies, and the samples the device is about to play.
///
/// This is an `extern struct` because miniaudio casts the node pointer to
/// `ma_node_base*`, so `base` has to be guaranteed to sit at offset zero.
/// Like every miniaudio node it also registers its own address in the graph,
/// so it must never be copied or moved once initialized.
pub const TapNode = extern struct {
    base: c.ma_node_base,
    tap: *VisTap,
    channels: u32,

    const vtable: c.ma_node_vtable = .{
        .onProcess = onProcess,
        .onGetRequiredInputFrameCount = null,
        .inputBusCount = 1,
        .outputBusCount = 1,
        .flags = c.MA_NODE_FLAG_PASSTHROUGH,
    };

    /// Runs on the audio thread. Must not allocate, lock, or block.
    fn onProcess(
        node: ?*anyopaque,
        frames_in: [*c]const [*c]const f32,
        frame_count_in: [*c]c.ma_uint32,
        frames_out: [*c][*c]f32,
        frame_count_out: [*c]c.ma_uint32,
    ) callconv(.c) void {
        _ = frames_out;
        _ = frame_count_in;
        const self: *TapNode = @ptrCast(@alignCast(node orelse return));

        const n = frame_count_out[0];
        if (n == 0 or self.channels == 0) return;
        const in = frames_in[0] orelse return;

        self.tap.pushInterleaved(in[0 .. n * self.channels], self.channels);
        // A passthrough must leave both frame counts exactly as it found
        // them; miniaudio asserts on it.
    }

    /// Insert between the sounds and the engine endpoint.
    pub fn init(self: *TapNode, engine: *Engine, tap: *VisTap) Error!void {
        const channels = engine.channels();
        self.* = .{ .base = undefined, .tap = tap, .channels = channels };

        var cfg = c.ma_node_config_init();
        cfg.vtable = &vtable;
        cfg.pInputChannels = &[_]c.ma_uint32{channels};
        cfg.pOutputChannels = &[_]c.ma_uint32{channels};

        try check(
            c.ma_node_init(c.ma_engine_get_node_graph(&engine.raw), &cfg, null, &self.base),
            error.NodeInitFailed,
        );
        try check(
            c.ma_node_attach_output_bus(&self.base, 0, c.ma_engine_get_endpoint(&engine.raw), 0),
            error.AttachFailed,
        );
    }

    pub fn deinit(self: *TapNode) void {
        c.ma_node_uninit(&self.base, null);
    }
};

pub const Sound = struct {
    raw: c.ma_sound = undefined,
    initialized: bool = false,

    /// Streams from disk rather than decoding the whole file into memory,
    /// which matters for long FLACs and keeps startup instant.
    pub fn initFile(self: *Sound, engine: *Engine, path: [:0]const u8) Error!void {
        const flags: c.ma_uint32 = c.MA_SOUND_FLAG_STREAM | c.MA_SOUND_FLAG_NO_SPATIALIZATION;
        try check(
            c.ma_sound_init_from_file(&engine.raw, path.ptr, flags, null, null, &self.raw),
            error.SoundInitFailed,
        );
        self.initialized = true;

        // Sounds attach themselves to the endpoint; re-route through the tap
        // so the visualizer sees them.
        _ = c.ma_node_attach_output_bus(&self.raw, 0, engine.sink(), 0);
    }

    pub fn deinit(self: *Sound) void {
        if (!self.initialized) return;
        c.ma_sound_uninit(&self.raw);
        self.initialized = false;
    }

    pub fn start(self: *Sound) Error!void {
        try check(c.ma_sound_start(&self.raw), error.StartFailed);
    }

    pub fn stop(self: *Sound) void {
        _ = c.ma_sound_stop(&self.raw);
    }

    pub fn isPlaying(self: *Sound) bool {
        return c.ma_sound_is_playing(&self.raw) == c.MA_TRUE;
    }

    pub fn atEnd(self: *Sound) bool {
        return c.ma_sound_at_end(&self.raw) == c.MA_TRUE;
    }

    pub fn seekToFrame(self: *Sound, frame: u64) Error!void {
        try check(c.ma_sound_seek_to_pcm_frame(&self.raw, frame), error.SeekFailed);
    }

    pub fn cursorFrames(self: *Sound) u64 {
        var frames: c.ma_uint64 = 0;
        _ = c.ma_sound_get_cursor_in_pcm_frames(&self.raw, &frames);
        return frames;
    }

    /// Returns 0 when the length is not knowable (e.g. a stream).
    pub fn lengthFrames(self: *Sound) u64 {
        var frames: c.ma_uint64 = 0;
        _ = c.ma_sound_get_length_in_pcm_frames(&self.raw, &frames);
        return frames;
    }

    pub fn cursorSeconds(self: *Sound) f32 {
        var secs: f32 = 0;
        _ = c.ma_sound_get_cursor_in_seconds(&self.raw, &secs);
        return secs;
    }

    pub fn lengthSeconds(self: *Sound) f32 {
        var secs: f32 = 0;
        _ = c.ma_sound_get_length_in_seconds(&self.raw, &secs);
        return secs;
    }

    /// 0.0 .. 1.0, applied per-sound so the engine volume stays the master.
    pub fn setVolume(self: *Sound, v: f32) void {
        c.ma_sound_set_volume(&self.raw, v);
    }

    /// -1.0 fully left .. +1.0 fully right.
    pub fn setPan(self: *Sound, pan: f32) void {
        c.ma_sound_set_pan(&self.raw, pan);
    }

    /// The source file's own format, which is what Winamp's kHz and
    /// stereo/mono readouts show — not the device format it resamples to.
    pub fn sourceFormat(self: *Sound) Format {
        const ds = c.ma_sound_get_data_source(&self.raw);
        if (ds == null) return .{ .channels = 0, .sample_rate = 0 };
        var fmt: c.ma_format = 0;
        var channels: c.ma_uint32 = 0;
        var rate: c.ma_uint32 = 0;
        if (c.ma_data_source_get_data_format(ds, &fmt, &channels, &rate, null, 0) != c.MA_SUCCESS) {
            return .{ .channels = 0, .sample_rate = 0 };
        }
        return .{ .channels = channels, .sample_rate = rate };
    }
};

pub const Format = struct {
    channels: u32,
    sample_rate: u32,
};

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A small stereo WAV of full-scale sine, written to `dir`.
fn writeToneWav(io: std.Io, dir: std.Io.Dir, name: []const u8, frames: u32, rate: u32) !void {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const data_len: u32 = frames * 2 * 2; // stereo, 16-bit
    var u32buf: [4]u8 = undefined;
    var u16buf: [2]u8 = undefined;

    try out.appendSlice(gpa, "RIFF");
    std.mem.writeInt(u32, &u32buf, 36 + data_len, .little);
    try out.appendSlice(gpa, &u32buf);
    try out.appendSlice(gpa, "WAVEfmt ");
    std.mem.writeInt(u32, &u32buf, 16, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, 1, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, 2, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u32, &u32buf, rate, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u32, &u32buf, rate * 4, .little);
    try out.appendSlice(gpa, &u32buf);
    std.mem.writeInt(u16, &u16buf, 4, .little);
    try out.appendSlice(gpa, &u16buf);
    std.mem.writeInt(u16, &u16buf, 16, .little);
    try out.appendSlice(gpa, &u16buf);
    try out.appendSlice(gpa, "data");
    std.mem.writeInt(u32, &u32buf, data_len, .little);
    try out.appendSlice(gpa, &u32buf);

    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        const v: i16 = @intFromFloat(@sin(2.0 * std.math.pi * 440.0 * t) * 30000);
        std.mem.writeInt(i16, &u16buf, v, .little);
        try out.appendSlice(gpa, &u16buf);
        try out.appendSlice(gpa, &u16buf);
    }

    try dir.writeFile(io, .{ .sub_path = name, .data = out.items });
}

fn rms(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var sum: f64 = 0;
    for (samples) |v| sum += @as(f64, v) * @as(f64, v);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(samples.len))));
}

/// Build the real chain — sound into EQ into tap into endpoint — and read
/// what a sound card would have been handed.
const Capture = struct {
    engine: *Engine,
    tap: *VisTap,
    eq_shared: *eq_mod.Node.Shared,
    sound: *Sound,
    tmp: testing.TmpDir,

    const rate: u32 = 48000;

    fn init() !Capture {
        const gpa = testing.allocator;
        const io = testing.io;

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeToneWav(io, tmp.dir, "tone.wav", rate, rate);
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        const path = try std.fs.path.joinZ(gpa, &.{ root, "tone.wav" });
        defer gpa.free(path);

        const engine = try gpa.create(Engine);
        errdefer gpa.destroy(engine);
        engine.* = .{};
        try engine.initCapture(2, rate);

        const tap = try gpa.create(VisTap);
        errdefer gpa.destroy(tap);
        tap.* = .{};
        try engine.installTap(tap);

        const eq_shared = try gpa.create(eq_mod.Node.Shared);
        errdefer gpa.destroy(eq_shared);
        eq_shared.* = .{};
        try engine.installEq(eq_shared);

        const sound = try gpa.create(Sound);
        errdefer gpa.destroy(sound);
        sound.* = .{};
        try sound.initFile(engine, path);
        try sound.start();

        return .{
            .engine = engine,
            .tap = tap,
            .eq_shared = eq_shared,
            .sound = sound,
            .tmp = tmp,
        };
    }

    fn deinit(cap: *Capture) void {
        const gpa = testing.allocator;
        cap.sound.deinit();
        gpa.destroy(cap.sound);
        cap.engine.deinit();
        gpa.destroy(cap.engine);
        gpa.destroy(cap.tap);
        gpa.destroy(cap.eq_shared);
        cap.tmp.cleanup();
    }

    /// Read `frames` and return the RMS of what came out.
    fn level(cap: *Capture, frames: u32) !f32 {
        const gpa = testing.allocator;
        const buf = try gpa.alloc(f32, frames * 2);
        defer gpa.free(buf);
        @memset(buf, 0);
        const got = cap.engine.read(buf, frames);
        return rms(buf[0 .. got * 2]);
    }
};

test "audio actually reaches the device output through the whole chain" {
    var cap = try Capture.init();
    defer cap.deinit();

    cap.engine.setVolume(1.0);
    // Discard the first block: the graph starts cold.
    _ = try cap.level(2048);
    const level = try cap.level(8192);

    // A full-scale sine at unity gain must come out loud. This is the check
    // the analyzer could never make, because it taps upstream of here.
    try testing.expect(level > 0.3);
}

test "master volume scales what the device receives" {
    var cap = try Capture.init();
    defer cap.deinit();

    cap.engine.setVolume(1.0);
    _ = try cap.level(2048);
    const full = try cap.level(8192);

    cap.engine.setVolume(0.25);
    _ = try cap.level(4096);
    const quarter = try cap.level(8192);

    cap.engine.setVolume(0);
    _ = try cap.level(4096);
    const muted = try cap.level(8192);

    try testing.expect(full > 0.3);
    try testing.expectApproxEqAbs(full * 0.25, quarter, full * 0.05);
    try testing.expect(muted < 0.001);
}

test "the visualizer tap sees the same audio the output does" {
    var cap = try Capture.init();
    defer cap.deinit();

    cap.engine.setVolume(1.0);
    _ = try cap.level(2048);
    _ = try cap.level(4096);

    var window: [1024]f32 = undefined;
    try testing.expect(cap.tap.readLatest(&window));
    try testing.expect(rms(&window) > 0.3);
}

test "a disabled equalizer does not attenuate the signal" {
    var cap = try Capture.init();
    defer cap.deinit();

    cap.engine.setVolume(1.0);
    _ = try cap.level(2048);
    const before = try cap.level(8192);

    // Switching the EQ on while flat must also leave the level alone.
    cap.eq_shared.publish(.{ .enabled = true });
    _ = try cap.level(4096);
    const flat_on = try cap.level(8192);

    try testing.expect(before > 0.3);
    try testing.expectApproxEqAbs(before, flat_on, before * 0.1);
}
