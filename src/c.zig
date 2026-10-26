//! The project's single `@cImport`.
//!
//! miniaudio is a ~96k line header, so translating it is expensive. Keeping it
//! to one import means it is translated once and every other module gets it
//! through `@import("../c.zig").c`.
//!
//! miniaudio's configuration macros are set in build.zig (`ma_macros`) rather
//! than here, so that this translation and the C translation unit in
//! vendor/miniaudio/miniaudio_impl.c always agree on struct layout.
pub const c = @cImport({
    @cInclude("miniaudio.h");
});
