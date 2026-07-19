{
  description = "Host Wrapper Test Container Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, llm-agents }:
    let
      # Supported systems for the container (Linux)
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      
      # Helper to generate an attrset for each system
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          ai = pkgs.mkShell {
            name = "host-wrapper-shell";
            
            buildInputs = with pkgs; [
              # Build tools
              gcc
              gnumake
              
              # Runtime dependencies
              openssh
              coreutils
              bashInteractive

              # Ai agent(s)
              llm-agents.packages.${system}.opencode
              
              # Essential tools for the AI agent
              ripgrep
              git
              curl
              jq
              python3
              
              # Network Utilities
              iputils    # ping, arping, tracepath
              bind       # dig, nslookup
              netcat     # nc
              iproute2   # ip

              # Process Utilities
              procps     # ps, top, uptime
            ];

            shellHook = ''
              export PS1="\[\e[1;32m\][host-wrapper] \[\e[m\]\w \$ "
              echo "--- Host Wrapper Development Shell ---"
              echo "System: ${system}"
              echo "Tools loaded: gcc, gnumake, ssh, git, curl, jq, python3, net-utils, procps"
              echo "-------------------------------------------"
            '';
          };
          
          default = self.devShells.${system}.ai;
        }
      );
    };
}
