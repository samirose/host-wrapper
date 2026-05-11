#!/usr/bin/env bash

# Configuration
PROJECT_DIR=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")
OPENCODE_SETTINGS_DIR="$HOME/.local/share/opencode"
IMAGE="ghcr.io/nixos/nix"
NIX_STORE_VOLUME="nix-store-$PROJECT_NAME"
NIX_USER_CACHE="$PROJECT_DIR/.cache/nix-user/root"

mkdir -p "$NIX_USER_CACHE" "$OPENCODE_SETTINGS_DIR"

# Reset Nix store option
if [[ "$1" == "--reset" ]]; then
    echo "Resetting Nix store volume $NIX_STORE_VOLUME..."
    container volume rm "$NIX_STORE_VOLUME"
    echo "Resetting local Nix user cache $NIX_USER_CACHE..."
    rm -rf "$NIX_USER_CACHE"
    exit 0
fi

# Confirmation to proceed with the container startup
echo "----------------------------------------------------"
echo "TARGET DIRECTORY: $PROJECT_DIR"
echo "----------------------------------------------------"
read -p "Are you sure you want to run OpenCode with Nix here? (y/n): " confirm
if [[ $confirm != [yY] ]]; then
    echo "Aborting."
    exit 1
fi

container system start

# Check that the Nix volume is populated
container run --rm \
  --volume "$NIX_STORE_VOLUME:/mnt/nix_target" \
  "$IMAGE" \
   sh -c '
    if [ ! -d "/mnt/nix_target/store" ] || [ ! -d "/mnt/nix_target/var/nix" ]; then
      echo "Setting up Nix store volume"
      cp -a /nix/. /mnt/nix_target/
    fi
  '

# Run session
GEMINI_API_KEY="$(security find-generic-password -a "$USER" -s "gemini-api-key" -w)"

# Detect Host IP (primary interface)
HOST_IP="$(ipconfig getifaddr "$(route get default | grep interface | awk '{print $2}')")"
HOST_USER="$USER"

echo "Detected Host: $HOST_USER@$HOST_IP"

container run -it --rm \
  --name "opencode-nix-session-$(date +%s)" \
  --workdir /project \
  --cpus 2 \
  --memory 4g \
  -e GOOGLE_GENERATIVE_AI_API_KEY="$GEMINI_API_KEY" \
  -e HOST_WRAPPER_IP="$HOST_IP" \
  -e HOST_WRAPPER_USER="$HOST_USER" \
  -e NIX_CONFIG="
     experimental-features = nix-command flakes
     auto-optimise-store = true
     extra-substituters = https://cache.numtide.com
     extra-trusted-public-keys = niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=
     warn-dirty = false
     " \
  --mount "type=bind,source=$PROJECT_DIR,target=/project" \
  --mount "type=volume,source=$NIX_STORE_VOLUME,target=/nix" \
  --mount "type=bind,source=$NIX_USER_CACHE,target=/root/.cache" \
  --mount "type=bind,source=$OPENCODE_SETTINGS_DIR,target=/root/.local/share/opencode" \
  $IMAGE \
  nix develop --accept-flake-config #--command opencode
