{
  description = "Yin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
      nativeBuildInputs = with pkgs; [
        meson
        ninja
        pkg-config
        cmake
        wayland
        ffmpeg
        libglvnd
        libva
        wayland-scanner
        wayland-protocols
      ];
      # Runtime
      libs = with pkgs; [
        wayland
        ffmpeg
        mesa
        libva
        libglvnd
        libva
        # egl-wayland2
      ];

      yin = pkgs.stdenv.mkDerivation {
        pname = "yin";
        version = "0.1.0";

        src = ./.;

        inherit nativeBuildInputs;

        buildInputs = libs;

        enableParallelBuilding = true;
      };
    in {
      checks = {
        inherit yin;
      };

      packages.default = yin;

      apps.default = flake-utils.lib.mkApp {
        drv = yin;
      };

      devShells.default = pkgs.mkShell {
        packages =
          nativeBuildInputs
          ++ libs;
      };
    });
}
