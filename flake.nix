{
  description = "build repro-metadata app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, ... }:
     flake-utils.lib.eachSystem [ flake-utils.lib.system.x86_64-linux flake-utils.lib.system.aarch64-linux ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        sqlFilter = path: _type: null != builtins.match ".*sql$" path;
        sqlOrCargo = path: type: (sqlFilter path type) || (craneLib.filterCargoSources path type);

        src = lib.cleanSourceWith {
          src = ./.;
          filter = sqlOrCargo;
          name = "source";
        };

        toolchain =  fenix.packages.${system}.complete.withComponents [
          "cargo"
          "rustc"
          "rust-src"
        ];

        craneLib = (crane.mkLib pkgs).overrideToolchain toolchain;

        commonArgs = {
            inherit src;
            strictDeps = true;

            # extraDummyScript = ''
            #   cp -r ${./migrations} --no-target-directory $out/migrations
            # '';

            nativeBuildInputs = [
              sqlxPrepared
              pkgs.pkg-config
            ];
          };

        cargoArtifacts = craneLib.buildDepsOnly {
            inherit src;
            strictDeps = true;
            nativeBuildInputs = [ pkgs.pkg-config ];
        };

        sqlxPrepared = pkgs.stdenv.mkDerivation {
            pname = "repro-metadata-cached-statements";
            version = self.packages.${system}.default.version;

            inherit src;
            inherit cargoArtifacts;

            nativeBuildInputs = [
              toolchain
              # inheritCargoArtifacts to try and get around the offline
              # like the idea was to give it the artifacts so it would go stop looking
              # for the metadata
              craneLib.inheritCargoArtifactsHook
              pkgs.zstd
              pkgs.sqlx-cli
              pkgs.postgresql

              # debug
              pkgs.lldb
            ];


            # this also fails:
            # cargo --verbose --frozen metadata
            # if lldb-server plattform --listen "*:1234" --server doesn't work then we can just disable the sandbox maybe but that then fucks wit reproducing the issue
            # just by running with sandbox doesn't fix the issue so we are good to lldb shit
            # also check metadata --format-version=1
            buildPhase = ''
              export DATABASE_URL="postgres:///postgres?host=$PWD"
              rm -rf postgres-data
              initdb postgres-data
              pg_ctl --pgdata=postgres-data --options "-c unix_socket_directories=$PWD" start
              sqlx database create
              sqlx migrate run

              type sqlx
              type cargo
              type cargo-sqlx

              ls -alh

              RUSTBACKTRACE=1 cargo --verbose --frozen sqlx prepare
            '';

            # not that needed but was nice in the more complex setup
            postBuild = ''
              sqlx database reset
              pg_ctl --pgdata=postgres-data --options "-c unix_socket_directories=$PWD" stop
              rm -rf postgres-data
            '';

            installPhase = ''
              cp -r .sqlx $out/.sqlx
            '';
        };

        repro-metadata = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          inherit src;
          nativeBuildInputs = (commonArgs.nativeBuildInputs or [ ]) ++ [
            sqlxPrepared
          ];

        });
      in
      {
        checks = {
          repro-metadata-doc = craneLib.cargoDoc (commonArgs // {
            cargoDocExtraArgs = "--no-deps --document-private-items --workspace";

            inherit cargoArtifacts;
          });
        };

        packages = {
          default = repro-metadata;
        };
      });
}
