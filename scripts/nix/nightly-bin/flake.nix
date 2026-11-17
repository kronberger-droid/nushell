{
  description = "Prebuilt nightly Nushell and plugins, from the release archives of nushell/nightly";

  # Only used for unpacking and patching, so `follows` of any recent nixpkgs
  # is fine.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Which nightly this is and where its archives are. Written by
      # ./update.nu; this flake is a template until that file exists.
      release =
        if builtins.pathExists ./nightly.json then
          lib.importJSON ./nightly.json
        else
          throw "nightly.json is missing: run `nu update.nu` in this directory first";

      build = pkgs: pkgs.callPackage ./package.nix { inherit release; };

      forEachSystem =
        f: lib.genAttrs (lib.attrNames release.systems) (system: f (import nixpkgs { inherit system; }));
    in
    {
      # Same output names as the flake in the root of nushell/nushell, which
      # builds from source, so a consumer switches between the two by changing
      # the input URL.
      overlays.default = final: previous: {
        inherit (build final) nushell;
        nushellPlugins = previous.nushellPlugins // (build final).plugins;
      };

      packages = forEachSystem (
        pkgs:
        let
          inherit (build pkgs) nushell plugins;
        in
        lib.mapAttrs' (name: lib.nameValuePair "nu_plugin_${name}") plugins
        // {
          inherit nushell;
          default = nushell;
          # nu and all the plugins in one profile entry. The plugins still have
          # to be registered with `plugin add`.
          full = pkgs.symlinkJoin {
            name = "nushell-full-${nushell.version}";
            paths = [ nushell ] ++ lib.attrValues plugins;
            inherit (nushell) passthru;
            meta = nushell.meta // {
              description = "Nushell with its plugins (prebuilt nightly ${release.tag})";
            };
          };
        }
      );

      legacyPackages = forEachSystem (pkgs: {
        nushellPlugins = (build pkgs).plugins;
      });
    };
}
