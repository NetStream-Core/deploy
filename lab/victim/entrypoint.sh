#!/bin/sh
set -eu

ip route add "$ROUTE_TO" via "$GATEWAY"

dnsmasq --keep-in-foreground --no-resolv --no-hosts --address="/#/$SELF_IP" &
exec nginx -g 'daemon off;'
