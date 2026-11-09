#!/bin/sh

# Replays a corpus through the coverage build of a fuzzer: a summary on stdout,
# line and branch counts in build/coverage/<name>.txt. What a fuzz build compiles
# out is not reported, so read the lines rather than the totals.
#
# Usage: CLANG=<clang> fuzz-coverage.sh <name> <corpus>
# llvm-profdata and llvm-cov come from beside clang, so that they match it.

set -e

name=$1
corpus=$2
llvm_bin=$(dirname "$(command -v "$CLANG")")
out=build/coverage/$name

LLVM_PROFILE_FILE=$out.profraw "$out-fuzzer" -runs=0 "$corpus"
"$llvm_bin/llvm-profdata" merge -o "$out.profdata" "$out.profraw"
"$llvm_bin/llvm-cov" show "$out-fuzzer" -instr-profile="$out.profdata" \
    -show-branches=count > "$out.txt"
"$llvm_bin/llvm-cov" report "$out-fuzzer" -instr-profile="$out.profdata"
