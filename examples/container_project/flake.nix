{
  description = "A development shell including host-proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    host-wrapper.url = "path:/host-wrapper";
  };

  outputs = { self, nixpkgs, host-wrapper }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              host-wrapper.packages.${system}.host-proxy
              # Some development tools as an example:
              pkgs.git
              pkgs.gnumake
              pkgs.gawk
            ];

            shellHook = ''
              # Configure the connection script path for the host-proxy binary
              export HOST_PROXY_SSH_SCRIPT="/project/host-proxy-ssh.sh"

              echo "========================================================="
              echo "Welcome to the host-wrapper proxy development container!"
              echo "========================================================="
              echo "The host-proxy binary is installed and available in PATH."
              echo ""
              echo "Try running:"
              echo "  host-proxy /usr/bin/uname"
              echo "========================================================="
            '';
          };
        }
      );
    };
}
