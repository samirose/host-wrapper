# host-wrapper Integration Examples

This directory contains pre-configured example integrations demonstrating how to use host-wrapper to run host-side utilities from guest environments.

---

## Supported Host OS

These example integration scripts leverage Apple's Container CLI (`container` tool) and are designed to be run on macOS host systems.

---

## Alpine Container Machine VM

This example demonstrates integration with a virtualized guest VM running under Apple's virtualization framework and without sharing host user's home directory to the guest.

### Scripts
- **setup-container-machine.sh**: Generates a dynamic-gateway SSH connection script and a dedicated guest keypair under `examples/ssh/id_ed25519_container-machine`.
- **run-container-machine.sh**: Automates VM provisioning, packages client components, pipes them into the isolated VM over a standard input stream with tar, builds the guest binary, and executes an integration test suite.

### Architecture
Since Apple's Container Machine VM currently supports only home directory mounting, `--home-mount none` is configured for guest isolation. The workspace is archived locally on the host, piped to the guest through standard input, and extracted to a working directory inside the running guest, from where the guest can compile the proxy and start to access the host commands on the allow list.

---

## Nix Standard Container

This example demonstrates how to run an isolated Nix development environment in a container where development dependencies and tools (such as git, gnumake, and gawk) are installed natively alongside the host-proxy binary for controlled host CLI access.

### Scripts
- **setup-container.sh**: Configures container local dependencies, generates standard DNS routing templates, and creates SSH keys.
- **run-container.sh**: Provisions an isolated bridge network, bind-mounts the root `host-wrapper` directory read-only to the container, and launches an interactive Nix shell in the container.

### Architecture
This container mounts the `examples/container_project` directory as its active working directory. The Nix flake (`examples/container_project/flake.nix`) reads the read-only `/host-wrapper` bind-mount to compile and install `host-proxy` dynamically inside the container's shell PATH, mapping execution paths via an environment variable.
