const std = @import("std");

/// miniaudio configuration. These are applied to both the C translation unit
/// and the `@cImport` in src/c.zig, so the two always agree on struct layout.
const ma_macros = [_][2][]const u8{
    // We only ever read audio, never write it.
    .{ "MA_NO_ENCODING", "1" },
};

const ma_cflags = [_][]const u8{
    "-std=c99",
    // miniaudio is third-party code; its warnings are not actionable for us.
    "-Wno-unused-function",
    "-Wno-unused-variable",
    "-Wno-unused-but-set-variable",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // miniaudio reaches ALSA and PulseAudio with `dlopen`, not by linking
    // them, so the loader has to be able to find `libasound.so.2` at run
    // time. On a distribution with a global library path that is automatic;
    // on NixOS it is not, and the symptom is miniaudio quietly selecting its
    // null backend and playing flawless silence.
    //
    // Baking the directory in as an rpath makes the binary work from any
    // shell, rather than depending on whoever launches it having exported
    // the right LD_LIBRARY_PATH.
    const audio_rpath = b.option(
        []const u8,
        "audio-rpath",
        "Directory holding libasound.so.2, baked in as an rpath (empty to skip)",
    ) orelse findAlsaDir(b, target);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addMiniaudio(b, exe_mod);
    if (audio_rpath.len > 0) exe_mod.addRPath(.{ .cwd_relative = audio_rpath });

    const exe = b.addExecutable(.{
        .name = "tuiamp",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // The theme files live inside the module so they can be embedded and
    // checked against the built-ins at compile time; install them too, so
    // users have something to copy into ~/.config/tuiamp/themes.
    b.installDirectory(.{
        .source_dir = b.path("src/themes"),
        .install_dir = .prefix,
        .install_subdir = "share/tuiamp/themes",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run tuiamp").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addMiniaudio(b, test_mod);
    if (audio_rpath.len > 0) test_mod.addRPath(.{ .cwd_relative = audio_rpath });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

/// Where `libasound.so.2` lives on this machine, or "" if we cannot tell.
///
/// On most distributions the answer is already on the loader's default path
/// and the rpath is simply redundant. On NixOS there is no such path, so
/// without this the binary builds fine and then plays silence. Probing beats
/// hardcoding: a stranger cloning this on Debian should not have to know.
fn findAlsaDir(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    if (target.result.os.tag != .linux) return "";

    const candidates = [_][]const u8{
        "/run/current-system/sw/lib", // NixOS system profile
        "/usr/lib/x86_64-linux-gnu", // Debian, Ubuntu
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib64", // Fedora, RHEL, openSUSE
        "/usr/lib", // Arch, Alpine
        "/lib/x86_64-linux-gnu",
    };

    const io = b.graph.io;
    for (candidates) |dir| {
        const path = b.fmt("{s}/libasound.so.2", .{dir});
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return dir;
    }
    // Not found at build time. That is not fatal — the library may appear
    // later, or the user may pass -Daudio-rpath — and the run-time error
    // message explains what to do.
    return "";
}

fn addMiniaudio(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/miniaudio"));
    for (ma_macros) |m| mod.addCMacro(m[0], m[1]);
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio_impl.c"),
        .flags = &ma_cflags,
    });
    // miniaudio resolves the ALSA/PulseAudio backends with dlopen at runtime,
    // so there is no build-time dependency on their headers or shared objects.
    // `dl` and `pthread` are POSIX names with no Windows equivalent — libc
    // provides both there — so asking for them breaks a Windows build before
    // it reaches anything interesting.
    mod.linkSystemLibrary("m", .{});
    if (mod.resolved_target.?.result.os.tag != .windows) {
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("pthread", .{});
    }
}
