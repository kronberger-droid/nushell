{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      # systems = lib.systems.flakeExposed;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "powerpc64le-linux"
        "aarch64-darwin"
        "riscv64-linux"
        "armv6l-linux"
        "armv7l-linux"
        "i686-linux"
        ## Broken in `nix flake check`
        # "x86_64-freebsd"
      ];
      main-overlay = final: previous: {
        # Override the rustPlatform without forcing a rebuild of _every_ tool as well
        rustToolchain' = previous.rust-bin.fromRustupToolchainFile ../../rust-toolchain.toml;
        rustPlatform' = final.makeRustPlatform {
          cargo = final.rustToolchain';
          rustc = final.rustToolchain';
        };
        # Add a specific rustPlatform with extensions for development/editors
        rustToolchain-devshell = final.rustToolchain'.override ({
          extensions = [
            "rust-src"
            "rust-analyzer"
          ];
        });
        rustPlatform-devshell = final.makeRustPlatform {
          cargo = final.rustToolchain-devshell;
          rustc = final.rustToolchain-devshell;
        };
        rustToolchain-latest-devshell = previous.rust-bin.stable.latest.default.override ({
          extensions = [
            "rust-src"
            "rust-analyzer"
          ];
        });
        rustPlatform-latest-devshell = final.makeRustPlatform {
          cargo = final.rustToolchain-latest-devshell;
          rustc = final.rustToolchain-latest-devshell;
        };
        # nushell, its plugins and the CI checks, built incrementally with
        # crane. See ./crane.nix.
        nushellCrane = final.callPackage ./crane.nix {
          craneLib = (inputs.crane.mkLib final).overrideToolchain final.rustToolchain';
          inherit (final.rustPlatform') bindgenHook;
          commitHash = inputs.self.rev or inputs.self.dirtyRev or null;
        };
        nushell = final.nushellCrane.nushell;
        nushellPlugins = previous.nushellPlugins // final.nushellCrane.plugins;
      };
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                inputs.rust-overlay.overlays.default
                main-overlay
              ];
            };
          }
        );
    in
    {
      overlays = {
        default = main-overlay;
      };
      packages = forEachSupportedSystem (
        { pkgs, ... }:
        {
          inherit (pkgs) nushell;
          default = pkgs.nushell;
          dev = (pkgs.nushellCrane.override { profile = "dev"; }).nushell;
        }
      );
      checks = forEachSupportedSystem ({ pkgs, ... }: pkgs.nushellCrane.checks);
      legacyPackages = forEachSupportedSystem (
        { pkgs, ... }:
        {
          nushellPlugins = {
            # Only getting a subset of these so we don't have _all_ of the
            # plugins that are in `nixpkgs`
            inherit (pkgs.nushellPlugins)
              formats
              gstat
              inc
              polars
              query
              ;
          };
        }
      );
      devShells = forEachSupportedSystem (
        { pkgs, ... }:
        let
          basepkgs =
            with pkgs;
            (
              [
                curlMinimal
                openssl
                pkg-config
                zstd
              ]
              ++ (lib.optionals stdenv.hostPlatform.isLinux [
                python3
                libX11
              ])
              ++ (lib.optionals stdenv.hostPlatform.isDarwin [
                zlib
                nghttp2
                libgit2
              ])
            );
        in
        {
          # devshell with build/check deps from nushell and plugins, with some
          # separation for linux/darwin.
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                rustToolchain-devshell
                rustPlatform-devshell.bindgenHook
              ]
              ++ basepkgs;
          };
          latest = pkgs.mkShell {
            packages =
              with pkgs;
              [
                rustToolchain-latest-devshell
                rustPlatform-latest-devshell.bindgenHook
              ]
              ++ basepkgs;
          };
        }
      );
    };
}
