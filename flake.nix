{
  description = "Nushell built from this source tree, with its plugins, CI checks and dev shells";

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

      # rust-overlay's `rust-bin` for a package set. Taken from its library
      # function and not from its overlay, so that `overlays.default` works on
      # its own and adds nothing but nushell to the consumer's `pkgs`.
      rustBin = inputs.rust-overlay.lib.mkRustBin { };

      # The toolchain pinned in rust-toolchain.toml, the one CI builds with.
      toolchain = pkgs: (rustBin pkgs).fromRustupToolchainFile ./rust-toolchain.toml;

      # bindgen's setup hook for a toolchain; only clang-based stdenvs use it.
      bindgenHook =
        pkgs: rust:
        (pkgs.makeRustPlatform {
          cargo = rust;
          rustc = rust;
        }).bindgenHook;

      # Replaces nixpkgs' nushell and its in-tree plugins with builds of this
      # source tree. `nushellCrane` is the whole result of ./scripts/nix/crane.nix
      # and takes `.override`: `nushellSrc` builds another checkout with this
      # expression, `craneLib` swaps the toolchain, `profile` the cargo profile.
      overlay = final: previous: {
        nushellCrane = final.callPackage ./scripts/nix/crane.nix {
          # A function, so that crane picks the package set the toolchain has
          # to come from when `final` is a cross-compiling one.
          craneLib = (inputs.crane.mkLib final).overrideToolchain toolchain;
          bindgenHook = bindgenHook final (toolchain final);
          commitHash = inputs.self.rev or inputs.self.dirtyRev or null;
        };
        nushell = final.nushellCrane.nushell;
        nushellPlugins = previous.nushellPlugins // final.nushellCrane.plugins;
      };

      forEachSupportedSystem =
        f:
        lib.genAttrs systems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ overlay ];
            };
          }
        );
    in
    {
      overlays.default = overlay;

      packages = forEachSupportedSystem (
        { pkgs, ... }:
        let
          inherit (pkgs.nushellCrane) plugins;
        in
        # Every plugin under its binary name, e.g. `nix run .#nu_plugin_polars`.
        lib.mapAttrs' (name: lib.nameValuePair "nu_plugin_${name}") plugins
        // {
          inherit (pkgs) nushell;
          default = pkgs.nushell;
          dev = (pkgs.nushellCrane.override { profile = "dev"; }).nushell;
          # nu and all the plugins in one profile entry. The plugins still have
          # to be registered with `plugin add`.
          full = pkgs.symlinkJoin {
            name = "nushell-full-${pkgs.nushell.version}";
            paths = [ pkgs.nushell ] ++ lib.attrValues plugins;
            inherit (pkgs.nushell) passthru;
            meta = pkgs.nushell.meta // {
              description = "Nushell with the plugins built from its workspace";
            };
          };
        }
      );

      # The plugins as a set, in the shape of nixpkgs' `nushellPlugins`.
      legacyPackages = forEachSupportedSystem (
        { pkgs, ... }:
        {
          nushellPlugins = pkgs.nushellCrane.plugins;
        }
      );

      checks = forEachSupportedSystem (
        { pkgs, ... }:
        pkgs.nushellCrane.checks
        // {
          # Spell check over the whole tree, as CI's typos workflow does. The
          # crane checks see a filtered source without typos.toml or the docs.
          typos = pkgs.runCommand "nushell-typos" { nativeBuildInputs = [ pkgs.typos ]; } ''
            cd ${inputs.self}
            typos
            touch $out
          '';
          nixfmt = pkgs.runCommand "nushell-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${inputs.self} -name '*.nix' -exec nixfmt --check {} +
            touch $out
          '';
        }
      );

      formatter = forEachSupportedSystem ({ pkgs, ... }: pkgs.nixfmt-tree);

      devShells = forEachSupportedSystem (
        { pkgs, ... }:
        let
          # Libraries and build tools that nushell and its plugins link or run:
          # openssl and curl for the gstat, polars and query plugins, python for
          # the virtualenv tests, libx11 for the `system-clipboard` feature.
          nativeDeps =
            with pkgs;
            [
              curlMinimal
              openssl
              pkg-config
              zstd
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              python3
              libx11
            ]
            ++ lib.optionals stdenv.hostPlatform.isDarwin [
              zlib
              nghttp2
              libgit2
            ];

          # What the checks before a hand-off call next to cargo: `typos`, and
          # nextest for `toolkit test --fast`.
          checkTools = with pkgs; [
            typos
            cargo-nextest
          ];

          # A toolchain with the components editors need, plus `args`.
          withDevExtensions =
            rust: args:
            rust.override (
              args
              // {
                extensions = [
                  "rust-src"
                  "rust-analyzer"
                ]
                ++ (args.extensions or [ ]);
              }
            );

          shell =
            rust: packages:
            pkgs.mkShell {
              packages = [
                rust
                (bindgenHook pkgs rust)
              ]
              ++ nativeDeps
              ++ packages;
            };
        in
        {
          # The pinned toolchain, the build dependencies of nushell and its
          # plugins, and the tools the hand-off checks need.
          default = shell (withDevExtensions (toolchain pkgs) { }) checkTools;

          # What `toolkit` and the scripts in this repo shell out to: the wasm
          # target for `toolkit build wasm`, llvm-tools and cargo-llvm-cov for
          # `toolkit cov`, and the tools behind CI's audit job, the ast-grep
          # rules and the virtualenv test. cargo-export, which the benchmark
          # commands call, is not in nixpkgs and still needs `cargo install`.
          full =
            shell
              (withDevExtensions (toolchain pkgs) {
                extensions = [ "llvm-tools" ];
                targets = [ "wasm32-unknown-unknown" ];
              })
              (
                checkTools
                ++ (with pkgs; [
                  ast-grep
                  cargo-audit
                  cargo-llvm-cov
                  hyperfine
                  python3Packages.virtualenv
                ])
              );

          # The latest stable toolchain, to try a bump of rust-toolchain.toml.
          latest = shell (withDevExtensions (rustBin pkgs).stable.latest.default { }) checkTools;
        }
      );
    };
}
