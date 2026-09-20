import argparse
import base64
import os
import random
import socket
import time

from dnswire import ask


def tunnel_name(domain, payload_bytes, max_label):
    encoded = base64.b32encode(os.urandom(payload_bytes)).decode().lower().rstrip("=")
    labels = [encoded[i:i + max_label] for i in range(0, len(encoded), max_label)]
    return ".".join(labels + [domain])


def main():
    parser = argparse.ArgumentParser(description="Emulated DNS tunnel: payload chunks encoded into query names")
    parser.add_argument("--server", default="10.20.0.10")
    parser.add_argument("--domain", default="t.tunnel.example")
    parser.add_argument("--rate", type=float, default=20.0)
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--qtype", choices=["TXT", "NULL", "mixed"], default="mixed")
    parser.add_argument("--payload-min", type=int, default=24)
    parser.add_argument("--payload-max", type=int, default=34)
    parser.add_argument("--max-label", type=int, default=63)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    interval = 1.0 / args.rate
    deadline = time.monotonic() + args.duration
    next_send = time.monotonic()
    sent = 0

    while time.monotonic() < deadline:
        qtype = args.qtype if args.qtype != "mixed" else random.choice(["TXT", "TXT", "NULL"])
        name = tunnel_name(args.domain, random.randint(args.payload_min, args.payload_max), args.max_label)
        ask(sock, args.server, name, qtype, wait=min(interval, 0.05))
        sent += 1
        next_send += interval
        pause = next_send - time.monotonic()
        if pause > 0:
            time.sleep(pause)

    print(f"sent {sent} queries")


if __name__ == "__main__":
    main()
