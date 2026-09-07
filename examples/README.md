# host-wrapper Integration Examples

This directory contains pre-configured example integrations demonstrating how to use host-wrapper to run host-side utilities from guest environments.

---

## Supported Host OS

These example integration scripts leverage Apple's Container CLI (`container` tool) and are designed to be run on macOS host systems.

---

## Alpine Container Machine VM

This example demonstrates integration with a virtualized guest VM running under Apple's virtualization framework and without sharing host user's home directory to the guest.

### Scripts
- **setup-container-machine.sh**: Generates a dedicated guest keypair under `examples/ssh/id_ed25519_container-machine`, then calls `host-connect-setup.sh` to produce the connection script, the pinned host key, and the host settings.
- **run-container-machine.sh**: Automates VM provisioning, packages client components, pipes them into the isolated VM over a standard input stream with tar, builds the guest binary, and runs the integration suite.
- **test-container-machine.sh**: The integration suite itself, run against a provisioned machine. `run-container-machine.sh` calls it, and it can also be run on its own against a machine that is already up:

        bash examples/test-container-machine.sh

### Architecture
Since Apple's Container Machine VM currently supports only home directory mounting, `--home-mount none` is configured for guest isolation. The workspace is archived locally on the host, piped to the guest through standard input, and extracted to a working directory inside the running guest, from where the guest can compile the proxy and start to access the host commands on the allow list.

---

## Nix Standard Container

This example demonstrates how to run an isolated Nix development environment in a container where development dependencies and tools (such as git, gnumake, and gawk) are installed natively alongside the host-proxy binary for controlled host CLI access.

### Scripts
- **setup-container.sh**: Configures container local dependencies, creates SSH keys, and generates the connection assets via `host-connect-setup.sh`.
- **run-container.sh**: Provisions an isolated bridge network, builds an OCI container image using Nix via an ephemeral builder container, loads it into the container platform, and launches an interactive development shell.

### Architecture
This container mounts the `examples/container_project` directory as its active working directory. The project Nix flake (`examples/container_project/flake.nix`) packages `host-proxy` and developer tools into a self-contained OCI container image (`oci-image`). Both Docker image streaming (`docker-stream`) and native OCI archives (`oci-image`) are provided by the flake outputs.

### Running the image under Docker

`run-container.sh` builds the `oci-image` output because Apple's `container`
loads OCI archives only. Docker reads the Docker image format, so it takes the
`docker-stream` output and skips the conversion:

    sh examples/setup-container.sh
    IMAGE=$(nix build --no-link --print-out-paths \
        --override-input host-wrapper "path:$PWD" \
        "path:$PWD/examples/container_project#docker-stream")
    "$IMAGE" | docker load
    docker run -it --rm \
        --mount "type=bind,source=$PWD/examples/container_project,target=/project" \
        example-container:latest

`setup-container.sh` runs first because the image expects the connection script
and the key it writes to be present in the mounted `/project`. The
`--override-input` supplies the repository at the path the flake's
`host-wrapper` input names, which is where the builder container mounts it.

The flake builds Linux images only, so a macOS or Windows host needs a Linux
builder. It also needs `HOST_GATEWAY` set as described under Reaching the Host,
because a Docker Desktop guest's default route reaches the Linux VM rather than
the host.

---

## Reaching the Host

Neither example writes a host address into its connection script. The gateway
address of a macOS native container depends on the networks configured for the
system, so a value that works on one machine is wrong on the next. The guest
reads its own default route instead, at the moment it connects.

That only works safely because host identity is checked independently of the
address: `host-connect-setup.sh` copies the host's public SSH host key into
`ssh/known_hosts` under the alias `host-wrapper`, and the connection script
passes `HostKeyAlias=host-wrapper` with `StrictHostKeyChecking=yes`. A gateway
that moves therefore changes where the guest connects, never whether it
verifies who answered.

Each example writes three files next to its private key:

| File | Contents |
| --- | --- |
| `host-proxy-ssh.sh` | The connection script. Identical everywhere; do not edit. |
| `ssh/known_hosts` | The host's public host key, filed under the alias. |
| `ssh/host-wrapper.env` | Host login name, key path, and an optional `HOST_GATEWAY`. |

Set `HOST_GATEWAY` in `ssh/host-wrapper.env` for guests whose default route
does not reach the host, such as Docker Desktop
(`HOST_GATEWAY='host.docker.internal'`). Re-run the setup script whenever the
host's SSH host key changes, so the pin stays current.
