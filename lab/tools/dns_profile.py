import argparse
import hashlib
import os
import random
import socket
import time

from dnswire import ask

DKIM_SELECTORS = ["default", "google", "selector1", "selector2", "k1", "mail", "s1"]
DKIM_DOMAINS = ["example.com", "corp.test", "university.test", "news.test", "mail.corp.test"]
CDN_DOMAINS = ["cdn.video.test", "assets.news.test", "edge.shop.test"]
REPUTATION_DOMAINS = ["rep.av-lookup.test", "hash.filescan.test"]


def cdn_query():
    token = os.urandom(random.randint(6, 10)).hex()
    return f"{token}.{random.choice(CDN_DOMAINS)}", random.choice(["A", "A", "AAAA"])


def dkim_query():
    kind = random.random()
    domain = random.choice(DKIM_DOMAINS)
    if kind < 0.6:
        return f"{random.choice(DKIM_SELECTORS)}._domainkey.{domain}", "TXT"
    if kind < 0.8:
        return f"_dmarc.{domain}", "TXT"
    return domain, "TXT"


def reputation_query():
    digest = hashlib.sha1(os.urandom(16)).hexdigest()
    return f"{digest}.{random.choice(REPUTATION_DOMAINS)}", "A"


KINDS = {"cdn": cdn_query, "dkim": dkim_query, "reputation": reputation_query}


def main():
    parser = argparse.ArgumentParser(description="Legitimate DNS traffic that resembles tunnelling by name features")
    parser.add_argument("--server", default="10.20.0.10")
    parser.add_argument("--kind", choices=sorted(KINDS), required=True)
    parser.add_argument("--rate", type=float, default=20.0)
    parser.add_argument("--duration", type=float, default=30.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    interval = 1.0 / args.rate
    deadline = time.monotonic() + args.duration
    next_send = time.monotonic()
    sent = 0

    while time.monotonic() < deadline:
        name, qtype = KINDS[args.kind]()
        ask(sock, args.server, name, qtype, wait=min(interval, 0.05))
        sent += 1
        next_send += interval
        pause = next_send - time.monotonic()
        if pause > 0:
            time.sleep(pause)

    print(f"sent {sent} queries")


if __name__ == "__main__":
    main()
