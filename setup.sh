#!/bin/bash

# Configuration
ALLOWLIST_DIR="./config"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
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
/usr/bin/wc
EOF
fi

# 3. Generate SSH Key Pair (if not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key for container at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "agent-harness.key"
fi

# 4. Generate the SSH Connection Script
SSH_CONNECT_SCRIPT="./host-proxy-ssh.sh"
echo "Generating SSH connection script at $SSH_CONNECT_SCRIPT..."
cat <<EOF > "$SSH_CONNECT_SCRIPT"
#!/bin/sh
# This script is invoked by host-proxy to establish the SSH tunnel.
# You can customize SSH options, ports, or hostnames here.
exec ssh -q -T -i "$SSH_KEY_FILE" host.docker.internal host-wrapper
EOF
chmod +x "$SSH_CONNECT_SCRIPT"

# 5. Output instructions
ABS_WRAPPER_PATH="$(pwd)/host-wrapper"
ABS_ALLOWLIST_PATH="$(pwd)/$ALLOWLIST_FILE"
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

echo "--------------------------------------------------------"
echo "Setup Complete."
echo "--------------------------------------------------------"
echo "To finish configuration, add the following line to your host's"
echo "~/.ssh/authorized_keys file:"
echo ""
echo "command=\"$ABS_WRAPPER_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "--------------------------------------------------------"
echo "Then, from your container, you can run commands like:"
echo "./host-proxy /usr/bin/uname"
echo "--------------------------------------------------------"
