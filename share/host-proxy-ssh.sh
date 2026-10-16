#!/bin/sh

# Invoked by host-proxy inside the guest to open the channel to host-wrapper.
#
# Installed unchanged from share/host-proxy-ssh.sh in the host-wrapper
# repository. Everything host-specific is in ssh/host-wrapper.env.

# Relative paths below are resolved against this script's directory.
cd "$(dirname "$0")" || exit 1

# Values already in the environment take precedence over the host-provided
# file, so a single run can be redirected without editing anything.
env_gateway="$HOST_GATEWAY"
env_user="$HOST_USER"

if [ -f ./ssh/host-wrapper.env ]; then
    . ./ssh/host-wrapper.env
fi

[ -n "$env_gateway" ] && HOST_GATEWAY="$env_gateway"
[ -n "$env_user" ] && HOST_USER="$env_user"

: "${HOST_KEY:=./ssh/id_ed25519}"
: "${HOST_KEY_ALIAS:=host-wrapper}"

# The first default route with a "via": one without a gateway, a point-to-point
# link say, is not the host.
if [ -z "$HOST_GATEWAY" ]; then
    HOST_GATEWAY=$(ip route show default 2>/dev/null |
        awk '$1 == "default" { for (i = 2; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
fi

if [ -z "$HOST_GATEWAY" ]; then
    echo "host-proxy-ssh: cannot determine the host gateway address." >&2
    echo "  The guest has no default route with a gateway, or 'ip' is missing." >&2
    echo "  Set HOST_GATEWAY in ssh/host-wrapper.env or in the environment," >&2
    echo "  for example HOST_GATEWAY=host.docker.internal under Docker Desktop." >&2
    exit 1
fi

if [ -z "$HOST_USER" ]; then
    echo "host-proxy-ssh: no host login user configured." >&2
    echo "  Set HOST_USER in ssh/host-wrapper.env or in the environment." >&2
    echo "  It must name the host account, which is rarely the guest's own user." >&2
    exit 1
fi

# Host identity is verified against HOST_KEY_ALIAS rather than the address, so
# a gateway that moves between systems never causes an unverified connection.
exec ssh -T \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes \
    -o GlobalKnownHostsFile=/dev/null \
    -o UserKnownHostsFile=./ssh/known_hosts \
    -o HostKeyAlias="$HOST_KEY_ALIAS" \
    -i "$HOST_KEY" \
    "$HOST_USER@$HOST_GATEWAY" host-wrapper
