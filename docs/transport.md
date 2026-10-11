# Reaching the host from a container

What a guest of Apple's `container` can use to reach the host, measured with
`examples/spike-socket.sh` on macOS 27.0.1 and `container` 1.5.0, with an
Alpine guest on kernel 6.18.15.

    bash examples/spike-socket.sh            # reachability, integrity, latency
    bash examples/spike-socket.sh --stress   # backpressure; wedges a container

| Channel | Guest reaches host | Notes |
|---|---|---|
| `AF_UNIX` on a bind-mounted path | No | The guest sees the socket file; `connect` fails with `ECONNREFUSED` or `ENOTSUP` |
| `AF_VSOCK` to CID 2 | No | `/dev/vsock` exists; `connect` is reset. Only the process owning the VM can listen |
| `container run --ssh` | No | Forwards the launchd SSH agent and ignores `SSH_AUTH_SOCK` |
| `container run --publish-socket` | Inverted | The host connects in to a socket the guest listens on |
| TCP to the gateway | Yes | The SSH transport today |

## `--publish-socket`

`--publish-socket <host path>:<guest path>` creates a host socket that forwards
each connection to a socket the guest listens on. The guest initiates nothing:
the host has to connect first, so a guest-initiated request needs a guest-side
listener holding connections the host opened.

- The host socket exists while the container runs, and is created mode 0755,
  owned by the user who ran `container`. It is removed on a normal stop and
  left behind when the runtime is killed.
- The host path must fit `sun_path`, 104 bytes on macOS; `container` refuses a
  longer one at start.
- Before the guest listens, a host `connect` succeeds and reads EOF at once.
- Data arrives intact: an 8 MiB echo, and 16 concurrent 1 MiB echoes. A
  half-close reaches the guest as EOF and the reply still arrives.
- Connect and round trip take 0.3–0.7 ms median, 2.6 ms at most.

### Backpressure stalls the container

The forwarder does not survive a reader that falls behind.

- **Host stops reading what the guest writes.** Every other connection on the
  socket stalls, and so does `container exec`. Both return once the host
  drains or closes the connection. A new connection afterwards answered in one
  run and timed out in another.
- **Guest stops reading what the host writes.** Ordinary flow control: about
  450 KB is buffered, then the host's writes block. Nothing else is affected.
- **Both directions full.** After 57 KB the container stops answering `exec`,
  `stop` and `kill`, and stays that way after the host closes. Recovering
  takes killing the container's `container-runtime-linux` and restarting the
  service with `container system stop` and `container system start`.

A host-wrapper session fills both directions whenever the target stops reading
its input while the guest stops reading the output, as in
`producer | host-proxy cat | slow-consumer`. On this channel that wedges the
container.
