FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 ca-certificates tcpdump \
    && rm -rf /var/lib/apt/lists/*

COPY artifacts/network-monitor-agent /usr/local/bin/network-monitor-agent
COPY artifacts/prog.bpf.o /usr/local/lib/netstream/prog.bpf.o
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
