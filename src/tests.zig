//! Aggregates every module's tests so `zig build test` sees all of them.
comptime {
    _ = @import("audio/engine.zig");
    _ = @import("ui/help.zig");
    _ = @import("config.zig");
    _ = @import("ui/eq_window.zig");
    _ = @import("audio/eq.zig");
    _ = @import("meta/tags.zig");
    _ = @import("meta/flac.zig");
    _ = @import("meta/wav.zig");
    _ = @import("meta/mpeg.zig");
    _ = @import("meta/id3.zig");
    _ = @import("meta/text.zig");
    _ = @import("ui/widgets/vis.zig");
    _ = @import("audio/tap.zig");
    _ = @import("audio/fft.zig");
    _ = @import("ui/fmt.zig");
    _ = @import("ui/playlist_window.zig");
    _ = @import("playlist/scan.zig");
    _ = @import("playlist/pls.zig");
    _ = @import("playlist/m3u.zig");
    _ = @import("playlist/list.zig");
    _ = @import("ui/app.zig");
    _ = @import("ui/main_window.zig");
    _ = @import("audio/player.zig");
    _ = @import("term/geom.zig");
    _ = @import("term/input.zig");
    _ = @import("term/screen.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/widgets/lcd.zig");
    _ = @import("ui/widgets/marquee.zig");
    _ = @import("ui/widgets/slider.zig");
}
