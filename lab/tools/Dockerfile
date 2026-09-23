FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends hping3 nmap curl dnsutils iproute2 iputils-ping python3 ca-certificates \
        iperf3 iodine slowhttptest apache2-utils sshpass openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY *.py *.sh /lab/
RUN chmod +x /lab/*.sh

ENTRYPOINT ["/lab/entrypoint.sh"]
