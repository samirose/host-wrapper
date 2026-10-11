# Wire Protocol

What `host-proxy` sends to `host-wrapper`, and how the results come back. The
transport is the forced command's SSH session: the request arrives on
host-wrapper's stdin, and its stdout, stderr and exit status return as the
session's.

## Request

A request is a sequence of netstrings (`<length>:<bytes>,`, the length in
decimal), followed by the target's standard input as raw bytes:

```text
3:HW1,          protocol magic and version
7:cols=80,      options, key=value, in any order
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

| Key    | Value                 | Default |
|--------|-----------------------|---------|
| `cols` | Terminal columns, 1–65535 | 80  |
| `rows` | Terminal rows, 1–65535    | 24  |

Every option is optional. A key the wrapper does not know, a key given twice,
an option without `=` or containing a NUL byte, and a value out of range each
refuse the request. host-proxy sends both keys, taking the size from the first
of its stdin, stdout and stderr that is a terminal.

### Arguments

`argc` is a decimal count from 1 to 1024, followed by that many netstrings.
`argv[0]` names the command, which the allowlist rules then resolve.

### Limits

A netstring carries at most 65536 bytes.

## Response

host-wrapper runs the target with its stdout and stderr on two pseudo-terminals
and copies each to its own stdout and stderr. SSH carries them back on separate
channels, so the two streams stay apart, but their relative order is not
preserved. The exit status returns as the session's; the README's Exit Status
table lists the codes.

Every refusal above exits 125 before the command runs, with the reason on
stderr.
