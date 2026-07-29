#!/usr/bin/env bash

# Safety check: Ensure the script is run from the project root
if [ ! -f "host-wrapper.c" ]; then
    echo "Error: Please run this script from the project root directory:"
    echo "  bash examples/run-container.sh"
    exit 1
fi

# Configuration
HOST_PROJECT_DIR=$(pwd)
CONTAINER_PROJECT_DIR="./examples/container_project"
PROJECT_NAME="example-container"
IMAGE="ghcr.io/nixos/nix"
NIX_STORE_VOLUME="nix-store-$PROJECT_NAME"
NETWORK_NAME="host-wrapper-net"
NIX_CONFIG="
  experimental-features = nix-command flakes
  auto-optimise-store = true
  warn-dirty = false
"

# 1. Ensure basic keys and scripts are initialized
SSH_KEY_FILE="$CONTAINER_PROJECT_DIR/ssh/id_ed25519_container"
SSH_CONNECT_SCRIPT="$CONTAINER_PROJECT_DIR/host-proxy-ssh.sh"

if [ ! -f "$SSH_KEY_FILE" ] || [ ! -f "$SSH_CONNECT_SCRIPT" ]; then
    echo "[*] Basic configuration not found. Running setup-container.sh..."
    ./examples/setup-container.sh
fi

# Ensure isolated network exists
if ! container network list | grep -q "$NETWORK_NAME"; then
    echo "Creating isolated network $NETWORK_NAME..."
    container network create "$NETWORK_NAME"
fi

# Reset Nix store option
if [[ "$1" == "--reset" ]]; then
    echo "Resetting Nix store volume $NIX_STORE_VOLUME..."
    container volume rm "$NIX_STORE_VOLUME"
    exit 0
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

# Start a development shell in the container
container run -it --rm \
  --name "$PROJECT_NAME-$(date +%s)" \
  --network "$NETWORK_NAME" \
  --init \
  --workdir /project \
  --cpus 2 \
  --memory 1g \
  -e NIX_CONFIG="$NIX_CONFIG" \
  --mount "type=bind,source=$CONTAINER_PROJECT_DIR,target=/project" \
  --mount "type=bind,source=$HOST_PROJECT_DIR,target=/host-wrapper,readonly=true" \
  --mount "type=volume,source=$NIX_STORE_VOLUME,target=/nix" \
  $IMAGE \
  nix develop --accept-flake-config
