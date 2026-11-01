//! End-to-end tests that launch the real binary.
//!
//! Everything else in this repo tests a function. These tests test the
//! program: they allocate a pseudo-terminal, exec `tuiamp` on it, type at
//! it, and assert on what it actually draws and on how it exits.
//!
//! That gap is why these exist. During development a build was shipped that
//! started, advanced its clock, and animated its analyzer while producing
//! no sound, and another that was silently the wrong architecture. Both
//! passed every unit test, because the unit tests never ran the program.
//!
//! The audio device is the null backend, so these need no sound card and
//! run unchanged on a CI container.
//!
//! `Term` replays the output into a cell grid, because the renderer emits
//! only the cells that changed: a playlist row that reads "30. Scroll 30"
//! after a scroll is assembled from whatever differed from the frame before,
//! so it need never appear as contiguous bytes in the stream. Anything about
//! layout or about a view staying put has to be asked of the screen.

const std = @import("std");
const build_options = @import("build_options");

// The build injects a build-root-relative path plus the root itself; exec
// wants one absolute, sentinel-terminated string. Note that `++` on a slice
// yields a slice, so this has to build a real array to point into.
const exe_path_z: [:0]const u8 = blk: {
    const rel = build_options.tuiamp_exe;
    const full = if (rel.len > 0 and rel[0] == '/')
        rel
    else
        build_options.build_root ++ "/" ++ rel;

    var arr: [full.len + 1]u8 = undefined;
    @memcpy(arr[0..full.len], full);
    arr[full.len] = 0;
    const frozen = arr;
    break :blk frozen[0..full.len :0];
};
const exe_path: [*:0]const u8 = exe_path_z.ptr;

// libc, which this project already links. Zig's std does not wrap the
// pseudo-terminal calls, and they are the whole point here.
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

const linux = std.os.linux;
const posix = std.posix;

/// A child process attached to its own terminal.
const Session = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    reaped: bool = false,

    const cols: u16 = 92;
    const rows: u16 = 34;

    fn start(argv: []const [*:0]const u8) !Session {
        const master = posix_openpt(@as(c_int, 0o2) | 0o400); // O_RDWR | O_NOCTTY
        if (master < 0) return error.OpenPtFailed;
        errdefer _ = linux.close(master);

        if (grantpt(master) != 0) return error.GrantPtFailed;
        if (unlockpt(master) != 0) return error.UnlockPtFailed;
        const slave_name = ptsname(master) orelse return error.PtsNameFailed;

        // Give the child a terminal of a known size, so layout assertions
        // are not at the mercy of whatever ran the test.
        var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));

        const pid_raw = linux.fork();
        if (@as(isize, @bitCast(pid_raw)) < 0) return error.ForkFailed;
        const pid: posix.pid_t = @intCast(pid_raw);

        if (pid == 0) {
            // Child: become a session leader so the slave becomes our
            // controlling terminal, then replace stdio with it.
            _ = linux.setsid();
            const slave = linux.openat(linux.AT.FDCWD, slave_name, .{ .ACCMODE = .RDWR }, 0);
            const slave_signed: isize = @bitCast(slave);
            if (slave_signed < 0) linux.exit(90);
            const slave_fd: posix.fd_t = @intCast(slave_signed);
            _ = linux.dup2(slave_fd, 0);
            _ = linux.dup2(slave_fd, 1);
            _ = linux.dup2(slave_fd, 2);
            if (slave_fd > 2) _ = linux.close(slave_fd);
            _ = linux.close(master);

            var argv_z: [16:null]?[*:0]const u8 = @splat(null);
            for (argv, 0..) |a, i| argv_z[i] = a;
            const envp: [1:null]?[*:0]const u8 = @splat(null);
            _ = linux.execve(argv[0], &argv_z, &envp);
            linux.exit(127);
        }

        return .{ .master = master, .pid = pid };
    }

    fn send(s: *Session, bytes: []const u8) void {
        _ = linux.write(s.master, bytes.ptr, bytes.len);
    }

    /// Drain output for `ms`, appending to `out`.
    fn pump(s: *Session, out: *std.ArrayList(u8), gpa: std.mem.Allocator, ms: u64) !void {
        var waited: u64 = 0;
        var buf: [8192]u8 = undefined;
        while (waited < ms) : (waited += 20) {
            var fds = [_]posix.pollfd{.{ .fd = s.master, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, 20) catch 0;
            if (ready > 0) {
                const n = linux.read(s.master, &buf, buf.len);
                const got: isize = @bitCast(n);
                if (got <= 0) return; // the child closed its end
                try out.appendSlice(gpa, buf[0..@intCast(got)]);
            }
        }
    }

    /// Exit code, or null if it had to be killed.
    fn wait(s: *Session, timeout_ms: u64) ?u8 {
        var waited: u64 = 0;
        var status: u32 = 0;
        while (waited < timeout_ms) : (waited += 20) {
            const rc = linux.waitpid(s.pid, &status, 1); // WNOHANG
            if (@as(isize, @bitCast(rc)) > 0) {
                s.reaped = true;
                if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
                return null; // killed by a signal
            }
            std.Thread.yield() catch {};
            var ts: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
        return null;
    }

    fn deinit(s: *Session) void {
        if (!s.reaped) {
            posix.kill(s.pid, .KILL) catch {};
            var status: u32 = 0;
            _ = linux.waitpid(s.pid, &status, 0);
        }
        _ = linux.close(s.master);
    }
};

const testing = std.testing;

/// A playable file, so the player has something to open.
///
/// Long enough that it is still playing for the whole of any measurement
/// window below. A short tone makes these tests measure a track that has
/// already ended, which passes or fails depending on how fast the machine
/// is — exactly the kind of flake CI should never have to diagnose.
const tone_seconds: u32 = 12;

fn writeTone(dir: std.Io.Dir, name: []const u8) !void {
    return writeToneSeconds(dir, name, tone_seconds);
}

fn writeToneSeconds(dir: std.Io.Dir, name: []const u8, seconds: u32) !void {
    const gpa = testing.allocator;
    const rate: u32 = 48000;
    const frames: u32 = rate * seconds;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const data_len: u32 = frames * 4;
    var u32b: [4]u8 = undefined;
    var u16b: [2]u8 = undefined;
    try out.appendSlice(gpa, "RIFF");
    std.mem.writeInt(u32, &u32b, 36 + data_len, .little);
    try out.appendSlice(gpa, &u32b);
    try out.appendSlice(gpa, "WAVEfmt ");
    std.mem.writeInt(u32, &u32b, 16, .little);
    try out.appendSlice(gpa, &u32b);
    std.mem.writeInt(u16, &u16b, 1, .little);
    try out.appendSlice(gpa, &u16b);
    std.mem.writeInt(u16, &u16b, 2, .little);
    try out.appendSlice(gpa, &u16b);
    std.mem.writeInt(u32, &u32b, rate, .little);
    try out.appendSlice(gpa, &u32b);
    std.mem.writeInt(u32, &u32b, rate * 4, .little);
    try out.appendSlice(gpa, &u32b);
    std.mem.writeInt(u16, &u16b, 4, .little);
    try out.appendSlice(gpa, &u16b);
    std.mem.writeInt(u16, &u16b, 16, .little);
    try out.appendSlice(gpa, &u16b);
    try out.appendSlice(gpa, "data");
    std.mem.writeInt(u32, &u32b, data_len, .little);
    try out.appendSlice(gpa, &u32b);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
        const v: i16 = @intFromFloat(@sin(2.0 * std.math.pi * 440.0 * t) * 20000);
        std.mem.writeInt(i16, &u16b, v, .little);
        try out.appendSlice(gpa, &u16b);
        try out.appendSlice(gpa, &u16b);
    }
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = out.items });
}

/// Replays rendered output into a cell grid.
///
/// Only what the renderer actually emits is handled: absolute cursor
/// positioning, erase-display, and printable text. Everything else — the
/// synchronised-update marks, the SGR colours, the private modes — is
/// skipped, which is right, because none of it moves a glyph. Wide glyphs
/// occupy one cell here rather than two; nothing asserted on depends on the
/// difference.
const Term = struct {
    cells: [Session.rows][Session.cols]u21,
    x: u16 = 0,
    y: u16 = 0,

    fn init() Term {
        return .{ .cells = @splat(@splat(' ')) };
    }

    fn feed(t: *Term, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            if (c == 0x1b) {
                i += 1;
                if (i < bytes.len and bytes[i] == '[') {
                    i += 1;
                    const start = i;
                    // Parameter and intermediate bytes, then one final byte.
                    while (i < bytes.len and bytes[i] < 0x40) i += 1;
                    if (i >= bytes.len) return;
                    t.csi(bytes[start..i], bytes[i]);
                    i += 1;
                } else if (i < bytes.len) {
                    i += 1; // a two-byte escape we do not care about
                }
                continue;
            }
            if (c == '\r') {
                t.x = 0;
                i += 1;
                continue;
            }
            if (c == '\n') {
                t.y +|= 1;
                t.x = 0;
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(c) catch {
                i += 1;
                continue;
            };
            if (i + len > bytes.len) return;
            const cp = std.unicode.utf8Decode(bytes[i..][0..len]) catch ' ';
            if (cp >= ' ' and t.y < Session.rows and t.x < Session.cols) {
                t.cells[t.y][t.x] = cp;
            }
            t.x +|= 1;
            i += len;
        }
    }

    fn csi(t: *Term, params: []const u8, final: u8) void {
        switch (final) {
            'H', 'f' => {
                var it = std.mem.splitScalar(u8, params, ';');
                const row = std.fmt.parseInt(u16, it.next() orelse "1", 10) catch 1;
                const col = std.fmt.parseInt(u16, it.next() orelse "1", 10) catch 1;
                t.y = row -| 1;
                t.x = col -| 1;
            },
            'J' => t.cells = @splat(@splat(' ')),
            else => {},
        }
    }

    fn cell(t: *const Term, x: u16, y: u16) u21 {
        if (y >= Session.rows or x >= Session.cols) return ' ';
        return t.cells[y][x];
    }

    /// The first row whose text contains `needle`, or null.
    fn rowContaining(t: *const Term, needle: []const u8) ?u16 {
        var buf: [Session.cols * 4]u8 = undefined;
        var y: u16 = 0;
        while (y < Session.rows) : (y += 1) {
            if (std.mem.indexOf(u8, t.rowText(y, &buf), needle) != null) return y;
        }
        return null;
    }

    fn contains(t: *const Term, needle: []const u8) bool {
        return t.rowContaining(needle) != null;
    }

    /// Does any row from `from` to `to` inclusive contain `needle`? Used to
    /// ask about one window: a track title is drawn in the main window's
    /// marquee as well as in the playlist, so "is it on screen" is too
    /// blunt a question to tell where the playlist is scrolled to.
    fn containsBetween(t: *const Term, from: u16, to: u16, needle: []const u8) bool {
        var buf: [Session.cols * 4]u8 = undefined;
        var y: u16 = from;
        while (y <= to and y < Session.rows) : (y += 1) {
            if (std.mem.indexOf(u8, t.rowText(y, &buf), needle) != null) return true;
        }
        return false;
    }

    fn rowText(t: *const Term, y: u16, buf: []u8) []const u8 {
        var n: usize = 0;
        for (t.cells[y]) |cp| {
            n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
        }
        return buf[0..n];
    }

    /// The rightmost non-blank column of the row whose text contains
    /// `title`, which for a window titlebar is where its frame sits — and so
    /// where the scrollbar is drawn.
    fn frameRight(t: *const Term, title: []const u8) ?u16 {
        const y = t.rowContaining(title) orelse return null;
        var x: u16 = Session.cols;
        while (x > 0) {
            x -= 1;
            if (t.cell(x, y) != ' ') return x;
        }
        return null;
    }
};

/// Run the player on a throwaway track and return everything it drew.
fn runPlayer(gpa: std.mem.Allocator, keys: []const u8, settle_ms: u64) !struct {
    output: []u8,
    exit: ?u8,
} {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTone(tmp.dir, "tone.wav");

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const track = try std.fs.path.joinZ(gpa, &.{ root, "tone.wav" });
    defer gpa.free(track);

    var session = try Session.start(&.{
        exe_path,
        "--null-audio",
        "--no-config",
        "--volume",
        "50",
        track.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try session.pump(&out, gpa, settle_ms);
    if (keys.len > 0) {
        session.send(keys);
        try session.pump(&out, gpa, 600);
    }
    session.send("q");
    try session.pump(&out, gpa, 600);

    return .{ .output = try out.toOwnedSlice(gpa), .exit = session.wait(3000) };
}

test "the player starts, draws its window, and exits cleanly on q" {
    const gpa = testing.allocator;
    const r = try runPlayer(gpa, "", 2500);
    defer gpa.free(r.output);

    // It took the terminal.
    try testing.expect(std.mem.indexOf(u8, r.output, "\x1b[?1049h") != null);
    // It drew the main window: title, frame, and the file it is playing.
    try testing.expect(std.mem.indexOf(u8, r.output, "tuiamp") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "tone") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\u{250c}") != null); // ┌
    // And the transport row.
    try testing.expect(std.mem.indexOf(u8, r.output, "shuffle") != null);

    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "the terminal is handed back on exit" {
    const gpa = testing.allocator;
    const r = try runPlayer(gpa, "", 2000);
    defer gpa.free(r.output);

    // Whatever else happened, the last thing it does must be to undo every
    // mode it set. Leaving a terminal in raw mode with no cursor is the
    // worst thing a TUI can do to someone.
    const tail = r.output[r.output.len -| 128..];
    try testing.expect(std.mem.indexOf(u8, tail, "\x1b[?1049l") != null); // main screen
    try testing.expect(std.mem.indexOf(u8, tail, "\x1b[?25h") != null); // cursor back
    try testing.expect(std.mem.indexOf(u8, tail, "\x1b[?1006l") != null); // mouse off
}

test "keys reach the windows: the equalizer opens and its presets cycle" {
    const gpa = testing.allocator;
    // alt+g opens the equalizer, tab focuses it, p steps the preset.
    const r = try runPlayer(gpa, "\x1bg\tp", 2500);
    defer gpa.free(r.output);

    try testing.expect(std.mem.indexOf(u8, r.output, "Equalizer") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "preset:") != null);
    // The band scale is drawn, so the window rendered rather than merely
    // being announced.
    try testing.expect(std.mem.indexOf(u8, r.output, "16k") != null);
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

/// Two phases: send `keys`, read back where the equalizer was drawn, then
/// send whatever `then` makes of that. Mouse reports carry absolute screen
/// cells, so they cannot be written down until the window has a position.
fn runPlayerThenMouse(
    gpa: std.mem.Allocator,
    keys: []const u8,
    then: *const fn (eq_row: u16, buf: []u8) []const u8,
) !struct {
    output: []u8,
    exit: ?u8,
} {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTone(tmp.dir, "tone.wav");

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const track = try std.fs.path.joinZ(gpa, &.{ root, "tone.wav" });
    defer gpa.free(track);

    var session = try Session.start(&.{
        exe_path,
        "--null-audio",
        "--no-config",
        "--volume",
        "50",
        track.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try session.pump(&out, gpa, 2500);
    session.send(keys);
    try session.pump(&out, gpa, 600);

    var term: Term = .init();
    term.feed(out.items);
    const eq_row = term.rowContaining("Equalizer") orelse return error.NoEqualizerDrawn;

    var buf: [128]u8 = undefined;
    session.send(then(eq_row, &buf));
    try session.pump(&out, gpa, 600);

    session.send("q");
    try session.pump(&out, gpa, 600);

    return .{ .output = try out.toOwnedSlice(gpa), .exit = session.wait(3000) };
}

/// Press on the zero tick of the first band, drag two rows up, release.
/// Band 0's slider is column 14 of an 80-wide window centred in these 92
/// columns; the sliders begin three rows under the titlebar, and the tick is
/// four rows below that. SGR reports are 1-based.
fn pressAndDragBandUp(eq_row: u16, buf: []u8) []const u8 {
    const x = 6 + 14 + 1;
    const tick = eq_row + 3 + 4 + 1;
    return std.fmt.bufPrint(
        buf,
        "\x1b[<0;{d};{d}M\x1b[<32;{d};{d}M\x1b[<0;{d};{d}m",
        .{ x, tick, x, tick - 2, x, tick - 2 },
    ) catch unreachable;
}

test "dragging a band moves it by the wheel's step, not the track's rows" {
    const gpa = testing.allocator;
    // The band starts flat, so the press lands on its own thumb and takes
    // hold of it rather than jumping. Two rows of travel is then two fine
    // steps: +1.0 dB, which is not a value any of the nine rows can name.
    const r = try runPlayerThenMouse(gpa, "\x1bg", pressAndDragBandUp);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);

    try testing.expect(term.contains("60 Hz: +1.0 dB"));
    // An absolute drag would have read the row under the pointer instead,
    // which two rows above centre is +6.
    try testing.expect(!term.contains("60 Hz: +6.0 dB"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "shift+arrow reaches a gain the slider's own rows cannot" {
    const gpa = testing.allocator;
    // alt+g opens the equalizer and tab focuses it. The cursor starts on the
    // preamp, so two shift+ups are two fine steps: +1.0 dB, which is neither
    // a multiple of the 1.5 dB keypress nor one of the nine 3 dB rows a
    // click can land on. Reading it back off the titlebar proves the whole
    // chain — key decoding, the fine step, the gain, the readout — rather
    // than any one end of it.
    const shift_up = "\x1b[1;2A";
    const r = try runPlayer(gpa, "\x1bg\t" ++ shift_up ++ shift_up, 2500);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);

    try testing.expect(term.contains("preamp: +1.0 dB"));
    // Had the shift been dropped on the way in, the same two presses would
    // have landed on +3.0 instead.
    try testing.expect(!term.contains("preamp: +3.0 dB"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "the analyzer renders real audio, not just its baseline" {
    const gpa = testing.allocator;
    const r = try runPlayer(gpa, "", 1200);
    defer gpa.free(r.output);

    // The analyzer's bar glyphs are U+2581..U+2588. At rest it draws only
    // the U+2581 baseline, so anything taller is a bar that was driven by
    // PCM arriving through the tap. Nothing else on screen here draws them:
    // the horizontal meters use U+258F..U+2589, and the equalizer — whose
    // sliders now fill in these same eighths — is closed until alt+g opens
    // it, which this test does not.
    const mid_bars = [_][]const u8{ "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}" };
    var saw_bar = false;
    for (mid_bars) |g| {
        if (std.mem.indexOf(u8, r.output, g) != null) saw_bar = true;
    }
    try testing.expect(saw_bar);
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

// There is deliberately no test here comparing how much the player draws
// while playing against while stopped. Under --null-audio miniaudio's null
// device does not pace itself to the sample rate — it consumes frames as
// fast as the decoder produces them, so a generated WAV is exhausted within
// the first second no matter how long it is, and any rate comparison
// measures decode speed rather than playback.
//
// That the device really pulls audio through the whole chain is proved
// properly in src/audio/engine.zig, where the no-device engine's output is
// read back and its level asserted.

/// A playlist long enough to need scrolling. The tones are a fraction of a
/// second because nothing here measures playback, only what gets drawn.
fn runLongPlaylist(gpa: std.mem.Allocator, keys: []const u8) !struct {
    output: []u8,
    exit: ?u8,
} {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var name_buf: [32]u8 = undefined;
    for (1..41) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "Scroll {d:0>2}.wav", .{i});
        try writeToneSeconds(tmp.dir, name, 1);
    }

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_path);
    const root = try gpa.dupeZ(u8, root_path);
    defer gpa.free(root);

    var session = try Session.start(&.{
        exe_path,
        "--null-audio",
        "--no-config",
        "--volume",
        "50",
        root.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try session.pump(&out, gpa, 1500);
    if (keys.len > 0) {
        session.send(keys);
        // Long enough that a view which snaps back to the cursor has had
        // many frames in which to do it.
        try session.pump(&out, gpa, 1200);
    }
    session.send("q");
    try session.pump(&out, gpa, 600);

    return .{ .output = try out.toOwnedSlice(gpa), .exit = session.wait(3000) };
}

/// A library of three album folders, so folder mode has something to group.
fn runFolderTree(gpa: std.mem.Allocator, keys: []const u8) !struct {
    output: []u8,
    exit: ?u8,
} {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const albums = [_][]const u8{ "Bowie - Low", "Eno - Green World", "Talk Talk - Eden" };
    var path_buf: [64]u8 = undefined;
    for (albums, 1..) |album, n| {
        try tmp.dir.createDirPath(io, album);
        // A different number of tracks each, so the counts on the headers
        // cannot all be right by accident.
        for (1..n + 1) |i| {
            const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>2} Track.wav", .{ album, i });
            try writeToneSeconds(tmp.dir, sub, 1);
        }
    }

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_path);
    const root = try gpa.dupeZ(u8, root_path);
    defer gpa.free(root);

    var session = try Session.start(&.{
        exe_path,
        "--null-audio",
        "--no-config",
        "--volume",
        "50",
        root.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try session.pump(&out, gpa, 1500);
    if (keys.len > 0) {
        session.send(keys);
        try session.pump(&out, gpa, 900);
    }
    session.send("q");
    try session.pump(&out, gpa, 600);

    return .{ .output = try out.toOwnedSlice(gpa), .exit = session.wait(3000) };
}

test "f groups the playlist by folder, and folds it" {
    const gpa = testing.allocator;

    // Flat to begin with: every track is a row and no folder is named.
    {
        const r = try runFolderTree(gpa, "");
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);
        try testing.expect(term.contains("6 tracks"));
        try testing.expect(!term.contains("Bowie - Low"));
        try testing.expectEqual(@as(?u8, 0), r.exit);
    }

    // `f` groups it. Entering the mode folds everything, which is the point
    // of it: three rows stand for six tracks.
    {
        const r = try runFolderTree(gpa, "f");
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);

        try testing.expect(term.contains("3 folders, 6 tracks"));
        try testing.expect(term.contains("Bowie - Low"));
        try testing.expect(term.contains("Talk Talk - Eden"));
        // Everything is folded, so no track has a row at all. Scoped to the
        // playlist window, because the main window is displaying the title
        // of the playing track and that says "Track" too.
        const pl = term.rowContaining(" Playlist ").?;
        try testing.expect(!term.containsBetween(pl, pl + 14, "Track.wav"));
        try testing.expect(!term.containsBetween(pl, pl + 14, "01 Track"));
        try testing.expect(!term.containsBetween(pl, pl + 14, "03 Track"));
        try testing.expectEqual(@as(?u8, 0), r.exit);
    }

    // And `f` again puts the flat playlist back.
    {
        const r = try runFolderTree(gpa, "ff");
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);
        try testing.expect(term.contains("6 tracks"));
        try testing.expect(!term.contains("3 folders"));
        try testing.expectEqual(@as(?u8, 0), r.exit);
    }
}

test "a folded folder opens on the keyboard and shows its tracks" {
    const gpa = testing.allocator;
    // The scan sorts by path, so "Talk Talk - Eden" is the last of the three
    // folders and holds three tracks. f groups and folds, tab focuses the
    // playlist, end goes to the last row, right opens what is under it.
    const key_right = "\x1b[C";
    const r = try runFolderTree(gpa, "f\t" ++ key_end ++ key_right);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);
    const pl = term.rowContaining(" Playlist ").?;

    try testing.expect(term.containsBetween(pl, pl + 14, "Talk Talk - Eden"));
    // Its tracks are numbered within the folder, so the third one is 3 even
    // though it is the sixth entry in the playlist.
    try testing.expect(term.containsBetween(pl, pl + 14, "3. 03 Track"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "left folds a folder back up" {
    const gpa = testing.allocator;
    // Open the last folder, then fold it again: the header survives and its
    // tracks go back to having no rows.
    const key_left = "\x1b[D";
    const key_right = "\x1b[C";
    const r = try runFolderTree(gpa, "f\t" ++ key_end ++ key_right ++ key_left);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);
    const pl = term.rowContaining(" Playlist ").?;

    try testing.expect(term.containsBetween(pl, pl + 14, "Talk Talk - Eden"));
    try testing.expect(!term.containsBetween(pl, pl + 14, "03 Track"));
    try testing.expect(term.contains("3 folders, 6 tracks"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

/// Eight notches of the wheel over the playlist, in SGR mouse reporting.
const wheel_down_8 = "\x1b[<65;20;22M" ** 8;
/// Enough to run it past the end, so the view lands on the last page.
const wheel_down_40 = "\x1b[<65;20;22M" ** 40;

test "a scrolled playlist stays where it was put" {
    const gpa = testing.allocator;
    const r = try runLongPlaylist(gpa, wheel_down_8);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);

    // The view used to be recentred on the cursor every single frame, so a
    // wheel scroll was undone before it could be seen and the playlist sat
    // immovably at the top unless the cursor itself had moved.
    const top = term.rowContaining(" Playlist ") orelse return error.NoPlaylistWindow;
    const bottom = term.rowContaining("40 tracks").?;
    try testing.expect(term.containsBetween(top, bottom, "Scroll 30"));
    try testing.expect(!term.containsBetween(top, bottom, "Scroll 02"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "the scrollbar thumb sits where the view is" {
    const gpa = testing.allocator;

    // Unscrolled: the thumb is at the top of the trough, and the rows below
    // it are plain border.
    {
        const r = try runLongPlaylist(gpa, "");
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);

        const bar_x = term.frameRight(" Playlist ") orelse return error.NoPlaylistWindow;
        const title_y = term.rowContaining(" Playlist ").?;
        const last_y = term.rowContaining("40 tracks").? - 1;
        try testing.expectEqual(@as(u21, '\u{2588}'), term.cell(bar_x, title_y + 1)); // █
        try testing.expectEqual(@as(u21, '\u{2502}'), term.cell(bar_x, last_y)); // │
    }

    // Scrolled to the end: the same thumb, at the other end of the trough.
    {
        const r = try runLongPlaylist(gpa, wheel_down_40);
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);

        const bar_x = term.frameRight(" Playlist ") orelse return error.NoPlaylistWindow;
        const title_y = term.rowContaining(" Playlist ").?;
        const last_y = term.rowContaining("40 tracks").? - 1;
        try testing.expect(term.containsBetween(title_y, last_y, "Scroll 40"));
        try testing.expectEqual(@as(u21, '\u{2502}'), term.cell(bar_x, title_y + 1));
        try testing.expectEqual(@as(u21, '\u{2588}'), term.cell(bar_x, last_y));
    }
}

/// Like `runPlayer`, but the screen is captured before the quit key is sent,
/// so a test can assert on a dialog that is still open. The teardown sends
/// escape first, because a modal dialog deliberately swallows `q` — a stray
/// keypress while picking a theme should not close the player.
fn runPlayerModal(gpa: std.mem.Allocator, theme: [*:0]const u8, keys: []const u8) !struct {
    output: []u8,
    exit: ?u8,
} {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTone(tmp.dir, "tone.wav");

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const track = try std.fs.path.joinZ(gpa, &.{ root, "tone.wav" });
    defer gpa.free(track);

    var session = try Session.start(&.{
        exe_path,
        "--null-audio",
        "--no-config",
        "--volume",
        "50",
        "--theme",
        theme,
        track.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try session.pump(&out, gpa, 2000);
    session.send(keys);
    try session.pump(&out, gpa, 600);

    // Teardown goes to a buffer the caller never sees, so the screen it
    // asserts on is the one the keys produced.
    var teardown: std.ArrayList(u8) = .empty;
    defer teardown.deinit(gpa);
    session.send("\x1b");
    try session.pump(&teardown, gpa, 300);
    session.send("q");
    try session.pump(&teardown, gpa, 600);

    return .{ .output = try out.toOwnedSlice(gpa), .exit = session.wait(3000) };
}

/// Ctrl+P, as a terminal sends it.
const ctrl_p = "\x10";
/// `end`, which selects the last theme in the list whatever the list is.
const key_end = "\x1b[F";

test "ctrl+p opens the settings dialog and lists the themes" {
    const gpa = testing.allocator;
    const r = try runPlayerModal(gpa, "classic", ctrl_p);
    defer gpa.free(r.output);

    var term: Term = .init();
    term.feed(r.output);

    try testing.expect(term.contains(" settings "));
    try testing.expect(term.contains("THEME"));
    // The built-ins are offered. There is no theme directory under
    // --no-config, so these are all there is to list.
    try testing.expect(term.contains("classic"));
    try testing.expect(term.contains("ascii"));
    try testing.expect(term.contains("paper"));
    // A modal dialog has to say how to leave.
    try testing.expect(term.contains("esc cancel"));
    try testing.expectEqual(@as(?u8, 0), r.exit);
}

test "picking a theme repaints the player, and escape puts it back" {
    const gpa = testing.allocator;

    // The glyph set is the visible half of a theme, so a player started in
    // `ascii` draws its corners as plusses, and any other theme draws them
    // as box-drawing. Nothing else in the program does that, which makes it
    // the honest test of whether a preview was really applied rather than
    // merely drawn in the list.
    //
    // Starting in `ascii` and pressing `end` keeps this independent of how
    // many themes ship and where `ascii` sorts among them: `end` is the
    // last entry, whatever it is, and every theme but `ascii` is
    // box-drawing.
    {
        const r = try runPlayerModal(gpa, "ascii", ctrl_p ++ key_end);
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);
        try testing.expect(term.contains("\u{250c}\u{2500} tuiamp"));
        try testing.expect(!term.contains("+- tuiamp"));
        try testing.expectEqual(@as(?u8, 0), r.exit);
    }

    // And escape is a real cancel: the player comes back as it was, not as
    // whatever the cursor happened to be resting on.
    {
        const r = try runPlayerModal(gpa, "ascii", ctrl_p ++ key_end ++ "\x1b");
        defer gpa.free(r.output);
        var term: Term = .init();
        term.feed(r.output);
        try testing.expect(term.contains("+- tuiamp"));
        try testing.expect(!term.contains(" settings "));
        try testing.expectEqual(@as(?u8, 0), r.exit);
    }
}

test "usage and device listing exit with the right codes" {
    const gpa = testing.allocator;

    // --help succeeds and describes itself.
    {
        var s = try Session.start(&.{ exe_path, "--help" });
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try s.pump(&out, gpa, 800);
        try testing.expectEqual(@as(?u8, 0), s.wait(3000));
        try testing.expect(std.mem.indexOf(u8, out.items, "usage:") != null);
    }

    // No arguments is a usage error.
    {
        var s = try Session.start(&.{exe_path});
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try s.pump(&out, gpa, 800);
        try testing.expectEqual(@as(?u8, 2), s.wait(3000));
    }

    // An unknown option is rejected rather than ignored.
    {
        var s = try Session.start(&.{ exe_path, "--nonsense" });
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try s.pump(&out, gpa, 800);
        try testing.expectEqual(@as(?u8, 2), s.wait(3000));
        try testing.expect(std.mem.indexOf(u8, out.items, "unknown option") != null);
    }

    // --devices reports the null backend when asked for it.
    {
        var s = try Session.start(&.{ exe_path, "--null-audio", "--devices" });
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try s.pump(&out, gpa, 1200);
        try testing.expectEqual(@as(?u8, 0), s.wait(3000));
        try testing.expect(std.mem.indexOf(u8, out.items, "Null") != null);
    }
}

test "a file it cannot play is reported, not silently ignored" {
    const gpa = testing.allocator;
    var s = try Session.start(&.{ exe_path, "--null-audio", "--no-config", "/definitely/not/here.mp3" });
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try s.pump(&out, gpa, 1500);
    try testing.expectEqual(@as(?u8, 1), s.wait(3000));
    try testing.expect(std.mem.indexOf(u8, out.items, "nothing") != null);
}

