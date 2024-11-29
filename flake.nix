{
  nixConfig = {
    bash-prompt = "\[sui(__git_ps1 \" (%s)\")\]$ ";
  };
  inputs = {
    #nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:junjihashimoto/nixpkgs?rev=484897f5b7e6070d4e5a94e3b25f28b206db0641";
    #nixpkgs.url = "git+file:///home/junji-hashimoto/git/nixpkgs?rev=484897f5b7e6070d4e5a94e3b25f28b206db0641";
    utils.url = "github:numtide/flake-utils";
  };
  inputs.flake-compat = {
    url = "github:edolstra/flake-compat";
    flake = false;
  };

  outputs = { self, nixpkgs, utils, flake-compat  }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {inherit system;};
        sui = with pkgs; rustPlatform.buildRustPackage rec {
          pname = "sui";
          version = "0.0.1";
          buildInputs = [
            cargo openssl curl zlib nghttp2 iconv postgresql.lib
            rustPlatform.bindgenHook
          ];
          src = ./.;
          GIT_REVISION="a9aa5a925b0298d40d456870278cd405fe12bf0a";
          LIBCLANG_PATH="${llvmPackages.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS="-isystem ${llvmPackages.libclang.lib}/lib/clang/${lib.getVersion clang}/include";

          env = lib.optionalAttrs stdenv.cc.isClang {
            NIX_LDFLAGS = "-l${stdenv.cc.libcxx.cxxabi.libName}";
          };
          cargoLock = {
            lockFile = ./Cargo.lock;
            outputHashes = {
              "anemo-0.0.0" = "sha256-kZaw7j2O4PoMEtJ0TfTV1z8VYw3IgKivEFoqKT4YXGE=";
              "async-task-4.3.0" = "sha256-zMTWeeW6yXikZlF94w9I93O3oyZYHGQDwyNTyHUqH8g=";
              "axum-server-0.6.1" = "sha256-sJLPtFIJAeO6e6he7r9yJOExo8ANS5+tf3IIUkZQXoA=";
              "datatest-stable-0.1.3" = "sha256-VAdrD5qh6OfabMUlmiBNsVrUDAecwRmnElmkYzba+H0=";
              "fastcrypto-0.1.8" = "sha256-SL7Qf8yf466t+86yG4MwL9ni4VcRWxnLpEZe11GTp0o=";
              "json_to_table-0.6.0" = "sha256-UKMTa/9WZgM58ChkvQWs1iKWTs8qk71gG+Q/U/4D4x4=";
              "jsonrpsee-0.16.2" = "sha256-PvuoB3iepY4CLUm9C1EQ07YjFFgzhCmLL1Iix8Wwlns=";
              # "minibytes-0.1.0" = "sha256-AUBFdOUzzZSyhT0lDO/+K2slf3s9DEw+EiHYeL/eixE=";
              "msim-0.1.0" = "sha256-J2GoKU5cW8pIjtcbvmFxnIt74hFWcNUsA692nl6SPG8=";
              "nexlint-0.1.0" = "sha256-L9vf+djTKmcz32IhJoBqAghQ8mS3sc9I2C3BBDdUxkQ=";
              "openapiv3-2.0.0" = "sha256-/j2qjyfBYCz6pjcaY6TzB6zDnoxVdxTkZp6rFI2QsUk=";
              "prometheus-parse-0.2.3" = "sha256-TGiTdewA9uMJ3C+tB+KQJICRW3dSVI0Xcf3YQMfUo6Q=";
              "real_tokio-1.38.1" = "sha256-PoH2DkAGuu51YcUjp3QdeYzjjW0vHlK6weEaKiRjQBo=";
              "sui-sdk-types-0.0.1" = "sha256-pVqqDAVCyP1OHnDGnc4n0YhzIET9MOGOl/1Fujbscnk=";
            };
          };
          doCheck = false;
        };
      in
      {
        defaultPackage = sui;
        devShell = with pkgs; mkShell {
          buildInputs = [
            git
            myCargo
          ];
          shellHook = ''
            source ${git}/share/bash-completion/completions/git-prompt.sh
          '';
        };
      });
}
