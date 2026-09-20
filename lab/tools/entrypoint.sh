#!/bin/sh
set -eu

ip route add "$ROUTE_TO" via "$GATEWAY"

exec "$@"
