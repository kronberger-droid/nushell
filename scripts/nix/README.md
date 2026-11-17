# Nix Flake for Nushell

`flake.nix` and `flake.lock` are in the root of the repo, so the usual commands work without a path:

```console
$ nix run
$ nix build
$ nix develop
$ nix flake check
$ nix run github:nushell/nushell/<rev or branch>
```

The expressions the flake calls live here in `scripts/nix`:

- `crane.nix` builds nushell, its plugins and the CI checks with
  [crane](https://github.com/ipetkov/crane). Crane compiles the third-party dependencies in their
  own derivations. They only rebuild when `Cargo.toml` or `Cargo.lock` change, so editing the
  sources recompiles just the workspace crates.
- `default.nix` is the generic expression for use without flakes; see below.

## Outputs

| Output | What it is |
| --- | --- |
| `packages.<system>.default`, `.nushell` | `nu`, built with the toolchain from `rust-toolchain.toml` |
| `packages.<system>.nu_plugin_<name>` | One plugin: `formats`, `gstat`, `inc`, `polars`, `query` |
| `packages.<system>.full` | `nu` and all the plugins in one package |
| `packages.<system>.dev` | `nu` in the `dev` cargo profile |
| `legacyPackages.<system>.nushellPlugins` | The plugins as a set, like nixpkgs' `nushellPlugins` |
| `overlays.default` | Replaces `nushell` and the in-tree `nushellPlugins` in a package set |
| `checks.<system>` | `fmt`, `clippy`, `test`, `typos`, `nixfmt` |
| `devShells.<system>` | `default`, `full`, `latest` |
| `formatter.<system>` | `nix fmt` for the Nix files |

The package does not run the tests; they are a check. The flake passes its own git revision as
`NU_COMMIT_HASH`, so `version` shows the commit the package was built from.

## Dev shells

```console
$ nix develop          # default
$ nix develop .#full
```

- `default` has the pinned toolchain with rust-analyzer, the libraries nushell and its plugins
  link, `typos` and `cargo-nextest`. That covers `cargo fmt`, `cargo nuclippy`, `typos` and
  `toolkit test --fast`.
- `full` adds what the rest of `toolkit` and the scripts call: the `wasm32-unknown-unknown` target
  for `toolkit build wasm`, `cargo-llvm-cov` for `toolkit cov`, `cargo-audit`, `ast-grep`,
  `virtualenv` and `hyperfine`. `cargo-export`, which the benchmark commands use, is not in nixpkgs
  and still needs `cargo install cargo-export`.
- `latest` has the latest stable toolchain instead of the pinned one, to try a toolchain bump.

With direnv, a `.envrc` containing `use flake .#full` loads the shell on `cd`.

## Checks

`nix flake check` runs the same fmt, clippy and test steps as CI, in the `ci` profile, plus the
spell check and a format check of the Nix files. One at a time:

```console
$ nix build .#checks.x86_64-linux.clippy
```

The clippy check reads its lint flags from the `nuclippy` alias in `.cargo/config.toml`.

## Including in another flake

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "...";
    nushell = {
      url = "github:nushell/nushell";
      # Build against your nixpkgs instead of the one locked here.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

### Using the overlay

The overlay is the way to use the flake from a NixOS or home-manager configuration. It replaces
`pkgs.nushell` and the in-tree plugins in `pkgs.nushellPlugins` everywhere at once, it builds
inside your own package set, and it is the only output that works when that set cross-compiles.
It needs no other overlay next to it.

```nix
{
  nixpkgs.overlays = [ inputs.nushell.overlays.default ];

  # NixOS: nu as a login shell
  users.users.you.shell = pkgs.nushell;

  # home-manager: its own module takes the package and registers the plugins
  programs.nushell = {
    enable = true;
    plugins = with pkgs.nushellPlugins; [ polars query ];
  };
}
```

Without the overlay, the same packages are `inputs.nushell.packages.<system>.default` and
`inputs.nushell.legacyPackages.<system>.nushellPlugins`.

### Building another revision, or with another toolchain

The overlay also adds `pkgs.nushellCrane`, the result of `crane.nix`, which takes `.override`:

```nix
# Another source tree, built with this flake's expression. Useful for a
# revision from before the flake existed, or a fork without it.
(pkgs.nushellCrane.override { nushellSrc = inputs.other-nushell.outPath; }).nushell

# nixpkgs' own rustc instead of the pinned toolchain
(pkgs.nushellCrane.override { craneLib = inputs.crane.mkLib pkgs; }).nushell
```

To run a specific revision that has the flake, point the input at it. Inside a configuration that
is `--override-input nushell github:nushell/nushell/<rev>`. Because the dependency build only
depends on `Cargo.lock`, the toolchain and nixpkgs, it is reused between revisions that share them.

## Using without flakes

The package can be built using the `scripts/nix/default.nix` file:

```nix
let
  pkgs = import <nixpkgs> { };
in
{
  nushell = pkgs.callPackage ./scripts/nix { };
}
```

## Keeping it working

- When `rust-toolchain.toml` moves to a newer Rust, run `nix flake update rust-overlay`. The
  locked rust-overlay only knows the releases that existed when it was locked.
- A new plugin crate, or a new native dependency of one, goes into the `plugins` set in
  `crane.nix`.
- A new top-level directory that the build reads goes into the file list in `crane.nix`.
