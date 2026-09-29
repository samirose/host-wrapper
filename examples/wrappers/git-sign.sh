#!/bin/sh
#
# Example wrapper: allowlist this, not git.
#
# git runs programs its own arguments name -- `-c core.pager`, `-c alias.x`,
# `--exec-path`, `-c core.hooksPath` -- so an allowlist naming git hands the
# guest a shell. This accepts two invocations and refuses everything else:
#
#     git-sign.sh commit -S [--amend] [-m <message>]
#     git-sign.sh tag -s -m <message> <tagname>
#
# What it is for: the signing key stays on the host and the guest never holds a
# copy. Everything else about the repository the guest can do for itself.
#
# Two rules for installing it:
#
#   - Keep this file outside the directory holding the allowlist. That directory
#     is where allowlisted commands run, so anything able to write a file there
#     could otherwise rewrite this one.
#   - Point GIT at the git on this host. The environment belongs to the host --
#     a request carries arguments and nothing else -- so reading it here is not
#     a way in, and it is what lets a test point this at a stub.

set -eu

GIT=${GIT:-/usr/bin/git}

refuse() {
    printf 'git-sign: %s\n' "$1" >&2
    exit 2
}

subcommand=${1:-}
[ -n "$subcommand" ] || refuse 'name a subcommand: commit or tag'
shift

# The subcommand is settled first, because the options that reach a shell are
# the ones git reads before it. What follows is a closed vocabulary: an argument
# not named here is refused rather than passed on.
case $subcommand in
commit)
    signed=no
    want_message=no
    for arg in "$@"; do
        if [ "$want_message" = yes ]; then
            want_message=no
            continue
        fi
        case $arg in
            -S) signed=yes ;;
            --amend) ;;
            -m) want_message=yes ;;
            *) refuse "commit: unsupported argument: $arg" ;;
        esac
    done
    if [ "$want_message" = yes ]; then refuse 'commit: -m takes a message'; fi
    if [ "$signed" != yes ]; then refuse 'commit: -S is required'; fi
    ;;
tag)
    signed=no
    want_message=no
    message=no
    names=0
    for arg in "$@"; do
        if [ "$want_message" = yes ]; then
            want_message=no
            message=yes
            continue
        fi
        case $arg in
            -s) signed=yes ;;
            -m) want_message=yes ;;
            -*) refuse "tag: unsupported option: $arg" ;;
            *) names=$((names + 1)) ;;
        esac
    done
    if [ "$want_message" = yes ]; then refuse 'tag: -m takes a message'; fi
    if [ "$signed" != yes ]; then refuse 'tag: -s is required'; fi
    if [ "$message" != yes ]; then refuse 'tag: -m is required'; fi
    if [ "$names" -ne 1 ]; then refuse 'tag: name exactly one tag'; fi
    ;;
*)
    refuse "unsupported subcommand: $subcommand"
    ;;
esac

exec "$GIT" "$subcommand" "$@"
