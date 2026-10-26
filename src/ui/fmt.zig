//! Time formatting shared by the windows.

const std = @import("std");

/// `mm:ss`, with minutes clamped to two digits like Winamp's readout.
pub fn clock(secs: u32) [5]u8 {
    var out: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>2}:{d:0>2}", .{
        @min(secs / 60, 99),
        secs % 60,
    }) catch return .{ '-', '-', ':', '-', '-' };
    return out;
}

/// `m:ss` or `h:mm:ss`, for durations that may exceed an hour. Unknown
/// durations (negative) render as a dash, which is what the playlist shows
/// before a track has been probed.
pub fn duration(buf: []u8, secs: f32) []const u8 {
    if (secs < 0) return "-:--";
    const total: u64 = @intFromFloat(@round(secs));
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "-:--";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "-:--";
}

const testing = std.testing;

test "clock pads and clamps" {
    try testing.expectEqualStrings("00:00", &clock(0));
    try testing.expectEqualStrings("01:05", &clock(65));
    try testing.expectEqualStrings("99:59", &clock(99 * 60 + 59));
    // Past 99 minutes the minute field saturates rather than overflowing.
    try testing.expectEqualStrings("99:07", &clock(200 * 60 + 7));
}

test "duration switches to hours and marks unknown" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:00", duration(&buf, 0));
    try testing.expectEqualStrings("3:12", duration(&buf, 192));
    try testing.expectEqualStrings("1:04:33", duration(&buf, 3873));
    try testing.expectEqualStrings("-:--", duration(&buf, -1));
    // Rounds to the nearest second rather than truncating.
    try testing.expectEqualStrings("3:13", duration(&buf, 192.6));
}
