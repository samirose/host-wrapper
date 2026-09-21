#!/usr/bin/env bash

# Ensure the script is run from the project root
if [ ! -f "host-wrapper.c" ]; then
    echo "Error: Please run this script from the project root directory:"
    echo "  bash examples/$(basename "$0")"
    exit 1
fi

# Automated Test & Run Script for Apple Container Machine Secure Integration
# This script automates both host-side and container-machine-side configurations,
# builds the binaries, and runs a comprehensive end-to-end integration test suite
# with file system isolation (no volume sharing or home mounts).

CONTAINER_MACHINE_NAME="example-container-machine"
IMAGE="alpine:latest"
PROJECT_DIR=$(pwd)
ALLOWLIST_FILE="examples/config/allowlist"
SSH_KEY_FILE="./examples/ssh/id_ed25519_container-machine"
GLOBAL_WRAPPER_PATH="$HOME/.ssh/host-wrapper"

# Parse arguments
NON_INTERACTIVE=false
if [[ "$1" == "--non-interactive" ]]; then
    NON_INTERACTIVE=true
fi

echo "======================================================="
echo "Setting up example host-wrapper Apple Container Machine"
echo "======================================================="

# 1. Ensure basic keys and scripts are initialized
if [ ! -f "$SSH_KEY_FILE" ] || [ ! -f "./examples/host-proxy-ssh.sh" ]; then
    echo "[*] Basic configuration not found. Running setup-container-machine.sh..."
    ./examples/setup-container-machine.sh
fi

# 2. Build and install host-wrapper locally on the host
echo "[*] Building and installing host-wrapper on host..."
make clean >/dev/null
make host-wrapper
mkdir -p "$(dirname "$GLOBAL_WRAPPER_PATH")"
cp host-wrapper "$GLOBAL_WRAPPER_PATH"
chmod 755 "$GLOBAL_WRAPPER_PATH"

# 3. Safely update host authorized_keys with the restricted public key
echo "[*] Setting up host-wrapper to host SSH authorized_keys..."
PUB_KEY_CONTENT=$(cat "${SSH_KEY_FILE}.pub")
ABS_ALLOWLIST_PATH="$PROJECT_DIR/$ALLOWLIST_FILE"
AUDIT_LOG_PATH="$PROJECT_DIR/examples/audit.log"
AUTH_LINE="command=\"$GLOBAL_WRAPPER_PATH -n $CONTAINER_MACHINE_NAME -l $AUDIT_LOG_PATH $ABS_ALLOWLIST_PATH\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUB_KEY_CONTENT"

mkdir -p "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/authorized_keys" ]; then
    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

if grep -q "example-container-machine.key" "$HOME/.ssh/authorized_keys"; then
    if grep -Fq "$AUTH_LINE" "$HOME/.ssh/authorized_keys"; then
        echo "[+] Restricted key with correct path already configured in authorized_keys."
    else
        echo "[*] Project path or key configuration changed. Updating authorized_keys..."
        grep -v "example-container-machine.key" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp"
        echo "$AUTH_LINE" >> "$HOME/.ssh/authorized_keys.tmp"
        mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
    fi
else
    echo "[*] Appending the restricted key to ~/.ssh/authorized_keys..."
    echo "$AUTH_LINE" >> "$HOME/.ssh/authorized_keys"
fi

# 4. Prepare local guest share directory
GUEST_SHARE_DIR="./guest_share"
echo "[*] Preparing host-proxy files in local directory '$GUEST_SHARE_DIR'..."
rm -rf "$GUEST_SHARE_DIR"
mkdir -p "$GUEST_SHARE_DIR/ssh"

cp host-proxy.c "$GUEST_SHARE_DIR/host-proxy.c"
cp Makefile "$GUEST_SHARE_DIR/Makefile"

# Generate the connection script, the host key pin, and the host settings.
# The host login name has to be recorded here, on the host: inside the VM the
# guest's own user is root, which is almost never the account to log in as.
./host-connect-setup.sh "$GUEST_SHARE_DIR" --key id_ed25519_machine

cp "$SSH_KEY_FILE" "$GUEST_SHARE_DIR/ssh/id_ed25519_machine"
chmod 600 "$GUEST_SHARE_DIR/ssh/id_ed25519_machine"

# 5. Boot or create the Container Machine
echo "[*] Provisioning Container Machine '$CONTAINER_MACHINE_NAME'..."
container system start

if container machine list | grep -q "$CONTAINER_MACHINE_NAME"; then
    echo "[+] Container Machine '$CONTAINER_MACHINE_NAME' already exists. Booting..."
    container machine set -n "$CONTAINER_MACHINE_NAME" cpus=2 memory=1G >/dev/null 2>&1
    container machine run -n "$CONTAINER_MACHINE_NAME" true </dev/null >/dev/null 2>&1
fi

if ! container machine list | grep -q "$CONTAINER_MACHINE_NAME"; then
    echo "[*] Creating Container Machine '$CONTAINER_MACHINE_NAME'..."
    container machine create "$IMAGE" \
      --name "$CONTAINER_MACHINE_NAME" \
      --home-mount none \
      --cpus 2 \
      --memory 1G

    echo "[*] Waiting for Container Machine to become ready..."
    READY=false
    for i in {1..30}; do
        if container machine run -n "$CONTAINER_MACHINE_NAME" true </dev/null >/dev/null 2>&1; then
            echo ""
            echo "[+] Container Machine is ready."
            READY=true
            break
        fi
        echo -n "."
        sleep 1
    done

    if [ "$READY" = false ]; then
        echo ""
        echo "[-] Container Machine failed to initialize. Aborting."
        exit 1
    fi

    echo "[*] Installing packages inside guest..."
    container machine run -n "$CONTAINER_MACHINE_NAME" --root apk add --no-cache build-base openssh-client </dev/null
fi

# 6. Copy files to guest using tar pipe
echo "[*] Copying files to guest..."
container machine run -n "$CONTAINER_MACHINE_NAME" mkdir -p /tmp/app </dev/null
tar -C "$GUEST_SHARE_DIR" -cf - . | container machine run -i -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- tar -xf -

# 7. Compile host-proxy inside guest
echo "[*] Compiling host-proxy..."
container machine run -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- make host-proxy </dev/null

# 8. Run End-to-End Integration Tests
#    Its own script, so it can be re-run against a machine already up.
if ! ./examples/test-container-machine.sh "$CONTAINER_MACHINE_NAME"; then
    echo "[-] Integration testing encountered failures. Please resolve errors before continuing."
    exit 1
fi
echo "[+] All integration tests passed successfully!"

if [ "$NON_INTERACTIVE" = true ]; then
    echo "[+] Non-interactive mode requested. Exiting successfully."
    echo "[*] Stopping Container Machine '$CONTAINER_MACHINE_NAME'..."
    container machine stop "$CONTAINER_MACHINE_NAME" >/dev/null 2>&1
else
    echo "[*] Entering interactive shell in the Container Machine..."
    echo "(Type 'exit' to escape, your files are inside /tmp/app/)"
    container machine run -i -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- sh -i

    echo "[*] Stopping Container Machine '$CONTAINER_MACHINE_NAME'..."
    container machine stop "$CONTAINER_MACHINE_NAME"
fi
