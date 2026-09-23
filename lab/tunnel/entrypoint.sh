#!/bin/sh
set -eu

ip route add "$ROUTE_TO" via "$GATEWAY"

mkdir -p /srv
dd if=/dev/zero of=/srv/big bs=1M count=64 status=none

iodined -f -c -P "$TUNNEL_PASSWORD" 10.99.0.1/24 "$TUNNEL_DOMAIN" &
until ip addr show dns0 2>/dev/null | grep -q 10.99.0.1; do sleep 0.2; done

cd /srv
exec python3 -m http.server 8000 --bind 10.99.0.1
