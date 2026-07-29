#!/bin/sh

# Configuration for container host-proxy setup
ALLOWLIST_DIR="./examples/config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
CONTAINER_PROJECT_DIR="./examples/container_project"
SSH_KEY_DIR="$CONTAINER_PROJECT_DIR/ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519_container"
HOST_DNS_NAME="host-os.internal"

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

# 3. Generate standard host connection script
SSH_CONNECT_SCRIPT="./examples/container_project/host-proxy-ssh.sh"
echo "[*] Generating standard gateway connection script at \$SSH_CONNECT_SCRIPT..."
cat <<EOF > "$SSH_CONNECT_SCRIPT"
#!/bin/sh
# This script is invoked by host-proxy inside the standard container.

# Change to the script's directory to ensure relative paths work.
cd "\$(dirname "\$0")" || exit 1

exec ssh -q -T -o StrictHostKeyChecking=no -i "./ssh/id_ed25519_container" "$USER@$HOST_DNS_NAME" host-wrapper
EOF
chmod +x "$SSH_CONNECT_SCRIPT"

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
echo "3. Run this command once per reboot to allow container-to-host DNS resolution:"
echo "   sudo container system dns create $HOST_DNS_NAME --localhost 127.0.0.1"
echo ""
echo "4. Build and run in the Nix container environment:"
echo "   make host-proxy"
echo "   bash examples/run-container.sh"
echo "--------------------------------------------------------"
