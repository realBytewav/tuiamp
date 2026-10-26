//! Terminal input decoding: raw bytes in, `Event`s out.
//!
//! The parser is incremental because escape sequences get split across reads
//! at any boundary. `push` appends bytes and `next` yields whatever complete
//! events are now available, leaving a partial tail in the buffer for the next
//! read. That design is also what makes it testable without a terminal: the
//! tests below feed recorded byte strings, including deliberately split ones.
//!
//! A lone ESC is ambiguous — it could be the Escape key, or the start of a
//! sequence whose remainder has not arrived. We hold it and let the caller
//! resolve it with `flushPending` once its poll times out.

const std = @import("std");

pub const Mods = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    pub const none: Mods = .{};

    /// Decode the xterm modifier parameter, which is 1 + a bitmask.
    fn fromParam(param: u32) Mods {
        if (param == 0) return .none;
        const bits = param - 1;
        return .{
            .shift = bits & 1 != 0,
            .alt = bits & 2 != 0,
            .ctrl = bits & 4 != 0,
        };
    }
};

pub const Key = union(enum) {
    /// A printable codepoint.
    char: u21,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    /// Function key, 1-based.
    f: u8,
};

pub const Button = enum { left, middle, right, wheel_up, wheel_down, none };

pub const Mouse = struct {
    button: Button,
    action: enum { press, release, drag, motion },
    /// Zero-based cell coordinates.
    x: u16,
    y: u16,
    mods: Mods = .none,
};

pub const Event = union(enum) {
    key: struct { key: Key, mods: Mods = .none },
    mouse: Mouse,
    paste_start,
    paste_end,
    /// A recognized but unhandled sequence. Carried rather than dropped so
    /// callers can log it; ignoring it is always correct.
    unknown,

    pub fn isChar(e: Event, ch: u21) bool {
        return e == .key and e.key.key == .char and e.key.key.char == ch and
            !e.key.mods.ctrl and !e.key.mods.alt;
    }

    pub fn isCtrl(e: Event, ch: u21) bool {
        return e == .key and e.key.key == .char and e.key.key.char == ch and
            e.key.mods.ctrl;
    }
};

pub const Parser = struct {
    /// Large enough for any sequence a terminal will emit; overlong garbage is
    /// discarded rather than allowed to wedge the parser.
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn push(p: *Parser, bytes: []const u8) void {
        const room = p.buf.len - p.len;
        if (bytes.len > room) {
            // Desynchronized or hostile input: drop what we hold and keep the
            // newest bytes, which are the ones a user is waiting on.
            p.len = 0;
            const keep = bytes[bytes.len - @min(bytes.len, p.buf.len) ..];
            @memcpy(p.buf[0..keep.len], keep);
            p.len = keep.len;
            return;
        }
        @memcpy(p.buf[p.len..][0..bytes.len], bytes);
        p.len += bytes.len;
    }

    /// Yield the next complete event, or null if more bytes are needed.
    pub fn next(p: *Parser) ?Event {
        while (true) {
            if (p.len == 0) return null;
            const r = decode(p.buf[0..p.len]) orelse return null;
            p.consume(r.used);
            if (r.event) |e| return e;
            // A sequence we recognized the shape of but produced nothing for;
            // keep going rather than returning to the caller empty-handed.
        }
    }

    /// Resolve a held-back lone ESC as the Escape key. Call this when the
    /// input poll times out, which is the only evidence that no continuation
    /// byte is coming.
    pub fn flushPending(p: *Parser) ?Event {
        if (p.len == 1 and p.buf[0] == 0x1b) {
            p.len = 0;
            return .{ .key = .{ .key = .escape } };
        }
        return null;
    }

    fn consume(p: *Parser, n: usize) void {
        std.debug.assert(n <= p.len);
        std.mem.copyForwards(u8, p.buf[0 .. p.len - n], p.buf[n..p.len]);
        p.len -= n;
    }
};

const Decoded = struct {
    used: usize,
    event: ?Event,
};

/// Decode one event from the front of `s`. Returns null when `s` holds the
/// prefix of a sequence that is not yet complete.
fn decode(s: []const u8) ?Decoded {
    std.debug.assert(s.len > 0);

    if (s[0] == 0x1b) {
        if (s.len == 1) return null; // ESC, or an incomplete sequence
        return switch (s[1]) {
            '[' => decodeCsi(s),
            'O' => decodeSs3(s),
            // ESC followed by anything else is Alt+that.
            else => alt: {
                const inner = decode(s[1..]) orelse break :alt null;
                var e = inner.event;
                if (e) |*ev| if (ev.* == .key) {
                    ev.key.mods.alt = true;
                };
                break :alt .{ .used = 1 + inner.used, .event = e };
            },
        };
    }

    // C0 control codes.
    switch (s[0]) {
        '\r', '\n' => return .{ .used = 1, .event = .{ .key = .{ .key = .enter } } },
        '\t' => return .{ .used = 1, .event = .{ .key = .{ .key = .tab } } },
        0x7f, 0x08 => return .{ .used = 1, .event = .{ .key = .{ .key = .backspace } } },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => {
            // Ctrl+letter. 0x01 is Ctrl+A.
            const letter: u21 = @as(u21, s[0]) + 'a' - 1;
            return .{ .used = 1, .event = .{ .key = .{
                .key = .{ .char = letter },
                .mods = .{ .ctrl = true },
            } } };
        },
        else => {},
    }

    // UTF-8.
    const seq_len = std.unicode.utf8ByteSequenceLength(s[0]) catch {
        return .{ .used = 1, .event = .unknown };
    };
    if (s.len < seq_len) return null;
    const cp = std.unicode.utf8Decode(s[0..seq_len]) catch {
        return .{ .used = 1, .event = .unknown };
    };
    return .{ .used = seq_len, .event = .{ .key = .{ .key = .{ .char = cp } } } };
}

/// `s` starts with ESC '['. CSI is: parameter bytes 0x30-0x3f, then
/// intermediate bytes 0x20-0x2f, then one final byte 0x40-0x7e.
fn decodeCsi(s: []const u8) ?Decoded {
    var i: usize = 2;
    while (i < s.len and s[i] >= 0x30 and s[i] <= 0x3f) i += 1;
    while (i < s.len and s[i] >= 0x20 and s[i] <= 0x2f) i += 1;
    if (i >= s.len) return null; // final byte has not arrived
    const final = s[i];
    const params_raw = s[2..i];
    const used = i + 1;

    // SGR mouse reporting: ESC [ < button ; x ; y (M|m)
    if (params_raw.len > 0 and params_raw[0] == '<') {
        return .{ .used = used, .event = decodeSgrMouse(params_raw[1..], final) };
    }

    var params: [8]u32 = @splat(0);
    const n = parseParams(params_raw, &params);
    const first = if (n > 0) params[0] else 0;
    const mods: Mods = .fromParam(if (n > 1) params[1] else 0);

    const key: Key = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'R' => .{ .f = 3 },
        'S' => .{ .f = 4 },
        'Z' => return .{ .used = used, .event = .{ .key = .{
            .key = .tab,
            .mods = .{ .shift = true },
        } } },
        '~' => switch (first) {
            1, 7 => .home,
            2 => .insert,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            11...15 => .{ .f = @intCast(first - 10) },
            17...21 => .{ .f = @intCast(first - 11) },
            23...26 => .{ .f = @intCast(first - 12) },
            200 => return .{ .used = used, .event = .paste_start },
            201 => return .{ .used = used, .event = .paste_end },
            else => return .{ .used = used, .event = .unknown },
        },
        // Kitty keyboard protocol reports codepoints with a 'u' final byte.
        'u' => .{ .char = std.math.cast(u21, first) orelse
            return .{ .used = used, .event = .unknown } },
        else => return .{ .used = used, .event = .unknown },
    };

    return .{ .used = used, .event = .{ .key = .{ .key = key, .mods = mods } } };
}

/// `s` starts with ESC 'O', used for F1-F4 and application-mode arrows.
fn decodeSs3(s: []const u8) ?Decoded {
    if (s.len < 3) return null;
    const key: Key = switch (s[2]) {
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'R' => .{ .f = 3 },
        'S' => .{ .f = 4 },
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => return .{ .used = 3, .event = .unknown },
    };
    return .{ .used = 3, .event = .{ .key = .{ .key = key } } };
}

fn decodeSgrMouse(params_raw: []const u8, final: u8) Event {
    var params: [4]u32 = @splat(0);
    if (parseParams(params_raw, &params) < 3) return .unknown;
    const code = params[0];

    // Terminals report 1-based coordinates; we work in 0-based cells.
    const x: u16 = @intCast(@max(params[1], 1) - 1);
    const y: u16 = @intCast(@max(params[2], 1) - 1);

    const mods: Mods = .{
        .shift = code & 4 != 0,
        .alt = code & 8 != 0,
        .ctrl = code & 16 != 0,
    };
    const dragging = code & 32 != 0;
    const wheel = code & 64 != 0;

    const button: Button = if (wheel) switch (code & 3) {
        0 => .wheel_up,
        1 => .wheel_down,
        else => .none,
    } else switch (code & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };

    return .{ .mouse = .{
        .button = button,
        .action = if (wheel)
            .press
        else if (final == 'm')
            .release
        else if (dragging)
            if (button == .none) .motion else .drag
        else
            .press,
        .x = x,
        .y = y,
        .mods = mods,
    } };
}

fn parseParams(raw: []const u8, out: []u32) usize {
    var count: usize = 0;
    var value: u32 = 0;
    var seen_digit = false;
    for (raw) |ch| {
        switch (ch) {
            '0'...'9' => {
                value = value * 10 + (ch - '0');
                seen_digit = true;
            },
            // ';' separates parameters; ':' separates sub-parameters, which we
            // do not use, so treat it the same and let the sub-value land in a
            // slot we ignore.
            ';', ':' => {
                if (count < out.len) out[count] = value;
                count += 1;
                value = 0;
                seen_digit = false;
            },
            else => {},
        }
    }
    if (seen_digit or count > 0) {
        if (count < out.len) out[count] = value;
        count += 1;
    }
    return @min(count, out.len);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectOne(bytes: []const u8) !Event {
    var p: Parser = .{};
    p.push(bytes);
    const e = p.next() orelse return error.Incomplete;
    try testing.expectEqual(@as(usize, 0), p.len);
    return e;
}

test "plain characters and ctrl" {
    try testing.expect((try expectOne("z")).isChar('z'));
    try testing.expect((try expectOne("\x03")).isCtrl('c'));
    try testing.expect((try expectOne("\x04")).isCtrl('d'));

    const tab = try expectOne("\t");
    try testing.expectEqual(Key.tab, tab.key.key);

    const enter = try expectOne("\r");
    try testing.expectEqual(Key.enter, enter.key.key);
}

test "arrows, both CSI and SS3" {
    try testing.expectEqual(Key.up, (try expectOne("\x1b[A")).key.key);
    try testing.expectEqual(Key.down, (try expectOne("\x1b[B")).key.key);
    try testing.expectEqual(Key.right, (try expectOne("\x1b[C")).key.key);
    try testing.expectEqual(Key.left, (try expectOne("\x1b[D")).key.key);
    try testing.expectEqual(Key.up, (try expectOne("\x1bOA")).key.key);
}

test "modified keys" {
    const shift_up = try expectOne("\x1b[1;2A");
    try testing.expectEqual(Key.up, shift_up.key.key);
    try testing.expect(shift_up.key.mods.shift);
    try testing.expect(!shift_up.key.mods.ctrl);

    const ctrl_right = try expectOne("\x1b[1;5C");
    try testing.expectEqual(Key.right, ctrl_right.key.key);
    try testing.expect(ctrl_right.key.mods.ctrl);

    const shift_tab = try expectOne("\x1b[Z");
    try testing.expectEqual(Key.tab, shift_tab.key.key);
    try testing.expect(shift_tab.key.mods.shift);
}

test "tilde keys and function keys" {
    try testing.expectEqual(Key.delete, (try expectOne("\x1b[3~")).key.key);
    try testing.expectEqual(Key.page_up, (try expectOne("\x1b[5~")).key.key);
    try testing.expectEqual(Key.page_down, (try expectOne("\x1b[6~")).key.key);
    try testing.expectEqual(Key{ .f = 5 }, (try expectOne("\x1b[15~")).key.key);
    try testing.expectEqual(Key{ .f = 12 }, (try expectOne("\x1b[24~")).key.key);
    try testing.expectEqual(Key{ .f = 1 }, (try expectOne("\x1bOP")).key.key);
}

test "alt-prefixed keys" {
    const alt_e = try expectOne("\x1be");
    try testing.expectEqual(Key{ .char = 'e' }, alt_e.key.key);
    try testing.expect(alt_e.key.mods.alt);
}

test "lone ESC is held until flushed" {
    var p: Parser = .{};
    p.push("\x1b");
    try testing.expectEqual(@as(?Event, null), p.next());
    const e = p.flushPending() orelse return error.NoEvent;
    try testing.expectEqual(Key.escape, e.key.key);
    try testing.expectEqual(@as(usize, 0), p.len);
}

test "sequences split across reads" {
    var p: Parser = .{};
    // Every boundary a terminal could pick for ESC [ 1 ; 5 C.
    const full = "\x1b[1;5C";
    var split: usize = 1;
    while (split < full.len) : (split += 1) {
        p = .{};
        p.push(full[0..split]);
        try testing.expectEqual(@as(?Event, null), p.next());
        p.push(full[split..]);
        const e = p.next() orelse return error.Incomplete;
        try testing.expectEqual(Key.right, e.key.key);
        try testing.expect(e.key.mods.ctrl);
    }
}

test "multiple events in one read" {
    var p: Parser = .{};
    p.push("z\x1b[Ax");
    try testing.expect(p.next().?.isChar('z'));
    try testing.expectEqual(Key.up, p.next().?.key.key);
    try testing.expect(p.next().?.isChar('x'));
    try testing.expectEqual(@as(?Event, null), p.next());
}

test "SGR mouse press, drag, release" {
    const press = (try expectOne("\x1b[<0;10;5M")).mouse;
    try testing.expectEqual(Button.left, press.button);
    try testing.expectEqual(@as(u16, 9), press.x); // 1-based -> 0-based
    try testing.expectEqual(@as(u16, 4), press.y);
    try testing.expectEqual(@as(@TypeOf(press.action), .press), press.action);

    const drag = (try expectOne("\x1b[<32;11;5M")).mouse;
    try testing.expectEqual(Button.left, drag.button);
    try testing.expectEqual(@as(@TypeOf(drag.action), .drag), drag.action);

    const release = (try expectOne("\x1b[<0;11;5m")).mouse;
    try testing.expectEqual(@as(@TypeOf(release.action), .release), release.action);

    const wheel = (try expectOne("\x1b[<64;3;3M")).mouse;
    try testing.expectEqual(Button.wheel_up, wheel.button);
    try testing.expectEqual(Button.wheel_down, (try expectOne("\x1b[<65;3;3M")).mouse.button);
}

test "mouse coordinates past 223 columns survive" {
    const m = (try expectOne("\x1b[<0;300;120M")).mouse;
    try testing.expectEqual(@as(u16, 299), m.x);
    try testing.expectEqual(@as(u16, 119), m.y);
}

test "bracketed paste markers" {
    try testing.expectEqual(Event.paste_start, try expectOne("\x1b[200~"));
    try testing.expectEqual(Event.paste_end, try expectOne("\x1b[201~"));
}

test "multibyte UTF-8 split across reads" {
    var p: Parser = .{};
    const snowman = "\xe2\x98\x83"; // U+2603
    p.push(snowman[0..2]);
    try testing.expectEqual(@as(?Event, null), p.next());
    p.push(snowman[2..]);
    try testing.expectEqual(Key{ .char = 0x2603 }, p.next().?.key.key);
}

test "unknown sequences are consumed, not wedged" {
    var p: Parser = .{};
    p.push("\x1b[?2026;1$yz");
    while (p.next()) |e| {
        if (e.isChar('z')) return; // reached the real key behind the garbage
    }
    return error.ParserWedged;
}
