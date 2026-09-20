FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends hping3 nmap curl dnsutils iproute2 iputils-ping python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY *.py *.sh /lab/
RUN chmod +x /lab/*.sh

ENTRYPOINT ["/lab/entrypoint.sh"]
