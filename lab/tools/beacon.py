import argparse
import random
import socket
import time

from dnswire import ask


def main():
    parser = argparse.ArgumentParser(description="Periodic lookups of a blocklisted command-and-control domain")
    parser.add_argument("--server", default="10.20.0.10")
    parser.add_argument("--domain", default="malware-c2.example")
    parser.add_argument("--rate", type=float, default=2.0)
    parser.add_argument("--duration", type=float, default=30.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    deadline = time.monotonic() + args.duration
    sent = 0
    while time.monotonic() < deadline:
        ask(sock, args.server, args.domain, random.choice(["A", "TXT"]), wait=0.05)
        sent += 1
        time.sleep(1.0 / args.rate)
    print(f"sent {sent} queries")


if __name__ == "__main__":
    main()
