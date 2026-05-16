CC = cc
CFLAGS = -Wall -Wextra -O2
CLANG ?= clang

all: host-wrapper host-proxy

host-wrapper: host-wrapper.c
	$(CC) $(CFLAGS) -o host-wrapper host-wrapper.c

host-proxy: host-proxy.c
	$(CC) $(CFLAGS) -o host-proxy host-proxy.c

# Fuzzing target
# Note: This requires clang with libFuzzer support.
fuzz: host-wrapper.c fuzz.c fuzz.dict
	$(CLANG) $(CFLAGS) -DFUZZING -fsanitize=fuzzer,address -o host-wrapper-fuzzer host-wrapper.c fuzz.c
	mkdir -p corpus
	./host-wrapper-fuzzer -max_total_time=60 -rss_limit_mb=2048 -max_len=70000 -dict=fuzz.dict corpus

# Minimize the corpus to only unique coverage inputs
fuzz-minimize: host-wrapper-fuzzer
	mkdir -p corpus_min
	./host-wrapper-fuzzer -merge=1 -max_len=70000 corpus_min corpus
	rm -rf corpus
	mv corpus_min corpus

clean:
	rm -f host-wrapper host-proxy host-wrapper-fuzzer
	rm -rf corpus_min
	rm -f crash-* leak-* timeout-* oom-*

.PHONY: all clean fuzz fuzz-minimize
