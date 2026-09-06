#!/bin/sh

# Configuration for Apple Container Machine Setup
ALLOWLIST_DIR="./examples/config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
SSH_KEY_DIR="./examples/ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519_container-machine"
CONTAINER_MACHINE_NAME="example-container-machine"

# Ensure running from project root
if [ ! -f "host-wrapper.c" ]; then
    echo "Error: Please run this script from the project root directory:"
    echo "  sh examples/$(basename "$0")"
    exit 1
fi

# Ensure directories exist
mkdir -p "$ALLOWLIST_DIR"
mkdir -p "$SSH_KEY_DIR"

echo "========================================================"
echo "Initializing Secure Apple Container Machine Integration"
echo "========================================================"

# 1. Create a sample allowlist if not already present
if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "[*] Creating sample allowlist at $ALLOWLIST_FILE..."
    cat <<EOF > "$ALLOWLIST_FILE"
# Allowed commands for host-proxy inside the Container Machine
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF
fi

# 2. Generate restricted SSH key pair for the Container Machine (if not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "[*] Generating dedicated SSH key at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "example-container-machine.key"
    chmod 600 "$SSH_KEY_FILE"
fi

# 3. Generate the connection script, pin the host key, and record the host
#    login user. The VM's gateway address is resolved from its default route
#    at connection time, since it depends on the networks configured for the
#    host system rather than being a fixed value.
echo "[*] Generating connection assets in ./examples..."
sh ./host-connect-setup.sh ./examples \
    --key "$(basename "$SSH_KEY_FILE")" || exit 1

SSH_CONNECT_SCRIPT="./examples/host-proxy-ssh.sh"

GLOBAL_WRAPPER_PATH="$HOME/.ssh/host-wrapper"
ABS_ALLOWLIST_PATH="$(pwd)/$ALLOWLIST_FILE"
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

echo "--------------------------------------------------------"
echo "Host and Project Configuration Complete."
echo "--------------------------------------------------------"
echo "1. Ensure the host-wrapper binary is built and in place:"
echo "   make host-wrapper"
echo "   cp host-wrapper $GLOBAL_WRAPPER_PATH"
echo ""
echo "2. Add the restricted public key to your host's"
echo "   ~/.ssh/authorized_keys file:"
echo ""
echo "command=\"$GLOBAL_WRAPPER_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "3. Create and boot the Container Machine (with no home directory sharing):"
echo "   container machine create alpine:latest \\"
echo "     --name $CONTAINER_MACHINE_NAME \\"
echo "     --home-mount none"
echo ""
echo "4. Copy client files and build host-proxy inside your container:"
echo "   (Or simply run 'bash examples/run-container-machine.sh' to fully automate this!)"
echo ""
echo "The generated assets are in ./examples: host-proxy-ssh.sh with the key,"
echo "ssh/known_hosts and ssh/host-wrapper.env beside it. Copy them into the"
echo "guest as a unit; the script resolves ./ssh/known_hosts relative to its"
echo "own directory, so where they land in the guest does not matter. The"
echo "host key is pinned under the alias 'host-wrapper' rather than by"
echo "address, so the gateway may differ between machines without host key"
echo "checking having to be disabled. Re-run this script if the host key"
echo "changes; run-container-machine.sh builds its own bundle and does not"
echo "need that step."
echo "--------------------------------------------------------"
