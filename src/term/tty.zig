//! Terminal entry and exit: raw mode, alternate screen, cursor and mouse
//! reporting. Everything this module turns on, `deinit` turns back off.
//!
//! Leaving a terminal in raw mode with no cursor is the single most hostile
//! thing a TUI can do to a user, so the restore path is also wired to the
//! panic handler via `restoreActive`.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const esc = struct {
    pub const alt_screen_on = "\x1b[?1049h";
    pub const alt_screen_off = "\x1b[?1049l";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
    pub const cursor_home = "\x1b[H";
    pub const clear = "\x1b[2J";
    pub const sgr_reset = "\x1b[0m";
    /// Button-event tracking (press, release, drag) with SGR extended
    /// coordinates, so columns past 223 still report correctly.
    pub const mouse_on = "\x1b[?1002h\x1b[?1006h";
    pub const mouse_off = "\x1b[?1006l\x1b[?1002l";
    pub const sync_begin = "\x1b[?2026h";
    pub const sync_end = "\x1b[?2026l";
};

pub const Size = struct { cols: u16, rows: u16 };

/// Set while a `Tty` holds the terminal, so the panic handler can restore it.
var active: ?*Tty = null;

pub const Tty = struct {
    in: posix.fd_t,
    out: posix.fd_t,
    original: posix.termios,
    entered: bool = false,

    pub fn init() !Tty {
        const in = std.Io.File.stdin().handle;
        const out = std.Io.File.stdout().handle;
        return .{
            .in = in,
            .out = out,
            .original = try posix.tcgetattr(in),
        };
    }

    /// Enter raw mode and the alternate screen. Idempotent.
    pub fn enter(t: *Tty) !void {
        if (t.entered) return;

        var raw = t.original;
        // No line buffering, no echo, and no signal generation: we want every
        // keystroke as a byte, including ^C, which we bind ourselves.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        // Reads return immediately with whatever is available; blocking is the
        // job of poll(), not of the terminal driver.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        // FLUSH discards anything typed before we took control. That loses
        // type-ahead, but it also guarantees we never start parsing from the
        // middle of an escape sequence that was already in flight.
        try posix.tcsetattr(t.in, .FLUSH, raw);

        try t.write(esc.alt_screen_on ++ esc.cursor_hide ++ esc.mouse_on ++
            esc.clear ++ esc.cursor_home);

        t.entered = true;
        active = t;
    }

    pub fn deinit(t: *Tty) void {
        if (!t.entered) return;
        t.entered = false;
        active = null;

        t.write(esc.mouse_off ++ esc.sgr_reset ++ esc.cursor_show ++
            esc.alt_screen_off) catch {};
        posix.tcsetattr(t.in, .FLUSH, t.original) catch {};
    }

    pub fn write(t: *const Tty, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rest = bytes[off..];
            const rc = linux.write(t.out, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }

    pub fn size(t: *const Tty) !Size {
        var ws: posix.winsize = undefined;
        const rc = linux.ioctl(t.out, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
        return .{
            .cols = if (ws.col == 0) 80 else ws.col,
            .rows = if (ws.row == 0) 24 else ws.row,
        };
    }
};

/// Best-effort restore from a panic or signal handler. Safe to call when no
/// terminal is held.
pub fn restoreActive() void {
    if (active) |t| t.deinit();
}
