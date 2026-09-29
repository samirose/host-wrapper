#!/bin/sh
#
# Example wrapper: allowlist this, not a compiler.
#
# A compiler runs programs its own arguments name -- `-fplugin=` loads code into
# it, `-B` chooses the assembler and linker, `@file` takes the flags themselves
# from a file -- so an allowlist naming cc hands the guest a shell. This accepts
# a fixed vocabulary and refuses everything else:
#
#     cc.sh [-c] [-g] [-O0|-O1|-O2|-O3|-Os] [-Wall] [-Wextra] [-Werror]
#           [-std=<std>] [-I<dir>] [-D<name>[=<value>]] [-l<lib>]
#           [-o <file>] <file.c|file.o>...
#
# Options carrying a value are written attached, `-Iinclude` and not
# `-I include`, so that one pass over the arguments settles what each one is.
# `-o` is the exception, no compiler accepting it any other way.
#
# The vocabulary is the smallest one that builds a project inside the workspace.
# Widen it deliberately, one flag at a time, and keep the two installation rules
# from git-sign.sh: this file lives outside the allowlist directory, and CC names
# the compiler on this host.

set -eu

CC=${CC:-/usr/bin/cc}

refuse() {
    printf 'cc: %s\n' "$1" >&2
    exit 2
}

# Every path stays inside the directory the wrapper runs in, which is the one
# holding the allowlist. An absolute path or a '..' component would read or
# write a file elsewhere on the host, which is the boundary this wrapper keeps.
check_path() {
    case $1 in
        '') refuse 'empty path' ;;
        /*) refuse "path outside the workspace: $1" ;;
        ..|../*|*/..|*/../*) refuse "'..' in path: $1" ;;
    esac
}

want_output=no
sources=0
for arg in "$@"; do
    if [ "$want_output" = yes ]; then
        check_path "$arg"
        want_output=no
        continue
    fi
    case $arg in
        -c|-g|-O0|-O1|-O2|-O3|-Os|-Wall|-Wextra|-Werror) ;;
        -std=?*) ;;
        -D[A-Za-z_]*) ;;
        -l?*) ;;
        -I?*) check_path "${arg#-I}" ;;
        -o) want_output=yes ;;
        # Ahead of the source-file arm, which `-fplugin=evil.c` and `@flags.c`
        # would otherwise satisfy by ending in .c.
        -*|@*) refuse "unsupported option: $arg" ;;
        *.c|*.o) check_path "$arg"; sources=$((sources + 1)) ;;
        *) refuse "unsupported argument: $arg" ;;
    esac
done
if [ "$want_output" = yes ]; then refuse '-o takes a file'; fi
if [ "$sources" -eq 0 ]; then refuse 'name at least one source or object file'; fi

exec "$CC" "$@"
