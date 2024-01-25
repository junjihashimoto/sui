{
  nixConfig = {
    bash-prompt = "\[sui(__git_ps1 \" (%s)\")\]$ ";
  };
  inputs = {
    #nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:junjihashimoto/nixpkgs?rev=8c2abbaad6456d7a3c9752bfc2caf4d982427100";
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
        myCargo = with pkgs; rustPlatform.buildRustPackage rec {
          pname = "cargo";
          version = "672451826a1a7f8a1a16b00bbf164feba1cb171d";
          buildInputs = [
            openssl curl zlib nghttp2 iconv
          ];
          GIT_REVISION="devnet-v1.16.0-188-gb5a95a94d0-dirty";
          src = fetchFromGitHub {
            owner = "junjihashimoto";
            repo = pname;
            rev = version;
            hash = "sha256-INYYcp2U1q3X1MZGA/xylhmNTZoXNWdj/NbIqkgG1fY=";
          };
          cargoHash = "sha256-+yDaffZ7C6GE1LJLrMNZfaDJiXin2FpVc/aJ30Jy+kU=";
          doCheck = false;
        };
        myRustPlatform = pkgs.makeRustPlatform (pkgs.rustPackages.buildRustPackages // {cargo = myCargo;});
        sui = with pkgs; rustPlatform.buildRustPackage rec {
          pname = "sui";
          version = "0.0.1";
          buildInputs = [
            myCargo openssl curl zlib nghttp2 iconv postgresql.lib
          ];
          src = ./.;
          env = lib.optionalAttrs stdenv.cc.isClang {
            NIX_LDFLAGS = "-l${stdenv.cc.libcxx.cxxabi.libName}";
          };
          cargoLock = {
            lockFile = ./Cargo.lock;
            outputHashes = {
              "anemo-0.0.0" = "sha256-HSRwZOJvgLy1y0xUZK6y6+FEWeipzYAMYVrrCoYDSsU=";
              "async-task-4.3.0" = "sha256-zMTWeeW6yXikZlF94w9I93O3oyZYHGQDwyNTyHUqH8g=";
              "datatest-stable-0.1.3" = "sha256-VAdrD5qh6OfabMUlmiBNsVrUDAecwRmnElmkYzba+H0=";
              "fastcrypto-0.1.7" = "sha256-bdxpeKr17kEVa4mLAmLB+INPA4sbvizRNfIDEKKNaDc=";
              "json_to_table-0.6.0" = "sha256-UKMTa/9WZgM58ChkvQWs1iKWTs8qk71gG+Q/U/4D4x4=";
              "jsonrpsee-0.16.2" = "sha256-PvuoB3iepY4CLUm9C1EQ07YjFFgzhCmLL1Iix8Wwlns=";
              "minibytes-0.1.0" = "sha256-AUBFdOUzzZSyhT0lDO/+K2slf3s9DEw+EiHYeL/eixE=";
              "msim-0.1.0" = "sha256-kkt3eU9Db/o7sEVlvkx+yZPj/pF9nEHe8PL281avu2o=";
              "nexlint-0.1.0" = "sha256-8UM1vRV+2mvx/4+qFgnsqzKkJgeg0mH1gX6iFYtHAAY=";
              "prometheus-parse-0.2.3" = "sha256-TGiTdewA9uMJ3C+tB+KQJICRW3dSVI0Xcf3YQMfUo6Q=";
              "real_tokio-1.28.1" = "sha256-ZKM7tQY8vtLRgu4l416JiyREdOw1+hKiFP6qpGVXEy0=";
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
