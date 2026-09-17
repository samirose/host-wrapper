#!/bin/sh

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

# Compiled by `make test`. winsize-probe is a target the wrapper runs; run-on-pty
# is the harness that puts a terminal on a stream of host-proxy's, which a suite
# written in shell has no other way to do.
TEST_HELPER_DIR="${TEST_HELPER_DIR:-$(dirname "$0")/tests}"
for helper in winsize-probe run-on-pty; do
    if [ ! -x "$TEST_HELPER_DIR/$helper" ]; then
        echo "Error: $TEST_HELPER_DIR/$helper is missing. Run 'make test'." >&2
        exit 1
    fi
    cp "$TEST_HELPER_DIR/$helper" "$TEST_DIR/$helper"
done

# Move into isolated directory to prevent touching repo files
cd "$TEST_DIR" || exit 1

ALLOWLIST="./allowlist"
# Use localized paths within the isolated directory
LOCAL_HOST_PROXY="./host-proxy"
LOCAL_HOST_WRAPPER="./host-wrapper"

# The allowlist matches verbatim, so a scenario has to name the binary the
# wrapper will exec, and that path differs per system.
#
# PATH is searched directly: `command -v` answers with a bare name for printf,
# pwd and false, all three being shell builtins.
find_bin() {
    _found=""
    _oldifs="$IFS"
    IFS=:
    for _dir in $PATH; do
        [ -n "$_dir" ] || _dir="."
        if [ -x "$_dir/$1" ] && [ ! -d "$_dir/$1" ]; then
            _found="$_dir/$1"
            break
        fi
    done
    IFS="$_oldifs"
    case "$_found" in
        /*) printf '%s' "$_found" ;;
        *) echo "Error: the suite needs $1 on PATH as an absolute path." >&2
           exit 1 ;;
    esac
}

UNAME_BIN=$(find_bin uname)
PRINTF_BIN=$(find_bin printf)
WC_BIN=$(find_bin wc)
ID_BIN=$(find_bin id)
FALSE_BIN=$(find_bin false)
CAT_BIN=$(find_bin cat)
SH_BIN=$(find_bin sh)
PWD_BIN=$(find_bin pwd)
LS_BIN=$(find_bin ls)
UNAME_OUT=$(uname -s)

# 1. Create a dummy allowlist with safe, benign commands
cat <<EOF > "$ALLOWLIST"
$UNAME_BIN
$PRINTF_BIN
$WC_BIN +stdin
$CAT_BIN +stdin
$TEST_DIR/winsize-probe
EOF

# 2. Create a stub SSH script that pipes directly to host-wrapper.
# This intercepts the connection from host-proxy and routes it locally.
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"
EOF
chmod +x "host-proxy-ssh.sh"

# Where the runners below put each stream. Kept apart rather than merged with
# 2>&1, so a message arriving on the wrong stream is a failure the suite can
# see.
CAPTURE_OUT="./capture-stdout"
CAPTURE_ERR="./capture-stderr"

# Internal base function for all tests
# Usage: _run_test_base <name> <expected_exit> <stream> <expected_out> <stdin_data> <cmd...>
#
# expected_exit: "zero" or an exact status such as 126.
# stream:        "out", "err" or "both" -- which capture expected_out has to
#                appear in. An empty expected_out matches anything.
_run_test_base() {
    name="$1"
    expected_exit="$2"
    stream="$3"
    expected_out="$4"
    stdin_data="$5"
    shift 5

    if [ -n "$stdin_data" ]; then
        printf '%s' "$stdin_data" | "$@" >"$CAPTURE_OUT" 2>"$CAPTURE_ERR"
    else
        "$@" </dev/null >"$CAPTURE_OUT" 2>"$CAPTURE_ERR"
    fi
    exit_code=$?

    actual_out=$(cat "$CAPTURE_OUT")
    actual_err=$(cat "$CAPTURE_ERR")
    case "$stream" in
        out) haystack="$actual_out" ;;
        err) haystack="$actual_err" ;;
        *)   haystack="$actual_out
$actual_err" ;;
    esac

    exit_pass=false
    case "$expected_exit" in
        zero)    [ "$exit_code" -eq 0 ] && exit_pass=true ;;
        *)       [ "$exit_code" -eq "$expected_exit" ] && exit_pass=true ;;
    esac

    out_pass=false
    if [ -z "$expected_out" ]; then
        out_pass=true
    else
        case "$haystack" in
            *"$expected_out"*) out_pass=true ;;
        esac
    fi

    detail=""
    if [ "$exit_pass" = false ]; then
        detail="  Exit code: expected $expected_exit, actual $exit_code"
    fi
    if [ "$out_pass" = false ]; then
        [ -n "$detail" ] && detail="$detail
"
        detail="$detail  Expected on $stream: $expected_out
  stdout: $actual_out
  stderr: $actual_err"
    fi

    if [ "$out_pass" = true ] && [ "$exit_pass" = true ]; then
        report "$name" yes
    else
        report "$name" no "$detail"
    fi
}

# Public test runners. Shifting the name off leaves the remaining arguments in
# the order _run_test_base wants them, which POSIX has no ${@:4} for.
run_test() {
    _name="$1"
    shift
    _run_test_base "$_name" zero out "$@"
}
# run_test_exit <name> <expected_code> <expected_err> <stdin_data> <cmd...>
run_test_exit() {
    _name="$1"
    _code="$2"
    shift 2
    _run_test_base "$_name" "$_code" err "$@"
}

# Scenario 1: Basic command execution
run_test "Basic execution (uname)" "$UNAME_OUT" "" "$LOCAL_HOST_PROXY" "$UNAME_BIN"

# Scenario 2: Argument with spaces
run_test "Spaces in args" "[hello space]" "" "$LOCAL_HOST_PROXY" "$PRINTF_BIN" "[%s]\n" "hello space"

# Scenario 3: Stdin forwarding (using wc -c to count bytes)
run_test "Stdin piping (wc)" "12" "hello stream" "$LOCAL_HOST_PROXY" "$WC_BIN" -c

# Scenario 4: Command NOT in allowlist
run_test_exit "Blocked command" 126 "Error: Command '$ID_BIN' not in allowlist" "" "$LOCAL_HOST_PROXY" "$ID_BIN"

# Scenario 5: Multiple arguments
run_test "Multi-args" "arg1-arg2" "" "$LOCAL_HOST_PROXY" "$PRINTF_BIN" "%s-%s\n" arg1 arg2

# Scenario 5.5: Exit code propagation
# false always exits with 1. We must add it to the allowlist first.
echo "$FALSE_BIN" >> "$ALLOWLIST"
run_test_exit "Exit code propagation" 1 "" "" "$LOCAL_HOST_PROXY" "$FALSE_BIN"

# Scenario 6: Malformed header
run_test_exit "Malformed header" 125 "Error: Malformed netstring" "malformed" "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 7: Header length too long (exceeds MAX_ARG_LEN of 65536)
run_test_exit "Header too long limit" 125 "Error: Argument too long (999999 bytes)" "999999:toobig," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 8: Header digits exceed buffer (more than 15 digits)
run_test_exit "Header digits overflow" 125 "Error: Netstring length too long" "12345678901234567890:toobig," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 9: Verify no-hang when host command finishes but stdin is still open
FIFO="./test_fifo"
mkfifo "$FIFO"

# Open the FIFO for writing in a background subshell to unblock the reader,
# but don't actually write anything yet. This simulates an "open but idle" stdin.
( exec 3> "$FIFO"; sleep 2 ) &
WRITER_PID=$!

# Start host-proxy in background reading from FIFO
$LOCAL_HOST_PROXY "$UNAME_BIN" < "$FIFO" > "no_hang_out" 2>&1 &
PROXY_PID=$!

# Wait a short moment to see if it exits (uname should be instant)
sleep 0.5
if ! kill -0 $PROXY_PID 2>/dev/null; then
    # Process is gone, check output
    if grep -q "$UNAME_OUT" "no_hang_out"; then
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
LONG_ARG=$(printf '%1000s' '' | tr ' ' 'A')
ARGS=""
i=0
while [ "$i" -lt 1000 ]; do
    ARGS="$ARGS $LONG_ARG"
    i=$((i + 1))
done

# The proxy reports the undelivered request as its own failure, not SIGPIPE's 141.
run_test_exit "SIGPIPE resilience" 125 "" "" "$LOCAL_HOST_PROXY" "$LS_BIN" $ARGS

# Scenario 11: Invalid argc (0 or negative)
run_test_exit "Invalid argc (0)" 125 "Error: Invalid target argc (0)" "5:80,24,1:0," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 12: argc too large
run_test_exit "Argc too large" 125 "Error: Invalid target argc (1025)" "5:80,24,4:1025," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 13: Partial match in allowlist (prefix/suffix)
# A prefix of an allowlisted path must not match it.
UNAME_PREFIX=${UNAME_BIN%??}
run_test_exit "Allowlist prefix match" 126 "Error: Command '$UNAME_PREFIX' not in allowlist" "5:80,24,1:1,${#UNAME_PREFIX}:$UNAME_PREFIX," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 14: Premature EOF in netstring data
# Header says 1 byte, but we send '1' and then close without the comma.
run_test_exit "Premature EOF" 125 "Error: Malformed netstring (expected ',')" "2:1,1:1" "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 15: Extremely long allowlist line (testing getline)
# Use OS max path limit divided into valid NAME_MAX chunks, plus a long comment
SYS_MAX=$(getconf PATH_MAX / 2>/dev/null || echo 1024)
TARGET_LEN=$((SYS_MAX - 50))
CHUNK=$(printf '%200s' '' | tr ' ' 'A')

LONG_PATH="/usr/bin"
while [ ${#LONG_PATH} -lt $TARGET_LEN ]; do
    LONG_PATH="$LONG_PATH/$CHUNK"
done
# Trim to exact length just to be clean
LONG_PATH=$(printf '%s' "$LONG_PATH" | cut -c "1-$TARGET_LEN")

LONG_COMMENT=$(printf '%2000s' '' | tr ' ' 'C')
echo "$LONG_PATH # $LONG_COMMENT" >> "$ALLOWLIST"
run_test_exit "Long allowlist line match" 127 "execvp: No such file or directory" "5:80,24,1:1,${#LONG_PATH}:$LONG_PATH," "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"

# Scenario 17: Context-aware Working Directory (chdir)
# Create a subdirectory, move allowlist there, and verify 'pwd' starts in that directory
mkdir -p ./subdir
SUB_ALLOWLIST="./subdir/allowlist"
cat <<EOF > "$SUB_ALLOWLIST"
$PWD_BIN
EOF

# Run host-wrapper with the subdirectory allowlist. 
# It should chdir into ./subdir before executing pwd.
ACTUAL_PWD=$("$(pwd)/host-wrapper" "$SUB_ALLOWLIST" <<EOF 2>&1
5:80,24,1:1,${#PWD_BIN}:$PWD_BIN,
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

# Add sh to the allowlist for this test
echo "$SH_BIN" >> "$ALLOWLIST"

OUT_FILE="./stdout_capture"
ERR_FILE="./stderr_capture"

# Run a command that writes to both streams
# Note: we use sh -c '...' to produce distinct output
"$LOCAL_HOST_PROXY" "$SH_BIN" -c 'echo "OUT_DATA"; echo "ERR_DATA" >&2' > "$OUT_FILE" 2> "$ERR_FILE"

OUT_VAL=$(cat "$OUT_FILE")
ERR_VAL=$(cat "$ERR_FILE")

if [ "$OUT_VAL" = "OUT_DATA" ] && [ "$ERR_VAL" = "ERR_DATA" ]; then
    report "Stdout/Stderr separation" yes
else
    report "Stdout/Stderr separation" no "  Expected stdout: OUT_DATA, Actual: $OUT_VAL
  Expected stderr: ERR_DATA, Actual: $ERR_VAL"
fi

# Scenario 19: Verify +stdin restriction
# Verify that a command without +stdin receives 0 bytes (EOF)
# We add wc (without +stdin) to a temporary allowlist, set up a stub ssh, and run it
TEMP_ALLOWLIST="./temp_allowlist"
cat <<EOF > "$TEMP_ALLOWLIST"
$WC_BIN
EOF

# Point our ssh stub to the wrapper using the temp allowlist
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$TEMP_ALLOWLIST"
EOF

ACTUAL_OUT=$(printf '%s' "hello stream" | "$LOCAL_HOST_PROXY" "$WC_BIN" -c 2>&1)
# Because wc lacks +stdin, it should receive EOF and print 0
case "$ACTUAL_OUT" in
    *12*) report "Stdin restriction (no +stdin option)" no \
        "  wc -c saw the stdin data, so +stdin was not required
  Actual Output: $ACTUAL_OUT" ;;
    *0*) report "Stdin restriction (no +stdin option)" yes ;;
    *) report "Stdin restriction (no +stdin option)" no \
        "  Expected wc -c to print 0
  Actual Output: $ACTUAL_OUT" ;;
esac

# Restore the original allowlist and stub ssh
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
exec "$LOCAL_HOST_WRAPPER" "$ALLOWLIST"
EOF

# Scenario 20: Large output integrity
# 256 KB round-tripped through the wrapper, compared by size and checksum. A
# substring match cannot see a discarded tail, which is what the PTY poll loop
# is suspected of producing.
LARGE_IN="./large-in"
LARGE_OUT="./large-out"
awk 'BEGIN {
    line = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"
    for (i = 0; i < 4096; i++) print line
}' > "$LARGE_IN"

"$LOCAL_HOST_PROXY" "$CAT_BIN" < "$LARGE_IN" > "$LARGE_OUT" 2> "$CAPTURE_ERR"
large_code=$?

in_size=$(wc -c < "$LARGE_IN" | tr -d ' ')
out_size=$(wc -c < "$LARGE_OUT" | tr -d ' ')
in_sum=$(cksum < "$LARGE_IN" | cut -d' ' -f1)
out_sum=$(cksum < "$LARGE_OUT" | cut -d' ' -f1)

if [ "$large_code" -eq 0 ] && [ "$out_size" = "$in_size" ] && [ "$out_sum" = "$in_sum" ]; then
    report "Large output integrity ($in_size bytes)" yes
else
    report "Large output integrity ($in_size bytes)" no \
        "  Exit code: $large_code
  Bytes:     sent $in_size, received $out_size
  Checksum:  sent $in_sum, received $out_sum
  stderr:    $(cat "$CAPTURE_ERR")"
fi

# Scenario 21: Window size with stdin redirected
# The size has to come off stdout or stderr once stdin is not a terminal, which
# is the ordinary case for a piped or redirected invocation. run-on-pty gives
# host-proxy a 120x40 terminal on stdout and stderr and relays what comes back.
WINSIZE_OUT=$(./run-on-pty 120 40 "$LOCAL_HOST_PROXY" "$TEST_DIR/winsize-probe" \
    < "$LARGE_IN" 2> "$CAPTURE_ERR")
assert_equals "Window size survives a redirected stdin" "$WINSIZE_OUT" "120,40"

# Scenario 22: Window size with no terminal on any stream
"$LOCAL_HOST_PROXY" "$TEST_DIR/winsize-probe" \
    < /dev/null > "$CAPTURE_OUT" 2> "$CAPTURE_ERR"
assert_equals "Window size defaults without a terminal" "$(cat "$CAPTURE_OUT")" "80,24"

# Scenario 23: Allowlisted but missing
# Exactly one diagnostic: a child that unwound through main would repeat
# whatever was buffered at the fork.
MISSING_BIN="$TEST_DIR/no-such-tool"
echo "$MISSING_BIN" >> "$ALLOWLIST"
run_test_exit "Exec failure exits 127" 127 "execvp: No such file or directory" "" "$LOCAL_HOST_PROXY" "$MISSING_BIN"
assert_equals "Exec failure reported once" "$(grep -c 'execvp:' "$CAPTURE_ERR")" "1"

# Scenario 24: Target killed by a signal
run_test_exit "Signal exits 128+n" 143 "" "" "$LOCAL_HOST_PROXY" "$SH_BIN" -c 'kill -TERM $$'

# Scenario 25: Unreadable allowlist
run_test_exit "Missing allowlist exits 125" 125 "fopen allowlist:" "" "$LOCAL_HOST_WRAPPER" ./no-such-allowlist

# Scenario 26: Commands named relative to the allowlist directory
# The entry and the request resolve against the same directory, so a project
# can keep its tools beside its allowlist and name neither absolutely.
cat <<'EOF' > "./tool.sh"
#!/bin/sh
printf 'tool ran in %s\n' "$(pwd)"
EOF
chmod +x "./tool.sh"
echo "./tool.sh" >> "$ALLOWLIST"
run_test "Workspace-relative command" "tool ran in" "" "$LOCAL_HOST_PROXY" ./tool.sh

# Resolution is what is compared, so the two ways of naming that file meet.
# pwd -P, because the wrapper resolves against the directory getcwd reports.
WORKSPACE=$(pwd -P)
run_test "Absolute request meets a relative entry" "tool ran in" "" \
    "$LOCAL_HOST_PROXY" "$WORKSPACE/tool.sh"

# Scenario 27: Names that resolve to no single file
# Both are denied by the resolution rule rather than by the lookup, which is
# what the diagnostic distinguishes: the unwound form names an allowlisted
# file, and a bare name is one PATH lookup away from one.
UNAME_DIR=${UNAME_BIN%/*}
UNWOUND_UNAME="$UNAME_DIR/../${UNAME_DIR##*/}/${UNAME_BIN##*/}"
run_test_exit "Bare command name denied" 126 \
    "Error: Command 'uname' has no directory; write it absolutely" \
    "" "$LOCAL_HOST_PROXY" uname
run_test_exit "Unwound path denied" 126 \
    "Error: Command '$UNWOUND_UNAME' contains a '..' component" "" \
    "$LOCAL_HOST_PROXY" "$UNWOUND_UNAME"
run_test_exit "Escaping relative path denied" 126 \
    "Error: Command './../tool.sh' contains a '..' component" "" \
    "$LOCAL_HOST_PROXY" ./../tool.sh

# Scenario 28: host-proxy's own failures
run_test_exit "Proxy usage error exits 125" 125 "Usage:" "" "$LOCAL_HOST_PROXY"
run_test_exit "Unrunnable connector exits 125" 125 "execvp failed" "" \
    env HOST_PROXY_SSH_SCRIPT=./no-such-connector "$LOCAL_HOST_PROXY" "$UNAME_BIN"

# Scenario 29: Connector killed by a signal
cat <<EOF > "host-proxy-ssh.sh"
#!/bin/sh
kill -TERM \$\$
EOF
run_test_exit "Killed connector exits 128+n" 143 "" "" "$LOCAL_HOST_PROXY" "$UNAME_BIN"

test_summary
