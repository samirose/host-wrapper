# Host-Container Command Proxy Plan

## 1. Background & Motivation
The goal is to allow an isolated container running under macOS Native Containers to safely execute specific commands on the macOS host. Shell argument evaluation must occur exclusively in the container to prevent security vulnerabilities and complications on the host. The tool will strictly rely on POSIX APIs and existing tools like SSH to maximize portability and security.

## 2. Proposed Solution
The architecture uses **SSH** as the communication and multiplexing layer, supplemented by two custom **C binaries** that handle exact argument serialization and command validation without ever invoking a host shell. 

To preserve arguments exactly, the container proxy will serialize `argv` using the **Netstring** format and prepend it to the standard input stream. The host wrapper will decode this header byte-by-byte from `stdin`, validate the command against a provided allowlist, and hand over execution via `execvp`, seamlessly passing the remainder of `stdin` along with `stdout` and `stderr`.

## 3. Key Components

### A. Protocol: Netstrings over Standard Input
The `argv` array is serialized as a sequence of [Netstrings](https://cr.yp.to/proto/netstrings.txt) (`[length]:[data],`), prefixed by a netstring representing `argc`.
**Format:**
`[argc netstring][arg0 netstring][arg1 netstring]...[remaining stdin payload]`
**Example for `ls -l /`:**
`1:3,2:ls,2:-l,1:/,`

### B. Container Proxy (`host-proxy.c`)
- **Invocation:** Behaves exactly like the target command (e.g., `host-proxy ls -l`).
- **Logic:**
  1. Creates a pipe.
  2. Forks.
  3. **Child:** Maps its `stdin` to the pipe, `execvp`s `./host-proxy-ssh.sh`.
  4. **Parent:** Serializes its own `argc`/`argv` as netstrings and writes them to the pipe. It then loops, reading from its original `stdin` and writing to the pipe until EOF.
  5. Parent waits for the child process and returns its exit code.

### C. SSH Connection Script (`host-proxy-ssh.sh`)
- **Role:** Encapsulates the SSH command and configuration (key paths, hostname, user, etc.).
- **Invocation:** Called by `host-proxy`.
- **Logic:** `exec ssh -q -T -i <key> user@host host-wrapper`
- **Benefit:** Allows users to modify SSH parameters (like port or target host) without recompiling the `host-proxy` binary.

### C. Host Wrapper (`host-wrapper.c`)
- **Invocation:** Configured in the macOS host's `~/.ssh/authorized_keys` as `command="/usr/local/bin/host-wrapper /path/to/allowlist",no-pty,no-port-forwarding...`. The allowlist file is passed as a command-line argument.
- **Logic:**
  1. Reads `stdin` **one byte at a time** (to avoid buffering bytes meant for the target command) to parse the `argc` netstring.
  2. Parses the remaining netstrings to reconstruct the exact `argv` array.
  3. Checks `argv[0]` against the allowlist file provided in `argv[1]` of the wrapper itself.
  4. If valid, executes the target command via `execvp(target_argv[0], target_argv)`.
  5. Because `stdin` was read unbuffered up to the end of the header, the new process natively inherits the remaining `stdin` stream, as well as the active `stdout` and `stderr` streams managed by SSH.
  **Note on Shell Scripts:** Because `execvp` relies on the OS kernel for program loading, target commands can be native binaries or shell scripts. Shell scripts will execute correctly as long as they have a valid shebang (e.g., `#!/bin/sh`) and executable permissions. 

### D. Allowlist Format
The allowlist is a simple text file specifying exact, permitted command paths.
- One command per line.
- Empty lines are ignored.
- Lines starting with `#` are treated as comments and ignored.
- The command name sent by the proxy (e.g., `git` or `/usr/bin/git`) must strictly match a non-comment line in the allowlist. 

**Example (`/etc/host-proxy/allowlist`):**
```text
# Development tools
/usr/bin/git
/usr/local/bin/docker

# System utilities
/bin/ls
cat

# Custom scripts (must have shebang and +x)
/usr/local/bin/my-custom-script.sh
```

## 4. Implementation Steps
1. **Develop `host-wrapper.c`:**
   - Implement strict byte-by-byte netstring parsing.
   - Implement allowlist parsing with support for comments and empty lines.
   - Implement validation logic using the file path passed as a command-line argument.
   - Handle errors (e.g., malformed headers, command not found) by writing to `stderr` and exiting securely.
2. **Develop `host-proxy.c`:**
   - Implement netstring serialization for `argv`.
   - Implement the `fork`/`pipe`/`execvp` routine for invoking `ssh`.
   - Implement the `stdin` forwarding loop.
3. **Configuration & Setup scripts:**
   - Script to generate SSH keys and configure `authorized_keys` on the host.
   - Script to deploy the binaries to their respective environments.

## 5. Security & Verification
- **Host Security:** The `host-wrapper` binary strictly bypasses `/bin/sh` or `system()`. It only calls `execvp`, meaning arguments cannot trigger command injection on the host.
- **Resource Limits:** The netstring parser must enforce strict limits on argument length and total header size to prevent memory exhaustion attacks from a compromised container.
- **Verification:**
  - Verify exact argument passing (e.g., arguments with spaces, quotes, newlines, and NUL characters).
  - Verify execution of compiled binaries and shell scripts (with shebang).
  - Verify `stdin` pipeline works (e.g., `echo "data" | host-proxy cat`).
  - Verify `stdout`/`stderr` multiplexing and exit codes propagate accurately back to the container.
