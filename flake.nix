{
  description = "Host wrapper and proxy development packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          host-proxy = pkgs.stdenv.mkDerivation {
            pname = "host-proxy";
            version = "1.0.0";
            src = ./.;

            # Ensure any pre-compiled macOS host binary is cleaned out so we build from scratch
            preBuild = ''
              make clean
            '';

            # Nix automatically executes `make host-proxy` in the buildPhase
            buildFlags = [ "host-proxy" ];

            installPhase = ''
              mkdir -p $out/bin
              cp host-proxy $out/bin/
            '';
          };

          host-wrapper = pkgs.stdenv.mkDerivation {
            pname = "host-wrapper";
            version = "1.0.0";
            src = ./.;

            # Ensure any pre-compiled macOS host binary is cleaned out so we build from scratch
            preBuild = ''
              make clean
            '';

            # Nix automatically executes `make host-wrapper` in the buildPhase
            buildFlags = [ "host-wrapper" ];

            installPhase = ''
              mkdir -p $out/bin
              cp host-wrapper $out/bin/
            '';
          };

          default = self.packages.${system}.host-proxy;
        }
      );
    };
}
