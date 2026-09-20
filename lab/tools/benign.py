import argparse
import http.client
import random
import socket
import threading
import time

from dnswire import ask

SUBDOMAINS = ["www", "mail", "api", "cdn", "login", "static", "docs", "shop", "images"]
DOMAINS = ["example.com", "example.org", "corp.test", "university.test", "news.test", "video.test"]
PATHS = ["/", "/index.html", "/about", "/products", "/api/items", "/missing", "/static/app.js", "/login"]


def paced(rate, work):
    while True:
        time.sleep(random.expovariate(rate))
        try:
            work()
        except OSError:
            pass


def http_request(victim):
    connection = http.client.HTTPConnection(victim, 80, timeout=3)
    try:
        connection.request("GET", random.choice(PATHS))
        connection.getresponse().read()
    finally:
        connection.close()


def dns_query(victim, sock):
    name = f"{random.choice(SUBDOMAINS)}.{random.choice(DOMAINS)}"
    qtype = random.choices(["A", "AAAA", "HTTPS", "TXT"], weights=[60, 25, 10, 5])[0]
    ask(sock, victim, name, qtype)


def main():
    parser = argparse.ArgumentParser(description="Background traffic of an ordinary client")
    parser.add_argument("--victim", default="10.20.0.10")
    parser.add_argument("--http-rate", type=float, default=3.0)
    parser.add_argument("--dns-rate", type=float, default=3.0)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    workers = [
        threading.Thread(target=paced, args=(args.http_rate, lambda: http_request(args.victim)), daemon=True),
        threading.Thread(target=paced, args=(args.dns_rate, lambda: dns_query(args.victim, sock)), daemon=True),
    ]
    for worker in workers:
        worker.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
