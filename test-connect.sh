#!/bin/sh

# Test suite for host-connect-setup.sh and the connection script it generates.
#
# The connection script is the only part of the system that decides *where* to
# connect and *whether to trust* what answers, so it is exercised directly:
# stub `ip` and `ssh` binaries are placed ahead of the real ones on PATH, the
# script is run, and the argument vector the stub `ssh` receives is asserted on.

GENERATOR="${GENERATOR:-./host-connect-setup.sh}"

if [ ! -f "$GENERATOR" ]; then
    echo "Error: $GENERATOR not found. Run from the project root."
    exit 1
fi
GENERATOR=$(cd "$(dirname "$GENERATOR")" && pwd)/$(basename "$GENERATOR")

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass_count=0
fail_count=0

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/host-wrapper-connect.XXXXXX")
if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
    echo "Error: could not create a temporary directory (check TMPDIR)."
    exit 1
fi
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

# A fixture host key, so the suite never depends on this machine's /etc/ssh.
ssh-keygen -t ed25519 -f "$TEST_DIR/host_key" -N "" -q -C "fixture.host.key"
HOST_KEY_PUB="$TEST_DIR/host_key.pub"
HOST_KEY_FINGERPRINT=$(ssh-keygen -lf "$HOST_KEY_PUB" | cut -d' ' -f2)

# Stub binaries. `ssh` records its argument vector instead of connecting;
# `ip` replays whatever routing table the current test wants to simulate.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN"

cat <<'STUB_EOF' > "$STUB_BIN/ssh"
#!/bin/sh
# Records the argument vector as one '|'-separated line. Newlines inside an
# argument become '^', so a mangled value stays visible instead of being
# hidden past a line break by the assertions below.
argv=""
for arg in "$@"; do
    argv="$argv|$arg"
done
printf '%s' "$argv" | tr '\n' '^'
printf '\n'
STUB_EOF

cat <<'STUB_EOF' > "$STUB_BIN/ip"
#!/bin/sh
# Replays $IP_ROUTE_FIXTURE regardless of the arguments given.
printf '%s' "$IP_ROUTE_FIXTURE"
STUB_EOF

chmod +x "$STUB_BIN/ssh" "$STUB_BIN/ip"

report() {
    name="$1"
    ok="$2"
    detail="$3"
    if [ "$ok" = "yes" ]; then
        printf "Test: %s... ${GREEN}PASS${NC}\n" "$name"
        pass_count=$((pass_count + 1))
    else
        printf "Test: %s... ${RED}FAIL${NC}\n" "$name"
        [ -n "$detail" ] && printf '%s\n' "$detail"
        fail_count=$((fail_count + 1))
    fi
}

assert_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    case "$haystack" in
        *"$needle"*) report "$name" yes ;;
        *) report "$name" no "  Expected to find: $needle
  In output:
$haystack" ;;
    esac
}

assert_not_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    case "$haystack" in
        *"$needle"*) report "$name" no "  Expected NOT to find: $needle
  In output:
$haystack" ;;
        *) report "$name" yes ;;
    esac
}

assert_equals() {
    name="$1"
    actual="$2"
    expected="$3"
    if [ "$actual" = "$expected" ]; then
        report "$name" yes
    else
        report "$name" no "  Expected: $expected
  Actual:   $actual"
    fi
}

# Generate a guest directory. Extra arguments go to the generator.
make_guest() {
    dir="$TEST_DIR/$1"
    shift
    rm -rf "$dir"
    "$GENERATOR" "$dir" --host-key "$HOST_KEY_PUB" "$@" >/dev/null || return 1
    printf '%s' "$dir"
}

# Run a generated connection script under the stubs and echo the ssh argv.
# Usage: run_connect <guest-dir> <route-fixture> [VAR=value ...]
run_connect() {
    dir="$1"
    fixture="$2"
    shift 2
    env -u HOST_GATEWAY -u HOST_USER \
        PATH="$STUB_BIN:$PATH" \
        IP_ROUTE_FIXTURE="$fixture" \
        "$@" \
        sh "$dir/host-proxy-ssh.sh" 2>&1
}

echo "=========================================="
echo "Connection Setup and Gateway Test Suite"
echo "=========================================="

# ---------------------------------------------------------------------------
# Generator output
# ---------------------------------------------------------------------------

GUEST=$(make_guest guest --key id_ed25519_container --user hostuser)

for f in host-proxy-ssh.sh ssh/known_hosts ssh/host-wrapper.env; do
    if [ -f "$GUEST/$f" ]; then
        report "Generator creates $f" yes
    else
        report "Generator creates $f" no
    fi
done

if [ -x "$GUEST/host-proxy-ssh.sh" ]; then
    report "Connection script is executable" yes
else
    report "Connection script is executable" no
fi

if sh -n "$GUEST/host-proxy-ssh.sh" 2>/dev/null; then
    report "Connection script is valid POSIX sh" yes
else
    report "Connection script is valid POSIX sh" no
fi

# The pin must be a real known_hosts entry for the real host key, filed under
# the alias rather than under any address.
if ssh-keygen -lf "$GUEST/ssh/known_hosts" >/dev/null 2>&1; then
    report "Pinned known_hosts entry parses" yes
else
    report "Pinned known_hosts entry parses" no "$(cat "$GUEST/ssh/known_hosts")"
fi

assert_equals "Pinned key matches the host key" \
    "$(ssh-keygen -lf "$GUEST/ssh/known_hosts" | cut -d' ' -f2)" \
    "$HOST_KEY_FINGERPRINT"

assert_equals "Pin is filed under the alias, not an address" \
    "$(grep -v '^#' "$GUEST/ssh/known_hosts" | awk 'NF {print $1; exit}')" \
    "host-wrapper"

assert_contains "Custom alias is honoured" \
    "$(make_guest guest_alias --alias my-mac >/dev/null; grep -v '^#' "$TEST_DIR/guest_alias/ssh/known_hosts")" \
    "my-mac ssh-ed25519"

# ---------------------------------------------------------------------------
# SSH hardening options
# ---------------------------------------------------------------------------

ONE_ROUTE="default via 192.168.64.1 dev eth0
"
ARGV=$(run_connect "$GUEST" "$ONE_ROUTE")

assert_contains "Host key checking is enforced" "$ARGV" "StrictHostKeyChecking=yes"
assert_not_contains "Host key checking is never disabled" "$ARGV" "StrictHostKeyChecking=no"
assert_contains "Verification uses the alias" "$ARGV" "HostKeyAlias=host-wrapper"
assert_contains "Verification uses the pinned known_hosts" "$ARGV" "UserKnownHostsFile=./ssh/known_hosts"
assert_contains "System known_hosts cannot satisfy the pin" "$ARGV" "GlobalKnownHostsFile=/dev/null"
assert_contains "Only the supplied identity is offered" "$ARGV" "IdentitiesOnly=yes"
assert_contains "No interactive prompts" "$ARGV" "BatchMode=yes"
assert_contains "Connection attempts time out" "$ARGV" "ConnectTimeout=5"
assert_contains "No pty is requested" "$ARGV" "-T"
assert_contains "Configured key is used" "$ARGV" "./ssh/id_ed25519_container"
assert_contains "Remote command is host-wrapper" "$ARGV" "host-wrapper"

# -q would suppress exactly the diagnostics a failing connection needs to show.
assert_not_contains "Diagnostics are not suppressed" "$ARGV" "-q"

# ---------------------------------------------------------------------------
# Gateway resolution
# ---------------------------------------------------------------------------

destination() {
    printf '%s' "$1" | tr '|' '\n' | grep '@' | tail -n 1
}

assert_equals "Gateway comes from the default route" \
    "$(destination "$ARGV")" "hostuser@192.168.64.1"

# A different system yields a different gateway; nothing may be hardcoded.
OTHER_ROUTE="default via 10.88.0.1 dev eth0 proto static metric 100
"
assert_equals "Gateway tracks a different subnet" \
    "$(destination "$(run_connect "$GUEST" "$OTHER_ROUTE")")" \
    "hostuser@10.88.0.1"

# Regression: matching every line containing "default" and printing $3 emits
# one address per route, producing a mangled "A B" destination.
TWO_ROUTES="default via 10.88.0.1 dev eth0 metric 100
default via 172.17.0.1 dev eth1 metric 200
"
assert_equals "Multiple default routes select the first" \
    "$(destination "$(run_connect "$GUEST" "$TWO_ROUTES")")" \
    "hostuser@10.88.0.1"

# A gatewayless default route is not the host and must be skipped.
NO_VIA_FIRST="default dev tun0 scope link
default via 192.168.64.1 dev eth0
"
assert_equals "Gatewayless default route is skipped" \
    "$(destination "$(run_connect "$GUEST" "$NO_VIA_FIRST")")" \
    "hostuser@192.168.64.1"

# Regression: an unanchored /default/ match also fires on routes that merely
# mention the word, such as an entry in the routing table named "default".
NOISY="192.168.1.0/24 dev eth0 proto kernel scope link table default
default via 192.168.64.1 dev eth0
"
assert_equals "Routes merely mentioning 'default' are ignored" \
    "$(destination "$(run_connect "$GUEST" "$NOISY")")" \
    "hostuser@192.168.64.1"

# ---------------------------------------------------------------------------
# Overrides and precedence
# ---------------------------------------------------------------------------

assert_equals "Environment gateway overrides detection" \
    "$(destination "$(run_connect "$GUEST" "$ONE_ROUTE" HOST_GATEWAY=10.0.0.9)")" \
    "hostuser@10.0.0.9"

PINNED=$(make_guest guest_pinned --user hostuser --gateway host.docker.internal)
assert_equals "Provisioned gateway is used without detection" \
    "$(destination "$(run_connect "$PINNED" "$ONE_ROUTE")")" \
    "hostuser@host.docker.internal"

assert_equals "Environment gateway overrides the provisioned one" \
    "$(destination "$(run_connect "$PINNED" "$ONE_ROUTE" HOST_GATEWAY=10.0.0.9)")" \
    "hostuser@10.0.0.9"

# The host login name must survive into a guest whose own user differs; using
# the guest's $USER connects as the wrong account (root, in most images).
assert_equals "Host user is independent of the guest user" \
    "$(destination "$(run_connect "$GUEST" "$ONE_ROUTE" USER=root LOGNAME=root)")" \
    "hostuser@192.168.64.1"

assert_equals "Environment user overrides the provisioned one" \
    "$(destination "$(run_connect "$GUEST" "$ONE_ROUTE" HOST_USER=someone)")" \
    "someone@192.168.64.1"

# ---------------------------------------------------------------------------
# Failure reporting
# ---------------------------------------------------------------------------

# Falling back to a hardcoded address here is what produced the original bug:
# the connection appears configured and then times out somewhere else.
NO_ROUTE_OUT=$(run_connect "$GUEST" "")
NO_ROUTE_CODE=$?

if [ "$NO_ROUTE_CODE" -ne 0 ]; then
    report "Undetectable gateway fails instead of guessing" yes
else
    report "Undetectable gateway fails instead of guessing" no "  Exit code was 0"
fi

assert_not_contains "No hardcoded address is attempted" "$NO_ROUTE_OUT" "192.168.64.1"
assert_contains "Failure names the override" "$NO_ROUTE_OUT" "HOST_GATEWAY"

NO_USER=$(make_guest guest_nouser --user "" 2>/dev/null || printf '%s' "$TEST_DIR/guest_nouser")
NO_USER_OUT=$(run_connect "$NO_USER" "$ONE_ROUTE")
NO_USER_CODE=$?

if [ "$NO_USER_CODE" -ne 0 ]; then
    report "Missing host user fails loudly" yes
else
    report "Missing host user fails loudly" no "  Exit code was 0"
fi
assert_contains "Failure names the user setting" "$NO_USER_OUT" "HOST_USER"

# ---------------------------------------------------------------------------
# Generator argument handling
# ---------------------------------------------------------------------------

if "$GENERATOR" >/dev/null 2>&1; then
    report "Generator requires an output directory" no
else
    report "Generator requires an output directory" yes
fi

if "$GENERATOR" "$TEST_DIR/bogus" --host-key "$TEST_DIR/nonexistent.pub" >/dev/null 2>&1; then
    report "Generator rejects an unreadable host key" no
else
    report "Generator rejects an unreadable host key" yes
fi

echo "----------------------------------------"
echo "Results: $pass_count passed, $fail_count failed"
echo "----------------------------------------"

[ "$fail_count" -eq 0 ]
