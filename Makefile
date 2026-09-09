CC = cc
CFLAGS = -Wall -Wextra -O2
CLANG = clang

# Linux image for `make test-linux`. It supplies nix and nothing else; the
# toolchain comes from the flake's devShell.
LINUX_TEST_IMAGE = ghcr.io/nixos/nix

# Overridable linker flags (e.g. override via: make LDLIBS="-lutil" on Linux glibc)
LDLIBS =

# C helpers the protocol suite runs: a target that reports the window size it
# was handed, and a harness that supplies one over a PTY.
TEST_HELPERS = tests/winsize-probe tests/run-on-pty

all: host-wrapper host-proxy

.PHONY: all test test-connect test-linux check-posix fuzz fuzz-minimize clean

host-wrapper: host-wrapper.c
	$(CC) $(CFLAGS) -o $@ host-wrapper.c $(LDLIBS)

host-proxy: host-proxy.c
	$(CC) $(CFLAGS) -o $@ host-proxy.c

# Test binaries with sanitizers
host-wrapper-test: host-wrapper.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-wrapper.c $(LDLIBS)

host-proxy-test: host-proxy.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-proxy.c

tests/winsize-probe: tests/winsize-probe.c
	$(CC) $(CFLAGS) -o $@ tests/winsize-probe.c $(LDLIBS)

tests/run-on-pty: tests/run-on-pty.c
	$(CC) $(CFLAGS) -o $@ tests/run-on-pty.c $(LDLIBS)

# Run the protocol test suite using the sanitized test binaries, then the
# connection setup suite (no binaries required), then the portability policy.
test: host-wrapper-test host-proxy-test $(TEST_HELPERS)
	HOST_WRAPPER=./host-wrapper-test HOST_PROXY=./host-proxy-test ./test.sh
	./test-connect.sh
	./check-posix.sh

# Connection script and host key pinning tests. These stub out ssh and ip,
# so they need neither a network nor a configured host.
test-connect:
	./test-connect.sh

# Run the whole suite on Linux, where the PTY poll loop behaves differently
# from Darwin's. macOS only: Apple's container CLI runs Linux VMs.
#
# .git is dropped from the copy so the flake sees the working tree, and `clean`
# runs because the copy carries the host's Mach-O binaries.
test-linux:
	@[ "$$(uname -s)" = Darwin ] || { echo "test-linux: macOS only. Run 'make test'."; exit 1; }
	@command -v container >/dev/null 2>&1 || { echo "test-linux: needs Apple's container CLI."; exit 1; }
	container run --rm \
	    --mount "type=bind,source=$(CURDIR),target=/src,readonly=true" \
	    $(LINUX_TEST_IMAGE) sh -c '\
	        set -e; \
	        mkdir /app && cp -R /src/. /app/ && cd /app && rm -rf .git; \
	        export NIX_CONFIG="experimental-features = nix-command flakes"; \
	        nix develop --command make clean test'

# Shell portability policy from AGENTS.md. Every /bin/sh script, and the guest
# connection script that host-connect-setup.sh generates, has to run under a
# strict POSIX shell, because the guest's /bin/sh is often busybox ash. Needs no
# compiler; skips the shell-dependent checks if neither dash nor ash is present.
check-posix:
	./check-posix.sh

# Fuzzing target
# Note: This requires clang with libFuzzer support.
host-wrapper-fuzzer: host-wrapper.c fuzz.c
	$(CLANG) $(CFLAGS) -DFUZZING -fsanitize=fuzzer,address -o $@ host-wrapper.c fuzz.c $(LDLIBS)

fuzz: host-wrapper-fuzzer fuzz.dict
	mkdir -p corpus
	./host-wrapper-fuzzer -max_total_time=60 -rss_limit_mb=2048 -max_len=70000 -dict=fuzz.dict corpus

# Minimize the corpus to only unique coverage inputs
fuzz-minimize: host-wrapper-fuzzer
	mkdir -p corpus_min
	./host-wrapper-fuzzer -merge=1 -max_len=70000 corpus_min corpus
	rm -rf corpus
	mv corpus_min corpus

clean:
	rm -f host-wrapper host-proxy host-wrapper-fuzzer host-wrapper-test host-proxy-test
	rm -f $(TEST_HELPERS)
	rm -rf corpus_min
	rm -f crash-* leak-* timeout-* oom-*
