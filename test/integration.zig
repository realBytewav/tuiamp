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
fn writeTone(dir: std.Io.Dir, name: []const u8) !void {
    const gpa = testing.allocator;
    const rate: u32 = 48000;
    const frames: u32 = rate * 2;
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

test "it keeps redrawing while playing, so the device is pulling frames" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTone(tmp.dir, "tone.wav");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const track = try std.fs.path.joinZ(gpa, &.{ root, "tone.wav" });
    defer gpa.free(track);

    var session = try Session.start(&.{
        exe_path, "--null-audio", "--no-config", "--volume", "50", track.ptr,
    });
    defer session.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Let it settle, then measure how much it draws over a fixed window.
    try session.pump(&out, gpa, 1500);
    const after_settle = out.items.len;
    try session.pump(&out, gpa, 1500);
    const after_playing = out.items.len;

    session.send("q");
    try session.pump(&out, gpa, 600);

    // A player whose device never calls back would draw its first frame and
    // then go quiet. The clock and the analyzer mean it never does.
    try testing.expect(after_settle > 0);
    try testing.expect(after_playing > after_settle);

    try testing.expectEqual(@as(?u8, 0), session.wait(3000));
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
