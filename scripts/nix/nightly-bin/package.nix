# Nushell and its plugins from a prebuilt nightly release archive.
#
# Nothing is compiled: each package unpacks the archive for the host platform
# and installs one binary from it. On Linux the archives are the glibc builds,
# patched to run from the Nix store.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  # The contents of nightly.json, as written by ./update.nu.
  release,
}:
let
  inherit (stdenv.hostPlatform) system;

  src = fetchurl {
    inherit
      (release.systems.${system}
        or (throw "nushell nightly ${release.tag} has no prebuilt archive for ${system}")
      )
      url
      sha256
      ;
  };

  # The plugins worth installing. The archive also carries three that only
  # exist to test the plugin system: example, custom_values, stress_internals.
  pluginNames = [
    "formats"
    "gstat"
    "inc"
    "polars"
    "query"
  ];

  # One binary out of the archive, as a package of its own.
  package =
    {
      pname,
      description,
      extraAttrs ? { },
    }:
    stdenv.mkDerivation (
      {
        inherit pname src;
        inherit (release) version;

        nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
        # What the glibc builds link dynamically besides glibc itself.
        buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
          zlib
          stdenv.cc.cc.lib
        ];

        installPhase = ''
          runHook preInstall
          install -Dm755 ${pname} $out/bin/${pname}
          install -Dm644 LICENSE $out/share/licenses/${pname}/LICENSE
          runHook postInstall
        '';

        # The archives are stripped already, and stripping again would break
        # the code signature of the macOS binaries.
        dontStrip = true;

        meta = {
          inherit description;
          homepage = "https://www.nushell.sh/";
          license = lib.licenses.mit;
          mainProgram = pname;
          platforms = lib.attrNames release.systems;
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };
      }
      // extraAttrs
    );

  nushell = package {
    pname = "nu";
    description = "A new type of shell (prebuilt nightly ${release.tag})";
    # Lets NixOS accept it as a login shell.
    extraAttrs.passthru.shellPath = "/bin/nu";
  };

  plugins = lib.genAttrs pluginNames (
    name:
    package {
      pname = "nu_plugin_${name}";
      description = "Nushell ${name} plugin (prebuilt nightly ${release.tag})";
    }
  );
in
{
  inherit nushell plugins;
}
