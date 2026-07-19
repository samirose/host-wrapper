#!/bin/sh

# Configuration for Apple Container Machine Setup
ALLOWLIST_DIR="./config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
SSH_KEY_DIR="./ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519_machine"
CONTAINER_MACHINE_NAME="example-container-machine"

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
/usr/bin/wc
EOF
fi

# 2. Generate restricted SSH key pair for the Container Machine (if not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "[*] Generating dedicated SSH key at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "example-container-machine.key"
    # Ensure correct permissions
    chmod 600 "$SSH_KEY_FILE"
fi

# 3. Generate a dynamic-gateway SSH Connection Script
SSH_CONNECT_SCRIPT="./host-proxy-ssh.sh"
echo "[*] Generating dynamic gateway connection script at $SSH_CONNECT_SCRIPT..."
cat <<'EOF' > "$SSH_CONNECT_SCRIPT"
#!/bin/sh
# This script is invoked by host-proxy inside the Apple Container Machine.
# Change to the script's directory to ensure relative paths work.
cd "$(dirname "$0")" || exit 1

# Dynamically detect the host VM gateway IP address (the default gateway)
HOST_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3}')
if [ -z "$HOST_GATEWAY" ]; then
    # Fallback to standard Virtualization.framework gateway IP if ip route fails
    HOST_GATEWAY="192.168.64.1"
fi

exec ssh -q -T -o StrictHostKeyChecking=no -i "./ssh/id_ed25519_machine" "$USER@$HOST_GATEWAY" host-wrapper
EOF
chmod +x "$SSH_CONNECT_SCRIPT"

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
echo "3. Create and boot the Container Machine SECURELY:"
echo "   (This disables home sharing and mounts ONLY this project directory)"
echo ""
echo "   container machine create alpine:latest \\"
echo "     --name $CONTAINER_MACHINE_NAME \\"
echo "     --home-mount none \\"
echo "     --volume $(pwd):/app"
echo ""
echo "4. Build host-proxy inside your container and test:"
echo "   container machine run -n $CONTAINER_MACHINE_NAME"
echo "   # Inside the container's interactive shell:"
echo "   cd /app"
echo "   gcc -O2 -Wall -Wextra host-proxy.c -o host-proxy"
echo "   ./host-proxy /usr/bin/uname"
echo "--------------------------------------------------------"
