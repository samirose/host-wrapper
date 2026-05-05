CC = cc
CFLAGS = -Wall -Wextra -O2

all: host-wrapper host-proxy

host-wrapper: host-wrapper.c
	$(CC) $(CFLAGS) -o host-wrapper host-wrapper.c

host-proxy: host-proxy.c
	$(CC) $(CFLAGS) -o host-proxy host-proxy.c

clean:
	rm -f host-wrapper host-proxy

.PHONY: all clean
