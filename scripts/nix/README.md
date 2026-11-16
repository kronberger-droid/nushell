# Nix Flake for Nushell

Placed in the `scripts/nix` directory to keep it nicely out of the root of the repo, but also allow
including and building with the latest sources. Due to it not being in the root most nix commands
will need to be told the location of the flake:

```console
$ nix run ./scripts/nix
$ nix build ./scripts/nix
$ nix flake check ./scripts/nix
$ nix flake update --flake ./scripts/nix
```

The flake builds with [crane](https://github.com/ipetkov/crane) (`crane.nix`), which compiles the
third-party dependencies in their own derivations. They only rebuild when `Cargo.toml` or
`Cargo.lock` change, so editing the sources recompiles just the workspace crates.

`nix flake check` runs the same fmt, clippy and test steps as CI, in the `ci` profile:

```console
$ nix build ./scripts/nix#checks.x86_64-linux.clippy
```

`default.nix` is the generic expression for use without flakes; see below.

## Including in another flake

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "...";
    nushell = {
      url = "github:nushell/nushell?dir=scripts/nix";
      inputs.nixpkgs.follows = "nixpkgs"; # optional
    };
  };

  outputs = inputs: {
    # ...
    # I would recommend using a `for-each-system` function of some kind here.
    packages.x86_64-linux = {
      nushell = inputs.nushell.packages.x86_64-linux.nushell;
    };
  }
}
```

### Adding the hash to `version`

The flake passes its own git revision as `NU_COMMIT_HASH`, so `version` shows
the commit the package was built from without any extra configuration.

## Using the Overlay

This flake also includes an overlay to allow using the new nushell and plugins
without modifying every instance of `nushell` in the configuration. This is a
more complex example than the one above, allowing multiple systems and showing
an example of a `nixosConfiguration` that uses the flakes `nushell`.

```nix
{
  outputs = inputs:
  let
      systems = [
        # List of systems to enable, for example:
        "x86_64-linux"
        "aarch64-darwin"
      ];
      # And for packages or other system-specific inputs, use a function that
      # overlays overlays set during the nixpkgs import:
      forEachSystem =
        f:
        inputs.nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ inputs.nixpkgs.overlays.default ];
            }
          }
        );
  in
  {
    packages = forEachSystem ({pkgs, ...}: {inherit nushell;});
    # For a nixos configuration, add it to the `nixpkgs.overlays`. If a nixos
    # configuration is all that is required, this is the only part needed
    nixosConfiguration.yourHost = inputs.nixpkgs.lib.nixosSystem {
      system = "...";
      modules = [
        {
          nixpkgs.overlays = [
            inputs.nushell.overlays.default
          ];
        }
        ./configuration.nix
        # ... other modules
      ];
    };
  };
}
```

## Using Without Flakes

The package can be built using the `scripts/nix/default.nix` file:

```nix
let
  pkgs = import <nixpkgs> { };
in
{
  nushell = pkgs.callPackage ./scripts/nix { };
}
```
