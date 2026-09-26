#!/usr/bin/env python3
import argparse
import base64
import json
import random
import time
import urllib.request

INTERVAL_S = 10


def attr(key, value):
    if isinstance(value, bool):
        raise TypeError("booleans are not part of the contract")
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    if isinstance(value, float):
        return {"key": key, "value": {"doubleValue": value}}
    return {"key": key, "value": {"stringValue": str(value)}}


def record(ts_ns, event, severity, attributes):
    return {
        "timeUnixNano": str(ts_ns),
        "eventName": event,
        "severityNumber": severity,
        "attributes": [attr(k, v) for k, v in attributes.items()],
    }


def flow(ts_ns, direction, transport, src, dst, sport, dport, packets, bytes_per_packet=700, syn=0, synack=0, fin=0, rst=0):
    ip_bytes = packets * bytes_per_packet
    return record(ts_ns, "netstream.flow", 9, {
        "network.io.direction": direction,
        "network.transport": transport,
        "source.address": src,
        "destination.address": dst,
        "source.port": sport,
        "destination.port": dport,
        "netstream.flow.interval_ms": INTERVAL_S * 1000,
        "netstream.flow.packets": packets,
        "netstream.flow.bytes.ip": ip_bytes,
        "netstream.flow.bytes.payload": max(ip_bytes - packets * 52, 0),
        "netstream.flow.tcp.syn": syn,
        "netstream.flow.tcp.synack": synack,
        "netstream.flow.tcp.fin": fin,
        "netstream.flow.tcp.rst": rst,
        "netstream.flow.aggregated": 0,
        "netstream.flow.size.le64": packets if bytes_per_packet <= 64 else 0,
        "netstream.flow.size.le128": packets if 64 < bytes_per_packet <= 128 else 0,
        "netstream.flow.size.le256": packets if 128 < bytes_per_packet <= 256 else 0,
        "netstream.flow.size.le512": packets if 256 < bytes_per_packet <= 512 else 0,
        "netstream.flow.size.le1024": packets if 512 < bytes_per_packet <= 1024 else 0,
        "netstream.flow.size.gt1024": packets if bytes_per_packet > 1024 else 0,
        "netstream.flow.iat.count": max(packets - 1, 0),
        "netstream.flow.iat.sum_us": INTERVAL_S * 1000000 if packets > 1 else 0,
        "netstream.flow.iat.sumsq_us": (INTERVAL_S * 1000000 // max(packets, 1)) ** 2 * max(packets - 1, 0),
    })


def entropy(name):
    from collections import Counter
    from math import log2
    counts = Counter(name.replace(".", ""))
    total = sum(counts.values())
    return -sum(c / total * log2(c / total) for c in counts.values())


def dns(ts_ns, client, resolver, qtype, name, unique_subdomains, transport="udp"):
    labels = name.split(".")
    characters = name.replace(".", "")
    return record(ts_ns, "netstream.dns.query", 9, {
        "network.io.direction": "receive",
        "network.transport": transport,
        "source.address": client,
        "destination.address": resolver,
        "dns.question.name": name,
        "netstream.dns.question.type": qtype,
        "netstream.dns.qname.length": len(name),
        "netstream.dns.qname.labels": len(labels),
        "netstream.dns.qname.longest_label": max(len(label) for label in labels),
        "netstream.dns.qname.entropy": round(entropy(name), 4),
        "netstream.dns.qname.digit_ratio": round(sum(ch.isdigit() for ch in characters) / len(characters), 4),
        "netstream.dns.unique_subdomains": unique_subdomains,
    })


def hit(ts_ns, src, domain, action):
    return record(ts_ns, "netstream.blocklist.hit", 13, {
        "source.address": src,
        "netstream.hit.domain": domain,
        "netstream.hit.action": action,
    })


def base32_name(rng, length):
    raw = bytes(rng.getrandbits(8) for _ in range(length))
    return base64.b32encode(raw).decode().lower().rstrip("=")


def generate(host, now_ns, minutes, rng):
    start_ns = now_ns - minutes * 60 * 10**9
    steps = minutes * 60 // INTERVAL_S
    records = []

    def at(step):
        return start_ns + step * INTERVAL_S * 10**9

    def minutes_ago(m):
        return int(steps - m * 60 / INTERVAL_S)

    clients = [f"10.0.1.{i}" for i in range(10, 16)]
    server = "10.0.2.10"
    services = [(443, 0.6), (80, 0.25), (22, 0.05), (53, 0.1)]
    resolver = "10.0.0.53"

    syn_flood = range(minutes_ago(45), minutes_ago(35))
    port_scan = range(minutes_ago(70), minutes_ago(65))
    tunnel = range(minutes_ago(25), minutes_ago(15))
    hits_burst = range(minutes_ago(52), minutes_ago(48))

    scan_ports = iter(range(1, 1025))
    tunnel_names = set()
    web_subdomains = ["www", "mail", "api", "cdn", "login"]
    web_domains = ["example.com", "example.org", "corp.test"]

    for step in range(steps):
        ts = at(step)

        for client in clients:
            for port, weight in services:
                if rng.random() > weight + 0.2:
                    continue
                packets = rng.randint(4, 60)
                connections = rng.randint(1, 3)
                records.append(flow(ts, "receive", "tcp", client, server, rng.randint(32768, 60999), port, packets,
                                    syn=connections, synack=0, fin=connections))
                records.append(flow(ts, "transmit", "tcp", server, client, port, rng.randint(32768, 60999), packets,
                                    syn=0, synack=connections, fin=connections))
        records.append(flow(ts, "receive", "icmp", clients[0], server, 0, 0, rng.randint(1, 4), 84))

        if step in syn_flood:
            for _ in range(40):
                source = f"203.0.113.{rng.randint(1, 250)}"
                packets = rng.randint(150, 400)
                records.append(flow(ts, "receive", "tcp", source, server, rng.randint(1024, 65000), 443, packets,
                                    bytes_per_packet=60, syn=packets, synack=rng.randint(0, 3), rst=rng.randint(0, 2)))

        if step in port_scan:
            for _ in range(7):
                port = next(scan_ports, None)
                if port is None:
                    break
                records.append(flow(ts, "receive", "tcp", "198.51.100.7", server, 41000, port, 2, 60,
                                    syn=1, rst=1 if port % 9 else 0))
                records.append(flow(ts, "transmit", "tcp", server, "198.51.100.7", port, 41000, 1, 60,
                                    synack=0 if port % 9 else 1, rst=1 if port % 9 else 0))

        for _ in range(rng.randint(5, 14)):
            client = rng.choice(clients)
            name = f"{rng.choice(web_subdomains)}.{rng.choice(web_domains)}"
            records.append(dns(ts + rng.randint(0, 9) * 10**9, client, resolver,
                               rng.choice(["A", "A", "A", "AAAA", "HTTPS"]), name, len(web_subdomains)))

        if step in tunnel:
            for _ in range(30):
                name = f"{base32_name(rng, rng.randint(24, 34))}.t.tunnel.example"
                tunnel_names.add(name)
                records.append(dns(ts + rng.randint(0, 9) * 10**9, "10.0.1.55", resolver,
                                   rng.choice(["TXT", "TXT", "NULL"]), name, min(len(tunnel_names), 1000)))

        if step in hits_burst:
            action = "observed" if step < hits_burst.start + 4 else "quarantined"
            records.append(hit(ts, "10.0.1.99", "malware-c2.example", action))
        elif rng.random() < 0.01:
            records.append(hit(ts, rng.choice(clients), "ads.tracker.example", "dropped"))

    return records


def send(endpoint, host, batch):
    body = {
        "resourceLogs": [{
            "resource": {"attributes": [
                attr("service.name", "netstream-monitor-agent"),
                attr("host.id", host),
                attr("network.interface.name", "eth1"),
            ]},
            "scopeLogs": [{"scope": {"name": "seed"}, "logRecords": batch}],
        }]
    }
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/v1/logs",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()


def main():
    parser = argparse.ArgumentParser(description="Seed demo telemetry with synthetic attacks")
    parser.add_argument("--endpoint", default="http://127.0.0.1:4318")
    parser.add_argument("--hosts", nargs="+", default=["gateway-1", "gateway-2"])
    parser.add_argument("--minutes", type=int, default=90)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--batch", type=int, default=500)
    args = parser.parse_args()

    now_ns = time.time_ns()
    total = 0
    for index, host in enumerate(args.hosts):
        rng = random.Random(args.seed + index)
        records = generate(host, now_ns, args.minutes, rng)
        for offset in range(0, len(records), args.batch):
            send(args.endpoint, host, records[offset:offset + args.batch])
        total += len(records)
        print(f"{host}: {len(records)} records")

    print(f"seeded {total} records over the last {args.minutes} minutes")
    print("timeline (minutes ago): port scan 70-65, SYN flood 45-35, blocklist burst 52-48, DNS tunnel 25-15")


if __name__ == "__main__":
    main()
