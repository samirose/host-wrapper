#!/bin/sh

# host-authorized-key.sh
#
# Prints the authorized_keys line that confines a guest's key to host-wrapper.
#
# Usage:
#   sh host-authorized-key.sh [-n LABEL] [-l LOG] WRAPPER ALLOWLIST PUBKEY
#
#   -n LABEL    audit label for this key
#   -l LOG      audit log path (default: host-wrapper's own)
#   WRAPPER     the host-wrapper binary on this host
#   ALLOWLIST   the allowlist this key is confined to
#   PUBKEY      the guest's public key file
#
# restrict is default-deny: it covers ~/.ssh/rc and whatever later OpenSSH
# releases add, and the line grants nothing back.

LABEL=""
LOG=""

usage() {
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

while getopts n:l: opt; do
    case "$opt" in
        n) LABEL="$OPTARG" ;;
        l) LOG="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 3 ] || usage

WRAPPER="$1"
ALLOWLIST="$2"
PUBKEY="$3"

# An authorized_keys line passes ssh-keygen as well, and its options would
# land in front of the key alongside restrict, so the key type must lead.
KEY=$(head -n 1 "$PUBKEY" 2>/dev/null)
case "$KEY" in
    ssh-*|ecdsa-*|sk-*) ssh-keygen -lf "$PUBKEY" >/dev/null 2>&1 ;;
    *) false ;;
esac || {
    echo "host-authorized-key: $PUBKEY is not a public key." >&2
    exit 1
}

nl='
'
# sshd hands the forced command to the user's shell, so a word the shell would
# split or expand is single-quoted.
shword() {
    case "$1" in
        *"$nl"*)
            echo "host-authorized-key: a newline cannot appear in the forced command." >&2
            exit 1 ;;
        ''|*[!A-Za-z0-9_./:+-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *)
            printf '%s' "$1" ;;
    esac
}

CMD=$(shword "$WRAPPER") || exit 1
if [ -n "$LABEL" ]; then
    CMD="$CMD -n $(shword "$LABEL")" || exit 1
fi
if [ -n "$LOG" ]; then
    CMD="$CMD -l $(shword "$LOG")" || exit 1
fi
CMD="$CMD $(shword "$ALLOWLIST")" || exit 1

# Inside command="...", sshd reads \" as a quote and every other byte as itself.
CMD=$(printf '%s' "$CMD" | sed 's/"/\\"/g')

printf 'restrict,command="%s" %s\n' "$CMD" "$KEY"
