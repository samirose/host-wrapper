#!/bin/sh
# This script is invoked by host-proxy to establish the SSH tunnel.
# You can customize SSH options, ports, or hostnames here.
exec ssh -q -T -i "./ssh/id_rsa" host.docker.internal host-wrapper
