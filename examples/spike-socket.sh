#!/usr/bin/env bash
# Spike: which sockets can a guest of Apple's `container` use to reach the host?
# Prints one finding per candidate. Recorded results are in docs/transport.md.
#
#   bash examples/spike-socket.sh            # reachability, integrity, latency
#   bash examples/spike-socket.sh --stress   # also the load that wedges a container
#
# Needs network access in the guest (it installs socat) and python3 on the host.

set -u

IMAGE="${IMAGE:-alpine}"
NAME="hw-spike-$$"
# sun_path holds 104 bytes on macOS, and `container` refuses a longer host path.
DIR=$(mktemp -d "${TMPDIR:-/tmp}/hw-spike.XXXXXX")

# Run "$@" for at most $1 seconds. A wedged container makes `container` hang.
limit() { perl -e 'alarm(shift); exec(@ARGV) or die "$!\n"' "$@"; }

trap 'limit 30 container stop "$NAME" >/dev/null 2>&1; rm -rf "$DIR"' EXIT

guest() {
    limit 120 container run --rm --progress none "$@"
}

printf 'macOS %s, %s\n\n' "$(sw_vers -productVersion)" "$(container --version)"

echo "== (a) AF_UNIX socket on a bind-mounted path"
python3 - "$DIR/a.sock" <<'EOF' &
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c, _ = s.accept(); c.sendall(b"reached host\n")
EOF
listener=$!
sleep 1
guest --mount "type=bind,source=$DIR,target=/spike" "$IMAGE" sh -c \
    'apk add -q socat >/dev/null 2>&1; socat -t1 - UNIX-CONNECT:/spike/a.sock </dev/null' 2>&1
kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null

echo "== (b) AF_VSOCK to the host, CID 2"
guest "$IMAGE" sh -c \
    'apk add -q socat >/dev/null 2>&1; socat -t1 - VSOCK-CONNECT:2:5000 </dev/null' 2>&1

echo "== --publish-socket: the host connects to a socket the guest listens on"
SOCK="$DIR/p.sock"
limit 60 container run -d --rm --name "$NAME" --progress none \
    --publish-socket "$SOCK:/run/p.sock" "$IMAGE" sh -c \
    'apk add -q socat >/dev/null 2>&1; socat UNIX-LISTEN:/run/p.sock,fork EXEC:cat' >/dev/null
python3 - "$SOCK" <<'EOF'
import os, socket, sys, threading, time
path = sys.argv[1]

def echo(payload):
    # Write from a thread so a large payload cannot deadlock against its echo.
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(path)
    def w(): s.sendall(payload); s.shutdown(socket.SHUT_WR)
    t = threading.Thread(target=w, daemon=True); t.start()
    buf = bytearray()
    while True:
        d = s.recv(1 << 16)
        if not d: break
        buf += d
    s.close()
    return bytes(buf)

print("before the guest listens: %d bytes, then EOF" % len(echo(b"x")))
time.sleep(8)
data = os.urandom(8 << 20)
print("8 MiB echo, half-closed: %s" % ("intact" if echo(data) == data else "CORRUPT"))
ts = []
for _ in range(50):
    t = time.monotonic(); echo(b"hi"); ts.append(time.monotonic() - t)
ts.sort()
print("connect + round trip, 50 runs: median %.1f ms, max %.1f ms" % (ts[25] * 1e3, ts[-1] * 1e3))
ok = []
def one():
    d = os.urandom(1 << 20); ok.append(echo(d) == d)
th = [threading.Thread(target=one) for _ in range(16)]
[x.start() for x in th]; [x.join() for x in th]
print("16 concurrent 1 MiB echoes intact: %d/16" % sum(ok))
EOF
ls -l "$SOCK"

[ "${1:-}" = "--stress" ] || exit 0

# Backpressure. The responder answers a line "big" with 64 MiB and echoes anything else.
STALL="$NAME-stall"
SOCK2="$DIR/s.sock"
trap 'limit 30 container stop "$NAME" "$STALL" >/dev/null 2>&1; rm -rf "$DIR"' EXIT
limit 60 container run -d --rm --name "$STALL" --progress none \
    --publish-socket "$SOCK2:/run/p.sock" "$IMAGE" sh -c \
    'apk add -q socat >/dev/null 2>&1; socat UNIX-LISTEN:/run/p.sock,fork SYSTEM:"read l; [ \"\$l\" = big ] && exec head -c 67108864 /dev/zero; exec cat"' >/dev/null
sleep 8
python3 - "$SOCK2" "$STALL" <<'EOF'
import socket, subprocess, sys, time
path, name = sys.argv[1], sys.argv[2]

def responsive():
    cmd = ["perl", "-e", "alarm(15); exec(@ARGV)", "container", "exec", name, "true"]
    return "responsive" if subprocess.run(cmd).returncode == 0 else "NOT responsive"

def small():
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(path)
    s.sendall(b"small\n")
    try: return "answered" if s.recv(100) else "EOF"
    except socket.timeout: return "TIMEOUT"
    finally: s.close()

print("== --stress: the guest writes 64 MiB and the host does not read")
a = socket.socket(socket.AF_UNIX); a.connect(path); a.sendall(b"big\n")
time.sleep(3)
print("another connection: %s; container: %s" % (small(), responsive()))
a.close(); time.sleep(5)
print("after closing it undrained: another connection: %s; container: %s" % (small(), responsive()))

print("== --stress: both directions full, then the host closes")
b = socket.socket(socket.AF_UNIX); b.connect(path); b.setblocking(False)
b.send(b"echo\n"); n = 0; t = time.monotonic()
while time.monotonic() - t < 3:
    try: n += b.send(b"\0" * 65536)
    except BlockingIOError: time.sleep(0.05)
print("host wrote %d bytes, reading none; container: %s" % (n, responsive()))
b.close(); time.sleep(10)
print("10 s after closing: container: %s" % responsive())
EOF
if ! limit 20 container exec "$STALL" true; then
    echo "recover: kill the container-runtime-linux whose --root ends in /$STALL,"
    echo "then: container system stop && container system start"
fi
