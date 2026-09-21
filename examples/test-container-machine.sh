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

# The log this example writes, beside its own allowlist. Deliberately not the
# one belonging to a generic setup.sh install: that one is a different example's
# evidence and says nothing about this run.
AUDIT_LOG="./examples/audit.log"

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

# Sample the audit log before anything connects. The log accumulates across
# runs, so only growth during this run says the host actually logged anything.
audit_lines() {
    if [ -f "$AUDIT_LOG" ]; then
        wc -l < "$AUDIT_LOG" | tr -d ' '
    else
        echo 0
    fi
}
audit_before=$(audit_lines)

run_integration_test "Retrieve Host OS (uname)" "Darwin" "" /usr/bin/uname
run_integration_test "Space preservation (printf)" "[arg with space]" "" /usr/bin/printf "[%s]\\n" "\"arg with space\""
run_integration_test "Forwarding Stdin stream (wc)" "12" "hello stream" /usr/bin/wc -c
run_integration_test_fail "Blocked command validation (id)" "not in allowlist" /usr/bin/id

audit_after=$(audit_lines)
if [ "$audit_after" -gt "$audit_before" ]; then
    report "Verify Host Audit Logging" yes
else
    report "Verify Host Audit Logging" no "  No entries added to $AUDIT_LOG during this run
  ($audit_before lines before, $audit_after after)
  An ALLOWED or DENIED line should have been written by each test above."
fi

GUEST_HOME_FILES=$(container machine run -n "$CONTAINER_MACHINE_NAME" -- ls -la /Users /home 2>/dev/null)
if [[ "$GUEST_HOME_FILES" == *"$USER"* && ("$GUEST_HOME_FILES" == *".ssh"* || "$GUEST_HOME_FILES" == *"Library"* || "$GUEST_HOME_FILES" == *"Desktop"*) ]]; then
    report "Host Home Directory Isolation" no "  The guest can see host home contents:
$GUEST_HOME_FILES"
else
    report "Host Home Directory Isolation" yes
fi

test_summary
