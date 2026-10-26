//! Integer screen geometry. Coordinates are zero-based cells, origin top-left.

pub const Point = struct {
    x: u16,
    y: u16,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.x < r.x + r.w and
            p.y >= r.y and p.y < r.y + r.h;
    }

    pub fn right(r: Rect) u16 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) u16 {
        return r.y + r.h;
    }

    /// A sub-rectangle in `r`'s coordinate space, clipped to stay inside it.
    pub fn inset(r: Rect, dx: u16, dy: u16) Rect {
        const w = if (r.w > 2 * dx) r.w - 2 * dx else 0;
        const h = if (r.h > 2 * dy) r.h - 2 * dy else 0;
        return .{ .x = r.x + dx, .y = r.y + dy, .w = w, .h = h };
    }

    /// Translate into the coordinate space of `r`, for hit-testing a child.
    pub fn localize(r: Rect, p: Point) ?Point {
        if (!r.contains(p)) return null;
        return .{ .x = p.x - r.x, .y = p.y - r.y };
    }
};

test "Rect contains and localize" {
    const std = @import("std");
    const r: Rect = .{ .x = 10, .y = 5, .w = 4, .h = 2 };

    try std.testing.expect(r.contains(.{ .x = 10, .y = 5 }));
    try std.testing.expect(r.contains(.{ .x = 13, .y = 6 }));
    try std.testing.expect(!r.contains(.{ .x = 14, .y = 6 }));
    try std.testing.expect(!r.contains(.{ .x = 13, .y = 7 }));
    try std.testing.expect(!r.contains(.{ .x = 9, .y = 5 }));

    try std.testing.expectEqual(
        Point{ .x = 3, .y = 1 },
        r.localize(.{ .x = 13, .y = 6 }).?,
    );
    try std.testing.expectEqual(@as(?Point, null), r.localize(.{ .x = 0, .y = 0 }));
}

test "Rect inset clamps rather than underflowing" {
    const std = @import("std");
    const r: Rect = .{ .x = 0, .y = 0, .w = 3, .h = 1 };
    const i = r.inset(2, 2);
    try std.testing.expectEqual(@as(u16, 0), i.w);
    try std.testing.expectEqual(@as(u16, 0), i.h);
}
