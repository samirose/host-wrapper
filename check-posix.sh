#!/bin/sh
#
# Enforces the shell portability policy: every #!/bin/sh script, and the
# generated guest bundle, parses under dash or ash and holds no bashisms, and
# the connection suite passes under that shell.
#
# macOS /bin/sh is bash in POSIX mode, so it proves nothing here. Without dash
# or ash, the checks needing one are skipped rather than failed.

cd "$(dirname "$0")" || exit 1

status=0

# The parameter expansion alternatives omit ":-" and ":=", both POSIX.
BASHISMS='\[\[[^:]|(^|[;&|(])[[:space:]]*(local|source)[[:space:]]|<<<|\becho +-[neE]|\+=|pipefail|\bfunction +[A-Za-z_]+ *\(|\$\{[A-Za-z_][A-Za-z0-9_]*(:[0-9]|/|\^|,)'

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
for f in ./*.sh ./examples/*.sh ./examples/wrappers/*.sh ./share/*.sh; do
    [ -f "$f" ] || continue
    [ "$(head -n 1 "$f")" = "#!/bin/sh" ] || continue
    sh_files="$sh_files $f"
done

printf 'Checking shell portability policy\n'

if [ -n "$POSIX_SH" ]; then
    printf '  POSIX shell: %s\n' "$POSIX_SH"
else
    printf '  POSIX shell: none found (install dash to enforce the full policy)\n'
fi

if [ -n "$POSIX_SH" ]; then
    for f in $sh_files; do
        "$POSIX_SH" -n "$f" || fail "$f does not parse under $POSIX_SH"
    done
    printf '  parse: checked%s\n' "$sh_files"
fi

# BASHISMS would match its own definition.
for f in $sh_files; do
    case "$f" in
        ./check-posix.sh) continue ;;
    esac
    if grep -nE "$BASHISMS" "$f"; then
        fail "$f contains bash-only constructs"
    fi
done
printf '  bashisms: none in the /bin/sh scripts\n'

# host-wrapper.env exists only as generated, and the connection script is
# checked again as installed. A throwaway key stands in for the host's own.
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

# Without the shim, the suite's inner `sh host-proxy-ssh.sh` calls would run
# under bash, and the guest script would never meet a POSIX shell.
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
