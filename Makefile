CC = cc
CFLAGS = -Wall -Wextra -O2
CLANG = clang

# Linux image for `make test-linux`. It supplies nix and nothing else; the
# toolchain comes from the flake's devShell.
LINUX_TEST_IMAGE = ghcr.io/nixos/nix

# glibc needs LDLIBS=-lutil for openpty.
LDLIBS =

TEST_HELPERS = tests/winsize-probe tests/run-on-pty

all: host-wrapper host-proxy

.PHONY: all test test-connect test-linux check-posix fuzz fuzz-minimize fuzz-proxy fuzz-proxy-minimize clean

host-wrapper: host-wrapper.c
	$(CC) $(CFLAGS) -o $@ host-wrapper.c $(LDLIBS)

host-proxy: host-proxy.c
	$(CC) $(CFLAGS) -o $@ host-proxy.c

host-wrapper-test: host-wrapper.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-wrapper.c $(LDLIBS)

host-proxy-test: host-proxy.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-proxy.c

tests/winsize-probe: tests/winsize-probe.c
	$(CC) $(CFLAGS) -o $@ tests/winsize-probe.c $(LDLIBS)

tests/run-on-pty: tests/run-on-pty.c
	$(CC) $(CFLAGS) -o $@ tests/run-on-pty.c $(LDLIBS)

test: host-wrapper-test host-proxy-test $(TEST_HELPERS)
	HOST_WRAPPER=./host-wrapper-test HOST_PROXY=./host-proxy-test ./test.sh
	./test-connect.sh
	./check-posix.sh

test-connect:
	./test-connect.sh

# The whole suite on Linux, whose PTYs behave differently from Darwin's, in a
# VM run by Apple's container CLI.
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

check-posix:
	./check-posix.sh

# Needs a clang with libFuzzer.
host-wrapper-fuzzer: host-wrapper.c fuzz.c
	$(CLANG) $(CFLAGS) -DFUZZING -fsanitize=fuzzer,address -o $@ host-wrapper.c fuzz.c $(LDLIBS)

fuzz: host-wrapper-fuzzer fuzz.dict
	mkdir -p corpus
	./host-wrapper-fuzzer -max_total_time=60 -rss_limit_mb=2048 -max_len=70000 -dict=fuzz.dict corpus

fuzz-minimize: host-wrapper-fuzzer
	mkdir -p corpus_min
	./host-wrapper-fuzzer -merge=1 -max_len=70000 corpus_min corpus
	rm -rf corpus
	mv corpus_min corpus

# host-proxy's response decoder, fed its input in reads of varying size
host-proxy-fuzzer: host-proxy.c fuzz-proxy.c
	$(CLANG) $(CFLAGS) -fsanitize=fuzzer,address,undefined -o $@ fuzz-proxy.c

fuzz-proxy: host-proxy-fuzzer
	mkdir -p corpus-proxy
	./host-proxy-fuzzer -max_total_time=60 -rss_limit_mb=2048 -max_len=70000 corpus-proxy

fuzz-proxy-minimize: host-proxy-fuzzer
	mkdir -p corpus-proxy_min
	./host-proxy-fuzzer -merge=1 -max_len=70000 corpus-proxy_min corpus-proxy
	rm -rf corpus-proxy
	mv corpus-proxy_min corpus-proxy

clean:
	rm -f host-wrapper host-proxy host-wrapper-fuzzer host-proxy-fuzzer host-wrapper-test host-proxy-test
	rm -f $(TEST_HELPERS)
	rm -rf corpus_min
	rm -f crash-* leak-* timeout-* oom-*
