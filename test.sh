#!/usr/bin/env bash

# Test Suite for Host-Container Command Proxy
# This script tests the logic and protocol of host-proxy and host-wrapper 
# locally without requiring a full SSH setup.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Ensure binaries are up to date before isolating
make

# Setup isolated environment
TEST_DIR=$(mktemp -d)
cp host-proxy "$TEST_DIR/"
cp host-wrapper "$TEST_DIR/"

# Move into isolated directory to prevent touching repo files
cd "$TEST_DIR" || exit 1

ALLOWLIST="./allowlist"
HOST_PROXY="./host-proxy"
HOST_WRAPPER="./host-wrapper"

# 1. Create a dummy allowlist with safe, benign commands
cat <<EOF > "$ALLOWLIST"
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc
EOF

# 2. Create a stub SSH script that pipes directly to host-wrapper.
# This intercepts the connection from host-proxy and routes it locally.
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$HOST_WRAPPER" "$ALLOWLIST"
EOF
chmod +x "host-proxy-ssh.sh"

pass_count=0
fail_count=0

# Internal base function for all tests
# Usage: _run_test_base <name> <expected_exit_type> <expected_out> <stdin_data> <cmd...>
# expected_exit_type: "zero" or "nonzero"
_run_test_base() {
    local name="$1"
    local exit_type="$2"
    local expected_out="$3"
    local stdin_data="$4"
    shift 4

    echo -n "Test: $name... "

    local actual_out
    if [ -n "$stdin_data" ]; then
        actual_out=$(echo -n "$stdin_data" | "$@" 2>&1)
    else
        actual_out=$("$@" </dev/null 2>&1)
    fi
    local exit_code=$?

    local exit_pass=false
    if [ "$exit_type" = "zero" ] && [ $exit_code -eq 0 ]; then
        exit_pass=true
    elif [ "$exit_type" = "nonzero" ] && [ $exit_code -ne 0 ]; then
        exit_pass=true
    fi

    # Allow empty expected_out to mean "don't care about output"
    local out_pass=false
    if [ -z "$expected_out" ] || [[ "$actual_out" == *"$expected_out"* ]]; then
        out_pass=true
    fi

    if [ "$out_pass" = true ] && [ "$exit_pass" = true ]; then
        echo -e "${GREEN}PASS${NC}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}FAIL${NC}"
        if [ "$exit_pass" = false ]; then
            echo "  Exit Code Error (Expected $exit_type, Actual $exit_code)"
        fi
        if [ "$out_pass" = false ]; then
            echo "  Expected output to contain: $expected_out"
            echo "  Actual Output: $actual_out"
        fi
        fail_count=$((fail_count + 1))
    fi
}

# Public test runners
run_test() { _run_test_base "$1" "zero" "$2" "$3" "${@:4}"; }
run_test_fail() { _run_test_base "$1" "nonzero" "$2" "$3" "${@:4}"; }
# Used for piping raw protocol data into wrapper
run_test_pipe() {
    local name="$1"
    local expected_out="$2"
    local stdin_data="$3"
    shift 3
    _run_test_base "$name" "nonzero" "$expected_out" "$stdin_data" "$@"
}

# Scenario 1: Basic command execution
run_test "Basic execution (uname)" "Darwin" "" "$HOST_PROXY" /usr/bin/uname

# Scenario 2: Argument with spaces
run_test "Spaces in args" "[hello space]" "" "$HOST_PROXY" /usr/bin/printf "[%s]\n" "hello space"

# Scenario 3: Stdin forwarding (using wc -c to count bytes)
run_test "Stdin piping (wc)" "12" "hello stream" "$HOST_PROXY" /usr/bin/wc -c

# Scenario 4: Command NOT in allowlist
run_test_fail "Blocked command" "Error: Command '/usr/bin/id' not in allowlist" "" "$HOST_PROXY" /usr/bin/id

# Scenario 5: Multiple arguments
run_test "Multi-args" "arg1-arg2" "" "$HOST_PROXY" /usr/bin/printf "%s-%s\n" arg1 arg2

# Scenario 5.5: Exit code propagation
# /usr/bin/false always exits with 1. We must add it to the allowlist first.
echo "/usr/bin/false" >> "$ALLOWLIST"
run_test_fail "Exit code propagation" "" "" "$HOST_PROXY" /usr/bin/false

# Scenario 6: Malformed header
run_test_pipe "Malformed header" "Error: Malformed netstring" "malformed" "$HOST_WRAPPER" "$ALLOWLIST"

# Scenario 7: Header length too long (exceeds MAX_ARG_LEN of 65536)
run_test_pipe "Header too long limit" "Error: Argument too long (999999 bytes)" "999999:toobig," "$HOST_WRAPPER" "$ALLOWLIST"

# Scenario 8: Header digits exceed buffer (more than 15 digits)
run_test_pipe "Header digits overflow" "Error: Netstring length too long" "12345678901234567890:toobig," "$HOST_WRAPPER" "$ALLOWLIST"

# Scenario 9: Verify no-hang when host command finishes but stdin is still open
echo -n "Test: No-hang on open stdin... "
FIFO="./test_fifo"
mkfifo "$FIFO"

# Open the FIFO for writing in a background subshell to unblock the reader,
# but don't actually write anything yet. This simulates an "open but idle" stdin.
( exec 3> "$FIFO"; sleep 2 ) &
WRITER_PID=$!

# Start host-proxy in background reading from FIFO
$HOST_PROXY /usr/bin/uname < "$FIFO" > "no_hang_out" 2>&1 &
PROXY_PID=$!

# Wait a short moment to see if it exits (uname should be instant)
sleep 0.5
if ! kill -0 $PROXY_PID 2>/dev/null; then
    # Process is gone, check output
    if grep -q "Darwin" "no_hang_out"; then
        echo -e "${GREEN}PASS${NC}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}FAIL${NC} (Unexpected output)"
        fail_count=$((fail_count + 1))
    fi
else
    echo -e "${RED}FAIL${NC} (Hanging)"
    kill $PROXY_PID 2>/dev/null
    wait $PROXY_PID 2>/dev/null
    fail_count=$((fail_count + 1))
fi

# Cleanup FIFO
kill $WRITER_PID 2>/dev/null
wait $WRITER_PID 2>/dev/null
rm "$FIFO"

# Scenario 10: SIGPIPE resilience in parent
echo -n "Test: SIGPIPE resilience... "
# We simulate a wrapper crash by temporarily bypassing the real wrapper and 
# piping directly into a process that instantly exits.
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exit 1
EOF

# Generate 1000 arguments to ensure the parent writes enough data to hit the broken pipe.
LONG_ARG=$(printf 'A%.0s' {1..1000})
ARGS=$(printf "$LONG_ARG %.0s" {1..1000})

# Run the proxy. It should fail with exit code 1 (from the ssh script), not 141 (SIGPIPE).
OUT=$($HOST_PROXY /usr/bin/ls $ARGS 2>&1 </dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 141 ] && [ $EXIT_CODE -ne 0 ]; then
    echo -e "${GREEN}PASS${NC}"
    pass_count=$((pass_count + 1))
else
    echo -e "${RED}FAIL${NC}"
    echo "  Expected proxy to handle SIGPIPE and return normal error code (not 141 or 0)"
    echo "  Actual Exit Code: $EXIT_CODE"
    echo "  Actual Output: $OUT"
    fail_count=$((fail_count + 1))
fi

# Cleanup Environment
cd - > /dev/null
rm -rf "$TEST_DIR"

echo "----------------------------------------"
echo "Results: $pass_count passed, $fail_count failed"
echo "----------------------------------------"

if [ $fail_count -gt 0 ]; then
    exit 1
fi
exit 0
