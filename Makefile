CC = cc
CFLAGS = -Wall -Wextra -O2
CLANG = clang

# Overridable linker flags (e.g. override via: make LDLIBS="-lutil" on Linux glibc)
LDLIBS =

all: host-wrapper host-proxy

.PHONY: all test test-connect check-posix fuzz fuzz-minimize clean

host-wrapper: host-wrapper.c
	$(CC) $(CFLAGS) -o $@ host-wrapper.c $(LDLIBS)

host-proxy: host-proxy.c
	$(CC) $(CFLAGS) -o $@ host-proxy.c

# Test binaries with sanitizers
host-wrapper-test: host-wrapper.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-wrapper.c

host-proxy-test: host-proxy.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ host-proxy.c

# Run the protocol test suite using the sanitized test binaries, then the
# connection setup suite (no binaries required), then the portability policy.
test: host-wrapper-test host-proxy-test
	HOST_WRAPPER=./host-wrapper-test HOST_PROXY=./host-proxy-test ./test.sh
	./test-connect.sh
	./check-posix.sh

# Connection script and host key pinning tests. These stub out ssh and ip,
# so they need neither a network nor a configured host.
test-connect:
	./test-connect.sh

# Shell portability policy from AGENTS.md. Every /bin/sh script, and the guest
# connection script that host-connect-setup.sh generates, has to run under a
# strict POSIX shell, because the guest's /bin/sh is often busybox ash. Needs no
# compiler; skips the shell-dependent checks if neither dash nor ash is present.
check-posix:
	./check-posix.sh

# Fuzzing target
# Note: This requires clang with libFuzzer support.
host-wrapper-fuzzer: host-wrapper.c fuzz.c
	$(CLANG) $(CFLAGS) -DFUZZING -fsanitize=fuzzer,address -o $@ host-wrapper.c fuzz.c

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
	rm -rf corpus_min
	rm -f crash-* leak-* timeout-* oom-*
