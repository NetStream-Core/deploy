FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx-light dnsmasq iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
