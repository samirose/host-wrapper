#!/bin/sh

# Generic Host-Wrapper Setup Script
# This script initializes secure host-side configurations in standard user
# directories and generates the restricted SSH keypair used by container clients.

ALLOWLIST_DIR="$HOME/.config/host-wrapper"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
SSH_KEY_DIR="$HOME/.ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/host-wrapper_id_ed25519"

# 1. Create standard config directories
mkdir -p "$ALLOWLIST_DIR"
mkdir -p "$SSH_KEY_DIR"

# 2. Create default allowlist file
if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "Creating default allowlist file at $ALLOWLIST_FILE..."
    cat <<EOF > "$ALLOWLIST_FILE"
# Allowed commands for host-proxy
#
# - Edit to include commands relevant your use case, on per line.
# - Use +stdin option to allow the command to receive standard input from the proxy.
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF
fi

# 3. Generate SSH Key Pair (if does not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key for container at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "host-wrapper.key"
    chmod 600 "$SSH_KEY_FILE"
    chmod 600 "${SSH_KEY_FILE}.pub"
fi

# 4. Generate a generic SSH Connection Script
SSH_CONNECT_SCRIPT="./host-proxy-ssh.sh"
echo "Generating SSH connection script template at $SSH_CONNECT_SCRIPT..."
cat <<EOF > "$SSH_CONNECT_SCRIPT"
#!/bin/sh
# This script is invoked by host-proxy to establish the SSH tunnel.

# Change to the script's directory to ensure relative paths work.
cd "\$(dirname "\$0")" || exit 1

# Configure this with your host's gateway IP or DNS name:
# - Standard Virtualization Gateway: 192.168.64.1
# - Docker Desktop Gateway: host.docker.internal
# - Standard Docker Bridge Gateway: 172.17.0.1
HOST_IP="host-os.internal"

exec ssh -q -T -o StrictHostKeyChecking=no -i "./host-wrapper_id_ed25519" "$USER@\$HOST_IP" host-wrapper
EOF
chmod +x "$SSH_CONNECT_SCRIPT"

# This will install the host-wrapper to ~/.ssh.
# It can equally well be installed e.g. to a project-specific location.
GLOBAL_WRAPPER_PATH="$HOME/.ssh/host-wrapper"

ABS_ALLOWLIST_PATH="$ALLOWLIST_FILE"
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

# 5. Output instructions
echo "--------------------------------------------------------"
echo "Generic Host-Wrapper Setup Complete."
echo "--------------------------------------------------------"
echo "1. Build and install host-wrapper locally on your host:"
echo "   make host-wrapper"
echo "   cp host-wrapper $GLOBAL_WRAPPER_PATH"
echo "   chmod 755 $GLOBAL_WRAPPER_PATH"
echo ""
echo "2. Add the following line to your host's ~/.ssh/authorized_keys file:"
echo ""
echo "command=\"$GLOBAL_WRAPPER_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "3. Copy the following client files into your container/guest:"
echo "   - host-proxy (built via 'make host-proxy')"
echo "   - $SSH_CONNECT_SCRIPT"
echo "   - $SSH_KEY_FILE (the private key)"
echo ""
echo "4. Once inside the container, configure the connection script with your"
echo "   host's gateway IP and run commands like:"
echo "   ./host-proxy /usr/bin/uname"
echo "--------------------------------------------------------"
