{
  description = "tuiamp — Winamp, but the \"win\" is a TUI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Linux only, and honestly so: the terminal layer uses signalfd for
      # SIGWINCH and raw linux.ioctl for the window size, neither of which
      # exists on macOS or the BSDs. Porting is a contained job — one file
      # and one function — but it has not been done, and claiming otherwise
      # just wastes a stranger's afternoon.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      packages = forAll (pkgs: rec {
        default = tuiamp;

        tuiamp = pkgs.stdenv.mkDerivation {
          pname = "tuiamp";
          version = "0.2.0";

          # Only the files the build actually reads. The local .zig-cache is
          # measured in gigabytes and must never reach the store.
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./vendor
            ];
          };

          nativeBuildInputs = [ pkgs.zig_0_16.hook pkgs.patchelf ];
          buildInputs = [ pkgs.alsa-lib pkgs.libpulseaudio ];

          # miniaudio dlopens libasound.so.2 rather than linking it, and
          # inside the build sandbox none of the usual system paths exist for
          # build.zig to probe. Point it at the store paths explicitly.
          zigBuildFlags = [ "-Daudio-rpath=${pkgs.alsa-lib}/lib" ];

          # ...and then put it back afterwards. The default fixup runs
          # `patchelf --shrink-rpath`, which drops any rpath entry that no
          # DT_NEEDED library needs — and a dlopened library is, by
          # definition, not one of those. Without this the package builds,
          # installs, and plays silence.
          postFixup = ''
            patchelf --add-rpath "${pkgs.lib.makeLibraryPath [ pkgs.alsa-lib pkgs.libpulseaudio ]}" \
              "$out/bin/tuiamp"
          '';

          meta = with pkgs.lib; {
            description = ''Winamp, but the "win" is a TUI'';
            homepage = "https://github.com/realBytewav/tuiamp";
            license = licenses.mit;
            mainProgram = "tuiamp";
            platforms = platforms.linux;
          };
        };
      });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.tuiamp}/bin/tuiamp";
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_16 pkgs.pkg-config ];

          # For `zig build run` inside the shell: the same dlopen problem,
          # solved the lazy way rather than by rebuilding.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
            alsa-lib
            libpulseaudio
          ]);

          shellHook = ''
            echo "tuiamp dev shell — zig $(zig version)"
          '';
        };
      });
    };
}
