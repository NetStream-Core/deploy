FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 ca-certificates tcpdump \
    && rm -rf /var/lib/apt/lists/*

COPY artifacts/network-monitor-agent /usr/local/bin/network-monitor-agent
COPY artifacts/public_suffix_list.dat /etc/netstream/public_suffix_list.dat
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
