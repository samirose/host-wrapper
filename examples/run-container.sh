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
PROJECT_NAME="${PROJECT_NAME:-example-container}"
IMAGE_NAME="$PROJECT_NAME:latest"
BUILDER_IMAGE="ghcr.io/nixos/nix"
NETWORK_NAME="host-wrapper-net"

# 1. Ensure basic keys and scripts are initialized
SSH_KEY_FILE="$CONTAINER_PROJECT_DIR/ssh/id_ed25519_container"
SSH_CONNECT_SCRIPT="$CONTAINER_PROJECT_DIR/host-proxy-ssh.sh"

if [ ! -f "$SSH_KEY_FILE" ] || [ ! -f "$SSH_CONNECT_SCRIPT" ]; then
    echo "[*] Basic configuration not found. Running setup-container.sh..."
    ./examples/setup-container.sh
fi

# Refresh the connection assets on every run. The pinned host key and the host
# login user are host state, not project state: they can change without the
# key or the script disappearing, and a stale pin fails the connection.
./host-connect-setup.sh "$CONTAINER_PROJECT_DIR" \
  --key "$(basename "$SSH_KEY_FILE")" >/dev/null

# Ensure isolated network exists
if ! container network list | grep -q "$NETWORK_NAME"; then
    echo "Creating isolated network $NETWORK_NAME..."
    container network create "$NETWORK_NAME"
fi

# Reset container image option
if [[ "$1" == "--reset" ]]; then
    echo "Removing container image $IMAGE_NAME..."
    container image rm "$IMAGE_NAME" 2>/dev/null || true
    exit 0
fi

# Build or rebuild container image if missing or requested
if [[ "$1" == "--rebuild" ]] || ! container image list | grep -q "$PROJECT_NAME"; then
    echo "[*] Building OCI image using Nix..."
    ARCHIVE_PATH="$CONTAINER_PROJECT_DIR/$PROJECT_NAME.tar"

    container run --rm \
      --mount "type=bind,source=$HOST_PROJECT_DIR,target=/host-wrapper,readonly=true" \
      --mount "type=bind,source=$CONTAINER_PROJECT_DIR,target=/project" \
      --workdir /project \
      "$BUILDER_IMAGE" \
      sh -c "
        OUT=\$(nix build --extra-experimental-features 'nix-command flakes' \
          --override-input host-wrapper path:/host-wrapper \
          --no-link --print-out-paths .#oci-image)
        cp -L \"\$OUT\" \"/project/$PROJECT_NAME.tar\"
      "

    echo "[*] Loading OCI image into container platform..."
    container image load -i "$ARCHIVE_PATH"
    rm -f "$ARCHIVE_PATH"
    echo "[*] Image $IMAGE_NAME built and loaded successfully."
    [[ "$1" == "--rebuild" ]] && exit 0
fi

# Start a development shell in the container instantly
container run -it --rm \
  --name "$PROJECT_NAME-$(date +%s)" \
  --network "$NETWORK_NAME" \
  --init \
  --workdir /project \
  --cpus 2 \
  --memory 1g \
  --mount "type=bind,source=$CONTAINER_PROJECT_DIR,target=/project" \
  "$IMAGE_NAME"
