#!/bin/sh
#
# Enforces the shell portability policy documented in AGENTS.md.
#
# Covers every script whose shebang is /bin/sh. That includes
# share/host-proxy-ssh.sh, the tier 1 file that has to run under busybox ash
# inside a guest container, and ssh/host-wrapper.env, which is generated with
# interpolation and so has to be produced before it can be checked.
#
# macOS /bin/sh is bash in POSIX mode, so checking with it proves nothing. This
# looks for a real POSIX shell instead, and skips rather than fails if the
# machine has none, so `make test` still works on a bare system.

cd "$(dirname "$0")" || exit 1

status=0

# Bash constructs that either fail to parse under a POSIX shell or, worse, parse
# and behave differently. The parameter expansion alternatives deliberately omit
# ":-" and ":=", both of which are POSIX.
BASHISMS='\[\[|\blocal\b|\bsource\b|<<<|\becho +-[neE]|\+=|pipefail|\bfunction +[A-Za-z_]+ *\(|\$\{[A-Za-z_][A-Za-z0-9_]*(:[0-9]|/|\^|,)'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    status=1
}

POSIX_SH=""
for candidate in dash ash; do
    if command -v "$candidate" >/dev/null 2>&1; then
        POSIX_SH=$(command -v "$candidate")
        break
    fi
done

# Select by first line only. A plain `grep -l` would also match the /bin/sh
# heredocs embedded in the bash test scripts.
sh_files=""
for f in ./*.sh ./examples/*.sh ./share/*.sh; do
    [ -f "$f" ] || continue
    [ "$(head -n 1 "$f")" = "#!/bin/sh" ] || continue
    sh_files="$sh_files $f"
done

printf 'Checking shell portability policy (AGENTS.md)\n'

if [ -n "$POSIX_SH" ]; then
    printf '  POSIX shell: %s\n' "$POSIX_SH"
else
    printf '  POSIX shell: none found (install dash to enforce the full policy)\n'
fi

# 1. Parse every /bin/sh script under a strict POSIX shell.
if [ -n "$POSIX_SH" ]; then
    for f in $sh_files; do
        "$POSIX_SH" -n "$f" || fail "$f does not parse under $POSIX_SH"
    done
    printf '  parse: checked%s\n' "$sh_files"
fi

# 2. Grep for bashisms. The checker excludes itself: BASHISMS above contains the
# literal "pipefail" and "+=", so it would match its own pattern definition.
for f in $sh_files; do
    case "$f" in
        ./check-posix.sh) continue ;;
    esac
    if grep -nE "$BASHISMS" "$f"; then
        fail "$f contains bash-only constructs"
    fi
done
printf '  bashisms: none in the /bin/sh scripts\n'

# 3. Check a generated bundle. host-wrapper.env is interpolated, so nothing
# static reaches it. The connection script is re-checked here as an installed
# copy, which is what would catch a generator putting the wrong file in place.
# A throwaway key keeps this independent of whether the machine has readable
# host keys.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/host-wrapper-posix.XXXXXX")
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    fail "could not create a temporary directory (check TMPDIR)"
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT INT TERM

if ssh-keygen -t ed25519 -N '' -C check-posix -f "$tmp/key" -q </dev/null >/dev/null 2>&1 &&
    sh ./host-connect-setup.sh "$tmp/out" --key check-posix_id --user checker \
        --host-key "$tmp/key.pub" >/dev/null; then
    for f in "$tmp/out/host-proxy-ssh.sh" "$tmp/out/ssh/host-wrapper.env"; do
        if [ -n "$POSIX_SH" ]; then
            "$POSIX_SH" -n "$f" || fail "generated $(basename "$f") does not parse under $POSIX_SH"
        fi
        if grep -nE "$BASHISMS" "$f"; then
            fail "generated $(basename "$f") contains bash-only constructs"
        fi
    done
    printf '  generated bundle: host-proxy-ssh.sh and host-wrapper.env clean\n'
else
    fail "could not generate a bundle to check"
fi

# 4. Run the connection suite under the POSIX shell. The shim is what makes this
# meaningful: without it the suite's inner `sh host-proxy-ssh.sh` calls would run
# under bash and the guest script would never meet a POSIX shell at all.
if [ -n "$POSIX_SH" ]; then
    mkdir -p "$tmp/shim"
    ln -sf "$POSIX_SH" "$tmp/shim/sh"
    if out=$(PATH="$tmp/shim:$PATH" "$POSIX_SH" ./test-connect.sh 2>&1); then
        printf '  connection suite under %s: %s\n' "$(basename "$POSIX_SH")" \
            "$(printf '%s' "$out" | grep -i 'passed' | tail -n 1)"
    else
        printf '%s\n' "$out" >&2
        fail "connection suite fails under $POSIX_SH"
    fi
fi

if [ "$status" -eq 0 ]; then
    printf 'Shell portability policy: OK\n'
else
    printf 'Shell portability policy: violations found\n' >&2
fi

exit "$status"
