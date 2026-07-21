#!/bin/sh

# Configuration
ALLOWLIST_DIR="./config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
HOST_WRAPPER_USER="$USER"
HOST_DNS_NAME="host-os.internal"
HOST_DUMMY_IP="203.0.113.113"
SSH_KEY_DIR="./ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519"

# 1. Create directories
mkdir -p "$ALLOWLIST_DIR"
mkdir -p "$SSH_KEY_DIR"

# 2. Create sample allowlist
if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "Creating sample allowlist at $ALLOWLIST_FILE..."
    cat <<EOF > "$ALLOWLIST_FILE"
# Allowed commands for host-proxy
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF
fi

# 3. Generate SSH Key Pair (if not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key for container at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "host-wrapper.key"
fi

# 4. Generate the SSH Connection Script
SSH_CONNECT_SCRIPT="./host-proxy-ssh.sh"
echo "Generating SSH connection script at $SSH_CONNECT_SCRIPT..."
cat <<EOF > "$SSH_CONNECT_SCRIPT"
#!/bin/sh
# This script is invoked by host-proxy to establish the SSH tunnel.
# Change to the script's directory to ensure relative paths work.
cd "\$(dirname "\$0")" || exit 1
exec ssh -q -T -o StrictHostKeyChecking=no -i "$SSH_KEY_FILE" "$HOST_WRAPPER_USER@$HOST_DNS_NAME" host-wrapper
EOF
chmod +x "$SSH_CONNECT_SCRIPT"

# 5. Output instructions
GLOBAL_WRAPPER_PATH="$HOME/.ssh/host-wrapper"
ABS_ALLOWLIST_PATH="$(pwd)/$ALLOWLIST_FILE"
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

echo "--------------------------------------------------------"
echo "Setup Complete."
echo "--------------------------------------------------------"
echo "1. Ensure the host-wrapper binary is in a stable location."
echo "   Recommended: cp host-wrapper $GLOBAL_WRAPPER_PATH"
echo ""
echo "2. Run this command once per reboot to allow container-to-host networking:"
echo "   sudo container system dns create $HOST_DNS_NAME --localhost $HOST_DUMMY_IP"
echo ""
echo "3. To finish configuration, add the following line to your host's"
echo "   ~/.ssh/authorized_keys file:"
echo ""
echo "command=\"$GLOBAL_WRAPPER_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "Note: host-wrapper will automatically set the working directory for"
echo "spawned commands to: $(dirname "$ABS_ALLOWLIST_PATH")"
echo "--------------------------------------------------------"
echo "Then, from your container, you can run commands like:"
echo "./host-proxy /usr/bin/uname"
echo "--------------------------------------------------------"
