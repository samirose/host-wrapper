# Wire Protocol

What `host-proxy` sends to `host-wrapper`, and how the results come back. The
transport is the forced command's SSH session: the request arrives on
host-wrapper's stdin and the response leaves on its stdout, so the transport
has to provide one ordered byte stream in each direction and nothing more.

## Request

A request is a sequence of netstrings (`<length>:<bytes>,`, the length in
decimal without leading zeros), followed by the target's standard input as raw
bytes:

```text
3:HW1,          protocol magic and version
5:tty=7,        options, key=value, in any order
7:cols=80,
7:rows=24,
0:,             end of options
1:2,            argc
11:/usr/bin/wc, argv[0]
2:-l,           argv[1]
<stdin bytes>   until EOF
```

host-wrapper reads the header byte by byte and stops at its end, so the target
inherits the rest of stdin unread.

### Magic

The first netstring is `HW1`. Anything else, including a request in an earlier
format, is refused with `protocol version mismatch: rebuild host-proxy`.

### Options

| Key    | Value                                                    | Default |
|--------|----------------------------------------------------------|---------|
| `tty`  | Sum of the terminal streams: stdin 1, stdout 2, stderr 4 | 0       |
| `cols` | Terminal columns, 1–4096                                 | 80      |
| `rows` | Terminal rows, 1–4096                                    | 24      |

Every option is optional. A key the wrapper does not know, a key given twice,
an option without `=` or containing a NUL byte, and a value out of range or
with a leading zero each refuse the request. host-proxy sends all three:
`tty` with the bit of each of its stdin, stdout and stderr that is a terminal,
and the size of the first that reports one, each dimension capped at 4096.

### Arguments

`argc` is a decimal count from 1 to 1024, followed by that many netstrings.
`argv[0]` names the command, which the allowlist rules then resolve.

### Limits

A netstring carries at most 65536 bytes.

## Response

The response is a sequence of frames on host-wrapper's stdout. A frame is a
netstring whose first byte tags it:

```text
7:1hello\n,     stdout chunk
6:2oops\n,      stderr chunk
2:x0,           exit status, always the last frame
```

host-proxy writes each chunk to its own stdout or stderr as it arrives and
exits with the status.

When the target's allowlist entry carries `+pty`, each of its stdout and
stderr whose `tty` bit is set goes on one pseudo-terminal, shared and framed as
stdout when the stdout bit is set, as stderr otherwise. Every other output
stream is a pipe of its own. The stdin bit is not acted on: the target's stdin
is never the pseudo-terminal. Output sharing the pseudo-terminal keeps the
order it was written in. Across a pseudo-terminal and a pipe, or two pipes,
chunks keep the order in which the wrapper drains them: exact when the target
pauses between writes to different streams, not guaranteed for back-to-back
writes to both.

Every outcome ends in an `x` frame, the wrapper's own refusals included, so a
response that ends without one is a transport failure: host-proxy exits 125
with `transport failed before the command reported status`. It also exits 125
on a malformed frame: an unknown tag, a length that is missing, zero, has a
leading zero or exceeds a 64 KiB chunk, a missing comma, a status outside
0–255, or anything after the status.

host-wrapper's own diagnostics go to its stderr, outside the frames, which SSH
carries to host-proxy's stderr beside ssh's own. A refused request reports its
reason there and ends with status 125, or 126 when the allowlist denies it.
