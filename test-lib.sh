#!/bin/sh
#
# Reporting and assertion helpers shared by test.sh and test-connect.sh.
#
# Sourced, never executed. The shebang is here so check-posix.sh picks the file
# up by its first line and holds it to the POSIX shell language, which it has to
# be: check-posix.sh runs test-connect.sh under dash, and whatever that suite
# sources runs under dash with it.
#
# A suite is expected to call make_test_dir first, report results through
# report() or the assert_* helpers, and end with test_summary.

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass_count=0
fail_count=0

# make_test_dir <prefix>
#
# Create a scratch directory, publish it as $TEST_DIR and arrange for it to be
# removed on exit, so a run leaves nothing behind in the repository.
make_test_dir() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")
    if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
        printf 'Error: could not create a temporary directory (check TMPDIR).\n' >&2
        exit 1
    fi
    trap 'rm -rf "$TEST_DIR"' EXIT INT TERM
}

# report <name> <yes|no> [detail]
report() {
    name="$1"
    ok="$2"
    detail="$3"
    if [ "$ok" = "yes" ]; then
        printf "Test: %s... ${GREEN}PASS${NC}\n" "$name"
        pass_count=$((pass_count + 1))
    else
        printf "Test: %s... ${RED}FAIL${NC}\n" "$name"
        if [ -n "$detail" ]; then
            printf '%s\n' "$detail"
        fi
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

# Print the tally. Returns non-zero if anything failed, so a suite can end with
# a bare call to it and exit with the right status.
test_summary() {
    printf -- '----------------------------------------\n'
    printf 'Results: %s passed, %s failed\n' "$pass_count" "$fail_count"
    printf -- '----------------------------------------\n'
    [ "$fail_count" -eq 0 ]
}
