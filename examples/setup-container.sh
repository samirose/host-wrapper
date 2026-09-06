#!/bin/sh

# Configuration for container host-proxy setup
ALLOWLIST_DIR="./examples/config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
CONTAINER_PROJECT_DIR="./examples/container_project"
SSH_KEY_DIR="$CONTAINER_PROJECT_DIR/ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519_container"

# Ensure running from project root
if [ ! -f "host-wrapper.c" ]; then
    echo "Error: Please run this script from the project root directory:"
    echo "  sh examples/$(basename "$0")"
    exit 1
fi

# Ensure directories exist
mkdir -p "$ALLOWLIST_DIR"
mkdir -p "$SSH_KEY_DIR"

echo "========================================="
echo "Initializing container for host-proxy use"
echo "========================================="

# 1. Create isolated example allowlist
if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "[*] Creating example allowlist at $ALLOWLIST_FILE..."
    cat <<EOF > "$ALLOWLIST_FILE"
# Allowed commands for standard container example
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF
fi

# 2. Generate dedicated key pair
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "[*] Generating dedicated container SSH key at \$SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "example-container.key"
    chmod 600 "$SSH_KEY_FILE"
fi

# 3. Generate the connection script, pin the host key, and record the host
#    login user. The gateway address is deliberately left out: it depends on
#    the networks configured for the host system, so the guest resolves it
#    from its own default route at connection time.
echo "[*] Generating connection assets in $CONTAINER_PROJECT_DIR..."
sh ./host-connect-setup.sh "$CONTAINER_PROJECT_DIR" \
    --key "$(basename "$SSH_KEY_FILE")" || exit 1

SSH_CONNECT_SCRIPT="$CONTAINER_PROJECT_DIR/host-proxy-ssh.sh"

GLOBAL_WRAPPER_PATH="$HOME/.ssh/host-wrapper"
ABS_ALLOWLIST_PATH="$(pwd)/$ALLOWLIST_FILE"
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

echo "--------------------------------------------------------"
echo "Host and Project Configuration Complete."
echo "--------------------------------------------------------"
echo "1. Build and install host-wrapper locally on your host:"
echo "   make host-wrapper"
echo "   cp host-wrapper $GLOBAL_WRAPPER_PATH"
echo "   chmod 755 $GLOBAL_WRAPPER_PATH"
echo ""
echo "2. Add the restricted public key to your host's ~/.ssh/authorized_keys file:"
echo ""
echo "command=\"$GLOBAL_WRAPPER_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "3. Run in the Nix container environment:"
echo "   bash examples/run-container.sh"
echo ""
echo "The container reaches the host over its default route and verifies the"
echo "host key under the alias 'host-wrapper' rather than by address, so a"
echo "gateway that differs between machines does not require disabling host"
echo "key checking. The pin lives in $CONTAINER_PROJECT_DIR/ssh/known_hosts,"
echo "which the container sees at /project/ssh/known_hosts, and is refreshed"
echo "on every run by run-container.sh, so a changed host key needs no action."
echo "--------------------------------------------------------"
