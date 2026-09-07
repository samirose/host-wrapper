#!/usr/bin/env bash

# Test Suite for Host-Container Command Proxy
# This script tests the logic and protocol of host-proxy and host-wrapper 
# locally without requiring a full SSH setup.

. "$(dirname "$0")/test-lib.sh"

# Ensure binaries are provided or use defaults
HOST_PROXY="${HOST_PROXY:-./host-proxy}"
HOST_WRAPPER="${HOST_WRAPPER:-./host-wrapper}"

# Setup isolated environment
make_test_dir host-wrapper-protocol
cp "$HOST_PROXY" "$TEST_DIR/host-proxy"
cp "$HOST_WRAPPER" "$TEST_DIR/host-wrapper"

# Move into isolated directory to prevent touching repo files
cd "$TEST_DIR" || exit 1

ALLOWLIST="./allowlist"
# Use localized paths within the isolated directory
LOCAL_HOST_PROXY="./host-proxy"
LOCAL_HOST_WRAPPER="./host-wrapper"

# 1. Create a dummy allowlist with safe, benign commands
cat <<EOF > "$ALLOWLIST"
/usr/bin/uname
/usr/bin/printf
/usr/bin/wc +stdin
EOF

# 2. Create a stub SSH script that pipes directly to host-wrapper.
# This intercepts the connection from host-proxy and routes it locally.
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"
EOF
chmod +x "host-proxy-ssh.sh"

# Internal base function for all tests
# Usage: _run_test_base <name> <expected_exit_type> <expected_out> <stdin_data> <cmd...>
# expected_exit_type: "zero" or "nonzero"
_run_test_base() {
    local name="$1"
    local exit_type="$2"
    local expected_out="$3"
    local stdin_data="$4"
    shift 4

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

    local detail=""
    if [ "$exit_pass" = false ]; then
        detail="  Exit Code Error (Expected $exit_type, Actual $exit_code)"
    fi
    if [ "$out_pass" = false ]; then
        [ -n "$detail" ] && detail="$detail
"
        detail="$detail  Expected output to contain: $expected_out
  Actual Output: $actual_out"
    fi

    if [ "$out_pass" = true ] && [ "$exit_pass" = true ]; then
        report "$name" yes
    else
        report "$name" no "$detail"
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
run_test "Basic execution (uname)" "Darwin" "" "$LOCAL_HOST_PROXY" /usr/bin/uname

# Scenario 2: Argument with spaces
run_test "Spaces in args" "[hello space]" "" "$LOCAL_HOST_PROXY" /usr/bin/printf "[%s]\n" "hello space"

# Scenario 3: Stdin forwarding (using wc -c to count bytes)
run_test "Stdin piping (wc)" "12" "hello stream" "$LOCAL_HOST_PROXY" /usr/bin/wc -c

# Scenario 4: Command NOT in allowlist
run_test_fail "Blocked command" "Error: Command '/usr/bin/id' not in allowlist" "" "$LOCAL_HOST_PROXY" /usr/bin/id

# Scenario 5: Multiple arguments
run_test "Multi-args" "arg1-arg2" "" "$LOCAL_HOST_PROXY" /usr/bin/printf "%s-%s\n" arg1 arg2

# Scenario 5.5: Exit code propagation
# /usr/bin/false always exits with 1. We must add it to the allowlist first.
echo "/usr/bin/false" >> "$ALLOWLIST"
run_test_fail "Exit code propagation" "" "" "$LOCAL_HOST_PROXY" /usr/bin/false

# Scenario 6: Malformed header
run_test_pipe "Malformed header" "Error: Malformed netstring" "malformed" "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 7: Header length too long (exceeds MAX_ARG_LEN of 65536)
run_test_pipe "Header too long limit" "Error: Argument too long (999999 bytes)" "999999:toobig," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 8: Header digits exceed buffer (more than 15 digits)
run_test_pipe "Header digits overflow" "Error: Netstring length too long" "12345678901234567890:toobig," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 9: Verify no-hang when host command finishes but stdin is still open
FIFO="./test_fifo"
mkfifo "$FIFO"

# Open the FIFO for writing in a background subshell to unblock the reader,
# but don't actually write anything yet. This simulates an "open but idle" stdin.
( exec 3> "$FIFO"; sleep 2 ) &
WRITER_PID=$!

# Start host-proxy in background reading from FIFO
$LOCAL_HOST_PROXY /usr/bin/uname < "$FIFO" > "no_hang_out" 2>&1 &
PROXY_PID=$!

# Wait a short moment to see if it exits (uname should be instant)
sleep 0.5
if ! kill -0 $PROXY_PID 2>/dev/null; then
    # Process is gone, check output
    if grep -q "Darwin" "no_hang_out"; then
        report "No-hang on open stdin" yes
    else
        report "No-hang on open stdin" no "  Unexpected output: $(cat no_hang_out)"
    fi
else
    kill $PROXY_PID 2>/dev/null
    wait $PROXY_PID 2>/dev/null
    report "No-hang on open stdin" no "  Still running: an open stdin kept the proxy alive"
fi

# Cleanup FIFO
kill $WRITER_PID 2>/dev/null
wait $WRITER_PID 2>/dev/null
rm "$FIFO"

# Scenario 10: SIGPIPE resilience in parent
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
OUT=$($LOCAL_HOST_PROXY /usr/bin/ls $ARGS 2>&1 </dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 141 ] && [ $EXIT_CODE -ne 0 ]; then
    report "SIGPIPE resilience" yes
else
    report "SIGPIPE resilience" no "  Expected proxy to handle SIGPIPE and return normal error code (not 141 or 0)
  Actual Exit Code: $EXIT_CODE
  Actual Output: $OUT"
fi

# Scenario 11: Invalid argc (0 or negative)
run_test_pipe "Invalid argc (0)" "Error: Invalid target argc (0)" "5:80,24,1:0," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 12: argc too large
run_test_pipe "Argc too large" "Error: Invalid target argc (1025)" "5:80,24,4:1025," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 13: Partial match in allowlist (prefix/suffix)
# We want to ensure '/usr/bin/un' doesn't match '/usr/bin/uname'
run_test_pipe "Allowlist prefix match" "Error: Command '/usr/bin/un' not in allowlist" "5:80,24,1:1,11:/usr/bin/un," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 14: Premature EOF in netstring data
# Header says 1 byte, but we send '1' and then close without the comma.
run_test_pipe "Premature EOF" "Error: Malformed netstring (expected ',')" "2:1,1:1" "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 15: Extremely long allowlist line (testing getline)
# Use OS max path limit divided into valid NAME_MAX chunks, plus a long comment
SYS_MAX=$(getconf PATH_MAX / 2>/dev/null || echo 1024)
TARGET_LEN=$((SYS_MAX - 50))
CHUNK=$(printf 'A%.0s' {1..200})

LONG_PATH="/usr/bin"
while [ ${#LONG_PATH} -lt $TARGET_LEN ]; do
    LONG_PATH="$LONG_PATH/$CHUNK"
done
# Trim to exact length just to be clean
LONG_PATH="${LONG_PATH:0:$TARGET_LEN}"

LONG_COMMENT=$(printf 'C%.0s' {1..2000})
echo "$LONG_PATH # $LONG_COMMENT" >> "$ALLOWLIST"
run_test_pipe "Long allowlist line match" "execvp: No such file or directory" "5:80,24,1:1,${#LONG_PATH}:$LONG_PATH," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 17: Context-aware Working Directory (chdir)
# Create a subdirectory, move allowlist there, and verify 'pwd' starts in that directory
mkdir -p ./subdir
SUB_ALLOWLIST="./subdir/allowlist"
cat <<EOF > "$SUB_ALLOWLIST"
/bin/pwd
EOF

# Run host-wrapper with the subdirectory allowlist. 
# It should chdir into ./subdir before executing pwd.
ACTUAL_PWD=$("$(pwd)/host-wrapper" "$SUB_ALLOWLIST" <<EOF 2>&1
5:80,24,1:1,8:/bin/pwd,
EOF
)

assert_contains "Context-aware Working Directory (chdir)" "$ACTUAL_PWD" "/subdir"

# Scenario 18: Verify stdout/stderr separation
# Restore the real ssh shim
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"
EOF
chmod +x "host-proxy-ssh.sh"

# Add /bin/sh to allowlist for this test
echo "/bin/sh" >> "$ALLOWLIST"

OUT_FILE="./stdout_capture"
ERR_FILE="./stderr_capture"

# Run a command that writes to both streams
# Note: we use /bin/sh -c '...' to produce distinct output
"$LOCAL_HOST_PROXY" /bin/sh -c 'echo "OUT_DATA"; echo "ERR_DATA" >&2' > "$OUT_FILE" 2> "$ERR_FILE"

OUT_VAL=$(cat "$OUT_FILE")
ERR_VAL=$(cat "$ERR_FILE")

if [ "$OUT_VAL" == "OUT_DATA" ] && [ "$ERR_VAL" == "ERR_DATA" ]; then
    report "Stdout/Stderr separation" yes
else
    report "Stdout/Stderr separation" no "  Expected stdout: OUT_DATA, Actual: $OUT_VAL
  Expected stderr: ERR_DATA, Actual: $ERR_VAL"
fi

# Scenario 19: Verify +stdin restriction
# Verify that a command without +stdin receives 0 bytes (EOF)
# We add /usr/bin/wc (without +stdin) to a temporary allowlist, set up a stub ssh, and run it
TEMP_ALLOWLIST="./temp_allowlist"
cat <<EOF > "$TEMP_ALLOWLIST"
/usr/bin/wc
EOF

# Point our ssh stub to the wrapper using the temp allowlist
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$TEMP_ALLOWLIST"
EOF

ACTUAL_OUT=$(echo -n "hello stream" | "$LOCAL_HOST_PROXY" /usr/bin/wc -c 2>&1)
# Because wc lacks +stdin, it should receive EOF and print 0
if [[ "$ACTUAL_OUT" == *"0"* ]] && [[ "$ACTUAL_OUT" != *"12"* ]]; then
    report "Stdin restriction (no +stdin option)" yes
else
    report "Stdin restriction (no +stdin option)" no "  Expected wc -c to print 0
  Actual Output: $ACTUAL_OUT"
fi

# Restore the original allowlist and stub ssh
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"
EOF

test_summary
