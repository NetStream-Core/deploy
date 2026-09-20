#!/bin/sh
set -eu

lan_ip=${LAN_IP:-10.10.0.2}
interface=$(ip -o -4 addr show | awk -v ip="$lan_ip" 'index($4, ip "/") == 1 {print $2}')

if [ -z "$interface" ]; then
    echo "no interface with address $lan_ip" >&2
    exit 1
fi

export NETWORK_INTERFACE=$interface
exec network-monitor-agent
