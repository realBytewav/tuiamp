# tuiamp

**Winamp, but the "win" is a TUI.**

[![CI](https://github.com/realBytewav/tuiamp/actions/workflows/ci.yml/badge.svg)](https://github.com/realBytewav/tuiamp/actions/workflows/ci.yml)

A deliberate recreation of Winamp 2.9 in the terminal — not a modern player
with a retro colour scheme. The main window, equalizer and playlist editor
are three stacked windows you show, hide and collapse independently, with the
widgets in their real Winamp positions.

![tuiamp playing a 1,457-track library: transport and analyzer, the ten-band equalizer, and the playlist](docs/demo.gif)

## Requirements

- **Linux**, on glibc or musl, x86_64 or aarch64 — all four combinations are
  verified by cross-compiling, and CI builds and tests on stock Ubuntu.
  macOS and Windows do not build: the terminal layer uses `signalfd` for
  SIGWINCH and a raw `ioctl` for the window size, and Windows additionally
  needs a different `std.process.Args` path. The Linux-specific parts are
  confined to `src/term/tty.zig` and one function in `src/ui/app.zig`, so a
  port is a contained job if you fancy it.
- **A truecolor terminal.** Colours are emitted as 24-bit SGR with no
  256-colour fallback, so on an older terminal they will be wrong. Inside
  tmux you want `set -as terminal-features ",*:RGB"`.
- **Zig 0.16.0 exactly**, to build from source. 0.16 moved `std.fs.File` to
  `std.Io.File`, so neither 0.15 nor 0.17 will work.
- **A font with box-drawing and block glyphs**, or `--theme ascii`.
- 80x16 cells for the full layout; it falls back to a one-line windowshade
  below that. 80x24 shows the whole `?` overlay, which is what it is sized
  for.

## Running it

With Nix, without cloning anything:

```sh
nix run github:realBytewav/tuiamp -- ~/Music
```

From a checkout — Zig 0.16.0 and nothing else:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/tuiamp ~/Music
```

```sh
tuiamp track.mp3
tuiamp ~/Music            # scans recursively
tuiamp playlist.m3u       # m3u, m3u8 and pls
tuiamp --volume 25 --theme ascii ~/Music/Album
tuiamp --devices          # which backend and output device it will use
```

Press `?` — or click the `?` in the titlebar — for the keymap, then again
for what it can do. `ctrl+p` opens settings. Settings are saved to
`~/.config/tuiamp/config.zon` on exit; `--no-config` leaves it alone.

## Keys

Winamp's own, where they exist.

```
z x c v b   prev / play / pause / stop / next      tab    cycle window focus
space       play / pause                           alt+e  playlist
left/right  seek 5s        up/down  volume         alt+g  equalizer
s shuffle   r repeat       j jump to playing       w      windowshade
t elapsed / remaining      g cycle analyzer        q      quit
? keys, then what it does  ctrl+p settings
```

Mouse: drag the seek, volume, balance, equalizer and playlist-scroll
sliders; click the transport buttons; double-click a playlist row; the wheel
sets volume, or scrolls the playlist.

## What it does

- **Formats**: MP3, FLAC and WAV, through miniaudio's built-in decoders.
- **Tags**: ID3v2.2/2.3/2.4 and Vorbis comments are read at scan time, so
  titles and durations are there before anything plays. MP3 lengths come
  from the Xing/VBRI header where there is one, and from the file size
  otherwise. A 1,457-track library loads in about half a second.
- **Playlist**: recursive directory scan, m3u/m3u8/pls read and write,
  reordering, shuffle as a permutation over a fixed view, repeat off/all/one.
  The scrollbar lives in the window's right-hand border, where Winamp put
  its own, so it costs no title width.
- **Visualizer**: a passthrough node taps the audio into a lock-free ring; the
  UI runs a windowed FFT over it and draws a log-spaced spectrum with falling
  peak caps, or an oscilloscope at half-block resolution.
- **Equalizer**: ten bands at Winamp's frequencies plus a preamp, ±12 dB, as a
  chain of peaking biquads, with Winamp's stock presets.
- **Themes**: palette and glyph set in a ZON file. Seven are built in —
  `classic`, `ascii`, `amber` (monochrome phosphor), `gruvbox`, `neon`
  (synthwave), `nord`, and `paper`, the one for a light terminal. Pick one
  with `ctrl+p`, which lists them alongside whatever is in
  `~/.config/tuiamp/themes/` and applies each as you move down the list, or
  pass `--theme <name>`. Each built-in is defined once, in the same ZON file
  that gets installed to `share/tuiamp/themes/`, so what you copy to start
  your own theme is literally the theme that shipped. A theme is usually
  just a palette: leave the glyph table out and it inherits the
  box-drawing set.

## What it does not do

- **No Ogg Vorbis, Opus or AAC.** miniaudio decodes MP3, FLAC and WAV; the
  rest would need stb_vorbis or libopus wired in through
  `ma_decoding_backend_vtable`.
- **No gapless playback.** Tracks are opened one at a time.
- **No double-size mode.** Winamp's Ctrl+D doubles the window; here it would
  mean a second set of layout constants for every widget, which is more
  machinery than the feature is worth.
- **No network streams.** URLs in a playlist are skipped rather than played.

## A note on dlopen, ALSA and NixOS

miniaudio reaches ALSA and PulseAudio with `dlopen` rather than linking
them, so `libasound.so.2` has to be findable at run time. On most
distributions it already is. On NixOS it is not, and the failure is nasty:
miniaudio falls back to its null backend, which consumes frames at the right
rate, so the clock advances and the analyzer dances while nothing comes out.

Two things prevent that. `build.zig` probes the usual locations and bakes the
one it finds in as an rpath (override with `-Daudio-rpath=<dir>`, or pass an
empty string to skip), and the engine builds its own context from a backend
list that excludes the null device, so a missing library is a loud startup
error rather than silence. `tuiamp --devices` shows what is visible.

## Building and testing

```sh
zig build                 # debug
zig build -Doptimize=ReleaseFast
zig build test            # 256 unit + 10 end-to-end tests
zig build test-unit       # just the unit tests
zig build test-e2e        # just the end-to-end ones
nix develop               # a shell with the right Zig and libraries
nix build .#tuiamp        # the packaged build
```

Nothing here needs a sound card.

The **unit tests** check the audio path by driving miniaudio's no-device
engine and reading the node graph's output directly. That is the only way
to see what a listener would actually hear: the visualizer taps the signal
*upstream* of the master volume, so it cannot tell silence from sound, and
a build once shipped that advanced its clock and animated its analyzer
while playing nothing at all.

The **end-to-end tests** allocate a pseudo-terminal, exec the real binary on
it, type at it, and assert on what it draws and how it exits — that the
window appears, that keys reach it, that it keeps redrawing while playing,
that a scrolled playlist stays where it was put, that `ctrl+p` really
repaints the player in another theme rather than just listing one, and that
it hands the terminal back.
They replay the output into a cell grid first, because the renderer emits
only the cells that changed: a playlist row reading `30. Scroll 30` after a
scroll is assembled from whatever differed from the frame before and need
never appear as contiguous bytes in the stream. They run against `--null-audio`, which
selects miniaudio's null device. That device is reachable only when named
explicitly, never as a fallback, so it can never become the reason your
music is silent.

## Layout

```
src/
  main.zig         argument parsing and wire-up
  c.zig            the single @cImport of miniaudio
  config.zig       settings, as ZON
  audio/           engine, player, eq, the visualizer tap, fft
  meta/            id3, mpeg frame headers, flac, wav, text decoding
  playlist/        the list model, m3u, pls, directory scanning
  term/            raw mode, input decoding, the cell grid
  ui/              the windows and widgets
  themes/          the built-in themes, also installed for copying
vendor/miniaudio/  miniaudio 0.11.25, vendored unmodified
```

The terminal layer is hand-written rather than using a TUI library: Zig
0.16 moved `std.fs.File` to `std.Io.File` and the ecosystem has not caught
up, and a Winamp UI is custom-drawn anyway. There are no third-party Zig
dependencies.

## Licence and credits

tuiamp is MIT licensed — see [LICENSE](LICENSE).

`vendor/miniaudio/miniaudio.h` is [miniaudio](https://miniaud.io) v0.11.25 by
David Reid, vendored unmodified. It is the author's choice of public domain
or MIT-0; the full statements are at the end of that file.

Winamp was made by Justin Frankel and Dmitry Boldyrev at Nullsoft. This is an
affectionate homage, not affiliated with them in any way.
