#!/bin/sh
set -eu

ip route add "$ROUTE_TO" via "$GATEWAY"

dd if=/dev/urandom of=/var/www/html/big.bin bs=1M count=64 status=none
/usr/sbin/sshd
iperf3 --server --daemon
dnsmasq --keep-in-foreground --no-resolv --no-hosts --address="/#/$SELF_IP" &
exec nginx -g 'daemon off;'
