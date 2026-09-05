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
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          dockerStream = pkgs.dockerTools.streamLayeredImage {
            name = "example-container";
            tag = "latest";
            contents = [
              host-wrapper.packages.${system}.host-proxy
              pkgs.git
              pkgs.gnumake
              pkgs.gawk
              pkgs.bashInteractive
              pkgs.coreutils
              pkgs.openssh
              pkgs.iproute2
              pkgs.dockerTools.fakeNss
            ];
            config = {
              Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
              Env = [
                "PATH=/bin"
                "HOST_PROXY_SSH_SCRIPT=/project/host-proxy-ssh.sh"
              ];
              WorkingDir = "/project";
            };
          };

          ociImage = pkgs.runCommand "example-container.tar" {
            nativeBuildInputs = [ pkgs.skopeo ];
          } ''
            ${dockerStream} > docker.tar
            skopeo copy --insecure-policy docker-archive:docker.tar oci-archive:$out:example-container:latest
          '';
        in
        {
          docker-stream = dockerStream;
          oci-image = ociImage;
          default = ociImage;
        }
      );

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
