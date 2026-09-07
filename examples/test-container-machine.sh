#!/usr/bin/env bash

# End-to-end integration tests for the Container Machine example.
#
# Assumes the machine is provisioned and that /tmp/app inside it holds a built
# host-proxy. run-container-machine.sh does that and then calls this; it can
# also be run on its own against a machine that is already up.
#
# Usage: bash examples/test-container-machine.sh [machine-name]

# Ensure the script is run from the project root
if [ ! -f "host-wrapper.c" ]; then
    echo "Error: Please run this script from the project root directory:"
    echo "  bash examples/$(basename "$0")"
    exit 1
fi

. "$(dirname "$0")/../test-lib.sh"

CONTAINER_MACHINE_NAME="${1:-example-container-machine}"

echo "=================================================="
echo "Running End-to-End Guest-to-Host Integration Tests"
echo "=================================================="

run_integration_test() {
    local name="$1"
    local expected="$2"
    local stdin_data="$3"
    shift 3

    local actual
    if [ -n "$stdin_data" ]; then
        actual=$(echo -n "$stdin_data" | container machine run -i -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- ./host-proxy "$@" 2>&1)
    else
        actual=$(container machine run -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- ./host-proxy "$@" 2>&1)
    fi
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [[ "$actual" == *"$expected"* ]]; then
        report "$name" yes
    else
        report "$name" no "  Expected output to contain: $expected
  Actual output:             $actual
  Exit code:                 $exit_code"
    fi
}

run_integration_test_fail() {
    local name="$1"
    local expected_err="$2"
    shift 2

    local actual
    actual=$(container machine run -n "$CONTAINER_MACHINE_NAME" --cwd /tmp/app -- ./host-proxy "$@" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ] && [[ "$actual" == *"$expected_err"* ]]; then
        report "$name" yes
    else
        report "$name" no "  Expected failure containing: $expected_err
  Actual output:               $actual
  Exit code:                   $exit_code"
    fi
}

run_integration_test "Retrieve Host OS (uname)" "Darwin" "" /usr/bin/uname
run_integration_test "Space preservation (printf)" "[arg with space]" "" /usr/bin/printf "[%s]\\n" "\"arg with space\""
run_integration_test "Forwarding Stdin stream (wc)" "12" "hello stream" /usr/bin/wc -c
run_integration_test_fail "Blocked command validation (id)" "not in allowlist" /usr/bin/id

if grep -q "DENIED " "./config/host-wrapper.log" 2>/dev/null || grep -q "DENIED " "$HOME/.config/host-wrapper/host-wrapper.log" 2>/dev/null || grep -q "ALLOWED" "./config/host-wrapper.log" 2>/dev/null || grep -q "ALLOWED" "$HOME/.config/host-wrapper/host-wrapper.log" 2>/dev/null; then
    report "Verify Host Audit Logging" yes
elif grep -q "ALLOWED" "/tmp/host-wrapper.log" 2>/dev/null; then
    # Fall back to the standard /tmp log
    report "Verify Host Audit Logging" yes
else
    report "Verify Host Audit Logging" no "  Log files missing or empty"
fi

GUEST_HOME_FILES=$(container machine run -n "$CONTAINER_MACHINE_NAME" -- ls -la /Users /home 2>/dev/null)
if [[ "$GUEST_HOME_FILES" == *"$USER"* && ("$GUEST_HOME_FILES" == *".ssh"* || "$GUEST_HOME_FILES" == *"Library"* || "$GUEST_HOME_FILES" == *"Desktop"*) ]]; then
    report "Host Home Directory Isolation" no "  The guest can see host home contents:
$GUEST_HOME_FILES"
else
    report "Host Home Directory Isolation" yes
fi

test_summary
