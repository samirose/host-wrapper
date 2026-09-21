#!/bin/sh

# Generic Host-Wrapper Setup Script
# This script initializes secure host-side configurations in standard user
# directories and generates the restricted SSH keypair used by container clients.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

ALLOWLIST_DIR="$HOME/.config/host-wrapper"
ALLOWLIST_FILE="$ALLOWLIST_DIR/allowlist"
SSH_KEY_DIR="$HOME/.ssh"
SSH_KEY_FILE="$SSH_KEY_DIR/host-wrapper_id_ed25519"
GUEST_KEY_NAME="host-wrapper_id_ed25519"

# Everything the guest needs is assembled here, ready to be copied in one go.
GUEST_DIR="./guest"

# 1. Create standard config directories
mkdir -p "$ALLOWLIST_DIR"
mkdir -p "$SSH_KEY_DIR"

# 2. Create default allowlist file
if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "Creating default allowlist file at $ALLOWLIST_FILE..."
    cat <<EOF > "$ALLOWLIST_FILE"
# Allowed commands for host-proxy
#
# - Edit to include commands relevant to your use case, one per line.
# - Name a command absolutely, or relative to this file's directory, which is
#   where commands run: /usr/bin/uname or ./build.sh. A bare name is refused,
#   because nothing is looked up on PATH.
# - Use +stdin option to allow the command to receive standard input from the proxy.
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF
fi

# 3. Generate SSH Key Pair (if it does not exist)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key for container at $SSH_KEY_FILE..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q -C "host-wrapper.key"
    chmod 600 "$SSH_KEY_FILE"
    chmod 600 "${SSH_KEY_FILE}.pub"
fi

# 4. Assemble the guest bundle: connection script, pinned host key, and the
#    private key it authenticates with.
#
#    The host address is not written into the script. Guests resolve it from
#    their own default route, because the container gateway address depends on
#    the networks configured for the host system and is not the same on every
#    machine. Host identity is pinned separately, under a fixed alias, so a
#    changing address cannot weaken verification.
echo "Assembling guest connection bundle in $GUEST_DIR..."
sh "$SCRIPT_DIR/host-connect-setup.sh" "$GUEST_DIR" --key "$GUEST_KEY_NAME" || exit 1

cp "$SSH_KEY_FILE" "$GUEST_DIR/ssh/$GUEST_KEY_NAME"
chmod 600 "$GUEST_DIR/ssh/$GUEST_KEY_NAME"

SSH_CONNECT_SCRIPT="$GUEST_DIR/host-proxy-ssh.sh"

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
echo "command=\"$GLOBAL_WRAPPER_PATH -n host-wrapper $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"
echo ""
echo "   Every attempt is recorded under the label given by -n, in"
echo "   \${XDG_STATE_HOME:-\$HOME/.local/state}/host-wrapper/audit.log."
echo "   Give each key its own label; -l <path> puts its log elsewhere."
echo ""
echo "3. Copy the contents of $GUEST_DIR into your container/guest,"
echo "   alongside host-proxy (built inside the guest via 'make host-proxy'):"
echo ""
echo "     host-proxy-ssh.sh          connection script"
echo "     ssh/$GUEST_KEY_NAME  private key"
echo "     ssh/known_hosts            pinned host key"
echo "     ssh/host-wrapper.env       host user and key settings"
echo ""
echo "   Point host-proxy at the script if it is not next to the binary:"
echo "     export HOST_PROXY_SSH_SCRIPT=/path/to/host-proxy-ssh.sh"
echo ""
echo "4. Run commands from inside the container:"
echo "   ./host-proxy /usr/bin/uname"
echo ""
echo "   The host address is detected from the guest default route. If your"
echo "   guest does not route to the host directly (Docker Desktop, for one),"
echo "   set HOST_GATEWAY in ssh/host-wrapper.env, for example:"
echo "     HOST_GATEWAY='host.docker.internal'"
echo "--------------------------------------------------------"
