{
  inputs = {
    fenix = {
#      url = "github:nix-community/fenix";
      url = "github:junjihashimoto/fenix?rev=505c418b5114642be08180a525401a28f63f7a47";
#      url = "git+file:///home/junji-hashimoto/git/fenix?rev=505c418b5114642be08180a525401a28f63f7a47";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    #nixpkgs.url = "nixpkgs/nixos-24.11";
    # nixpkgs.url = "github:junjihashimoto/nixpkgs?ref=feature/rust-dup";
    # nixpkgs.url = "github:junjihashimoto/nixpkgs?ref=feature/nix-fetch-cargo";
    nixpkgs.url = "github:junjihashimoto/nixpkgs?rev=dda5ad6feb59b4208cc5c4d70426378b882d5110";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, fenix, flake-utils, nixpkgs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        #toolchain = fenix.packages.${system}.default.toolchain;
        toolchain = fenix.packages.${system}.fromToolchainFile {
          file = ./rust-toolchain.toml;
          sha256 = "sha256-3jVIIf5XPnUU1CRaTyAiO0XHVbJl12MSx3eucTXCjtE=";
        };
        pkgs = nixpkgs.legacyPackages.${system};
        suiVersion = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package.version;
      in
      let
        lib = pkgs.lib;
        stdenv = pkgs.stdenv;
        platform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
        };
        nativeBuildInputs = with pkgs; [ 
          git 
          pkg-config
          rustPlatform.bindgenHook
        ];
      in let
        # builts a sui rust crate
        mkCrate = subpath: extraDeps: (platform.buildRustPackage rec {
            pname = "sui";
            version = suiVersion;
            inherit nativeBuildInputs;

            # src = if (!builtins.isNull subpath) then ./crates/${subpath} else ./.;
            src = ./.;

            # buildAndTestSubdir = if (!builtins.isNull subpath) then ./crates/${subpath} else null;

            cargoLock = {
              lockFile = ./Cargo.lock;
              outputHashes = {
                "anemo-0.0.0" = "sha256-kZaw7j2O4PoMEtJ0TfTV1z8VYw3IgKivEFoqKT4YXGE=";
                "async-task-4.3.0" = "sha256-zMTWeeW6yXikZlF94w9I93O3oyZYHGQDwyNTyHUqH8g=";
                "axum-server-0.6.1" = "sha256-sJLPtFIJAeO6e6he7r9yJOExo8ANS5+tf3IIUkZQXoA=";
                "datatest-stable-0.1.3" = "sha256-VAdrD5qh6OfabMUlmiBNsVrUDAecwRmnElmkYzba+H0=";
                "fastcrypto-0.1.8" = "sha256-ytSD7Ecv1j5p06jSMqnd+eae0OU9iRZ9Cx7QII8WJJ0=";
                "json_to_table-0.6.0" = "sha256-UKMTa/9WZgM58ChkvQWs1iKWTs8qk71gG+Q/U/4D4x4=";
                "jsonrpsee-0.16.2" = "sha256-PvuoB3iepY4CLUm9C1EQ07YjFFgzhCmLL1Iix8Wwlns=";
                "msim-0.1.0" = "sha256-mXAN7JI4VRifWi8boqC5fdVa1wjaL4hFH9VhJ7jM52c=";
                "nexlint-0.1.0" = "sha256-L9vf+djTKmcz32IhJoBqAghQ8mS3sc9I2C3BBDdUxkQ=";
                "openapiv3-2.0.0" = "sha256-/j2qjyfBYCz6pjcaY6TzB6zDnoxVdxTkZp6rFI2QsUk=";
                "prometheus-parse-0.2.3" = "sha256-TGiTdewA9uMJ3C+tB+KQJICRW3dSVI0Xcf3YQMfUo6Q=";
                "real_tokio-1.36.0" = "sha256-q5jIRO3BGJVZtq3sagGFvLgL/u7dmz5yukwqFEuX3fc=";
                "sui-sdk-0.0.0" = "sha256-qwXpmU5Ci1hVzlpwP2Iyjet1nmvVCxBXBVuAmVEL69c=";
              };
            };

            # nativeBuildInputs = with pkgs; [
            #   protobuf
            #   # clang
              
            # ];
            #LIBCLANG_PATH="${llvmPackages.libclang.lib}/lib";
            #BINDGEN_EXTRA_CLANG_ARGS="-isystem ${llvmPackages.libclang.lib}/lib/clang/${lib.getVersion clang}/include";

            buildInputs = with pkgs; [
              bzip2
              zstd
              clang
              rustPlatform.bindgenHook
              #toolchain.bindgenHook
              # glibc.dev
              # libcxx.dev
            ] ++ lib.optionals stdenv.isDarwin [
              darwin.apple_sdk.frameworks.CoreFoundation
              darwin.apple_sdk.frameworks.CoreServices
              darwin.apple_sdk.frameworks.IOKit
              darwin.apple_sdk.frameworks.Security
              darwin.apple_sdk.frameworks.SystemConfiguration
            ] ++ (if builtins.isList(extraDeps) then extraDeps else []);

            preBuild = ''
            #   # From: https://github.com/NixOS/nixpkgs/blob/1fab95f5190d087e66a3502481e34e15d62090aa/pkgs/applications/networking/browsers/firefox/common.nix#L247-L253
            #   # Set C flags for Rust's bindgen program. Unlike ordinary C
            #   # compilation, bindgen does not invoke $CC directly. Instead it
            #   # uses LLVM's libclang. To make sure all necessary flags are
            #   # included we need to look in a few places.
            #   export BINDGEN_EXTRA_CLANG_ARGS="$(< ${stdenv.cc}/nix-support/libc-crt1-cflags) \
            #     $(< ${stdenv.cc}/nix-support/libc-cflags) \
            #     $(< ${stdenv.cc}/nix-support/cc-cflags) \
            #     $(< ${stdenv.cc}/nix-support/libcxx-cxxflags) \
            #     ${lib.optionalString stdenv.cc.isClang "-idirafter ${stdenv.cc.cc}/lib/clang/${lib.getVersion stdenv.cc.cc}/include"} \
            #     ${lib.optionalString stdenv.cc.isGNU "-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc} -isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}/${stdenv.hostPlatform.config}"}
            #   "
            export GIT_REVISION="$(git rev-parse HEAD)";
            '';

            # 
            #doCheck = false;
            # buildType = "debug";

              checkFlags = builtins.map (x: "--skip=" + x) [
                # no network in building sandbox
                "network::connection_monitor::tests::test_connectivity"
                "connectivity::tests::test_connectivity"
                "primary_node_restart"
                "simple_primary_worker_node_start_stop"
                "consensus::state::consensus_tests::test_consensus_recovery_with_bullshark"
                "primary::primary_tests::test_get_network_peers_from_admin_server"
                "proposer_store::test::test_writes"
              ];
            doCheck = false;

            env = {
              ROCKSDB_INCLUDE_DIR = "${pkgs.rocksdb_8_3}/include";
              ROCKSDB_LIB_DIR = "${pkgs.rocksdb_8_3}/lib";
              ZSTD_SYS_USE_PKG_CONFIG = true;
              # Includes normal include path
              # BINDGEN_EXTRA_CLANG_ARGS = lib.strings.makeSearchPath "" (builtins.map (a: ''-I"${a}/include"'') [
              #   # add dev libraries here (e.g. pkgs.libvmi.dev)
              #   pkgs.glibc.dev
              # ]);
            };

            passthru = {
              rocksdb = pkgs.rocksdb_8_3;
            };

            outputs = ["out"];

            meta = with pkgs.lib; {
              description = "Sui, a next-generation smart contract platform with high throughput, low latency, and an asset-oriented programming model powered by the Move programming language";
              homepage = "https://github.com/mystenLabs/sui";
              changelog = "https://github.com/mystenLabs/sui/blob/${src.rev}/RELEASES.md";
              license = with licenses; [ cc-by-40 asl20 ];
              maintainers = with maintainers; [ ];
              mainProgram = "sui";
            };
          });
      in
      {
        devShells.default = pkgs.mkShell
          {
            inherit nativeBuildInputs;
            RUST_SRC_PATH = "${fenix.packages.${system}.stable.rust-src}/bin/rust-lib/src";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath nativeBuildInputs;
            LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
            NIX_LDFLAGS = "${pkgs.lib.optionalString pkgs.stdenv.isDarwin "\
            -F${pkgs.darwin.apple_sdk.frameworks.Security}/Library/Frameworks -framework Security \
            -F${pkgs.darwin.apple_sdk.frameworks.CoreFoundation}/Library/Frameworks -framework CoreFoundation"}";
            # BINDGEN_EXTRA_CLANG_ARGS = (builtins.map (a: ''-I"${a}/include"'') [
            #   # Includes normal include pat
            #   # add dev libraries here (e.g. pkgs.libvmi.dev)
            #   # pkgs.glibc.dev
            #   # pkgs.libcxx.dev
            #   # pkgs.clang.dev
            # ]);
            buildInputs = [ toolchain ] ++ (with pkgs; [
              #(fenix.packages."${system}".stable.withComponents [ "clippy" "rustfmt" ])
              just
              python3
              pnpm
              nodePackages.webpack
              typescript
              turbo
              #docker-compose
              # setting LIBCLANG_PATH manually breaks globally installed `ssh` binary and transitively breaks git
              # so we use a local version of `ssh` in this dev env (maybe there is a better way to fix it)
              # openssh
            ]);
          };
        packages.default = pkgs.hello;
        packages.sui-full = mkCrate null [pkgs.postgresql];
        packages.sui-indexer = mkCrate "sui-indexer" [pkgs.postgresql];
        packages.sui-light-client = mkCrate "sui-light-client" [];
          
      });
}
