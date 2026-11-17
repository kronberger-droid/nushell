# Incremental builds of nushell, its plugins and the CI checks, using crane.
#
# Unlike `default.nix`, which builds everything in one `buildRustPackage`
# derivation, crane splits the third-party dependencies into their own
# derivations. Those only rebuild when Cargo.toml or Cargo.lock change, so a
# source edit recompiles the workspace crates and nothing else, and a binary
# cache can serve the dependency builds across commits.
#
# `default.nix` stays the generic, nixpkgs-style expression for non-flake use.
{
  lib,
  stdenv,
  craneLib,
  bindgenHook,
  pkg-config,
  openssl,
  curlMinimal,
  python3,
  libx11,
  nghttp2,
  libgit2,
  sqlite,
  zstd,
  zlib,
  # The nushell source tree. Defaults to the checkout this file is in; pass
  # another one, such as a flake input, to build that with this expression.
  nushellSrc ? ../..,
  # Written into `version` output; the flake passes its own git revision.
  commitHash ? null,
  # Cargo profile for the packages. The checks always use `ci`, like CI.
  profile ? "release",
}:
let
  cargoToml = lib.importTOML (nushellSrc + "/Cargo.toml");

  # The lint flags of the `nuclippy` cargo alias, i.e. what follows its `--`.
  # Read from the alias so the clippy check cannot drift from what CI runs.
  clippyLints = lib.last (
    lib.splitString " -- " (lib.importTOML (nushellSrc + "/.cargo/config.toml")).alias.nuclippy
  );

  # A local checkout is filtered down to what the build reads, so editing the
  # Nix files or docs does not rebuild anything. A flake input arrives as a
  # store path string, which lib.fileset cannot filter; it is used as is.
  src =
    if builtins.isPath nushellSrc then
      lib.fileset.toSource {
        root = nushellSrc;
        fileset = lib.fileset.difference (lib.fileset.unions (
          map (p: nushellSrc + p) [
            /Cargo.toml
            /Cargo.lock
            /.cargo
            /src
            /crates
            /tests
            /assets
            /benches
            /toolkit
            /scripts
          ]
        )) (nushellSrc + /scripts/nix);
      }
    else
      nushellSrc;

  commonArgs = {
    inherit src;
    pname = "nushell";
    inherit (cargoToml.workspace.package) version;
    strictDeps = true;

    nativeBuildInputs = [
      pkg-config
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ python3 ]
    ++ lib.optionals stdenv.cc.isClang [ bindgenHook ];

    # libgit2 and sqlite are linked from the system instead of their bundled
    # copies, as nixpkgs' own nushell package does.
    buildInputs = [
      zstd
      libgit2
      sqlite
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ libx11 ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      zlib
      nghttp2
    ];

    env = {
      LIBGIT2_NO_VENDOR = 1;
      LIBSQLITE3_SYS_USE_PKG_CONFIG = 1;
    };
  };

  # Plugins built from this workspace, with their extra system dependencies.
  plugins = {
    formats = { };
    gstat.buildInputs = [ openssl ];
    inc = { };
    polars.buildInputs = [ openssl ];
    query.buildInputs = [
      openssl
      curlMinimal
    ];
  };
  pluginPackages = lib.concatMapStringsSep " " (name: "-p nu_plugin_${name}") (lib.attrNames plugins);
  pluginBuildInputs = lib.unique (lib.concatMap (p: p.buildInputs or [ ]) (lib.attrValues plugins));

  # Dependency builds for the packages. These skip `cargo check` and the test
  # build, which only the checks need. nu and the plugins get separate ones
  # so that building nu alone does not compile polars.
  depsOnly =
    args:
    craneLib.buildDepsOnly (
      commonArgs
      // {
        CARGO_PROFILE = profile;
        cargoCheckCommand = "true";
        doCheck = false;
      }
      // args
    );
  nuDeps = depsOnly { };
  pluginDeps = depsOnly {
    pname = "nushell-plugins";
    cargoExtraArgs = "--locked ${pluginPackages}";
    buildInputs = commonArgs.buildInputs ++ pluginBuildInputs;
  };

  # Tests run in `checks`, against the `ci` profile, not in the packages.
  package =
    args:
    craneLib.buildPackage (
      commonArgs
      // {
        CARGO_PROFILE = profile;
        doCheck = false;
      }
      // args
    );

  nushell = package {
    cargoArtifacts = nuDeps;
    # Set here and not in commonArgs: it changes with every commit, and in the
    # dependency builds it would invalidate them every time.
    env = commonArgs.env // lib.optionalAttrs (commitHash != null) { NU_COMMIT_HASH = commitHash; };
    passthru.shellPath = "/bin/nu";
    meta = {
      inherit (cargoToml.package) description homepage;
      license = lib.licenses.mit;
      mainProgram = "nu";
    };
  };

  pluginDrvs = lib.mapAttrs (
    name: extra:
    package {
      pname = "nu_plugin_${name}";
      cargoArtifacts = pluginDeps;
      cargoExtraArgs = "--locked -p nu_plugin_${name}";
      buildInputs = commonArgs.buildInputs ++ (extra.buildInputs or [ ]);
      meta = {
        license = lib.licenses.mit;
        mainProgram = "nu_plugin_${name}";
      };
    }
  ) plugins;

  # The checks build the whole workspace in CI's `ci` profile, so they share
  # one dependency build that includes dev-dependencies and the plugins.
  ciArgs = commonArgs // {
    CARGO_PROFILE = "ci";
    buildInputs = commonArgs.buildInputs ++ pluginBuildInputs;
  };
  ciDeps = craneLib.buildDepsOnly (
    ciArgs
    // {
      cargoExtraArgs = "--locked --workspace";
    }
  );

  checks = {
    fmt = craneLib.cargoFmt { inherit src; };

    # The `nuclippy` alias in .cargo/config.toml, with its lint flags taken
    # from there.
    clippy = craneLib.cargoClippy (
      ciArgs
      // {
        cargoArtifacts = ciDeps;
        cargoExtraArgs = "--locked --workspace --exclude 'nu_plugin_*'";
        cargoClippyExtraArgs = "--all-targets -- ${clippyLints}";
      }
    );

    test = craneLib.cargoTest (
      ciArgs
      // {
        cargoArtifacts = ciDeps;
        cargoExtraArgs = "--locked --workspace";
        cargoTestExtraArgs = "--all-targets";
        # Builds the plugins for the tests using the right profile, otherwise
        # the plugins cannot be found.
        NUSHELL_CARGO_PROFILE = "ci";
        NU_TEST_LOCALE_OVERRIDE = "en_US.UTF-8";
        preCheck = ''
          export HOME=$(mktemp -d)
        '';
      }
    );
  };
in
{
  inherit nushell checks;
  plugins = pluginDrvs;
}
