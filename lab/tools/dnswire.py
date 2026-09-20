import random
import socket
import struct

QTYPES = {"A": 1, "NS": 2, "CNAME": 5, "NULL": 10, "MX": 15, "TXT": 16, "AAAA": 28, "HTTPS": 65}


def encode_query(name, qtype):
    wire = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\x00"
    header = struct.pack(">HHHHHH", random.getrandbits(16), 0x0100, 1, 0, 0, 0)
    return header + wire + struct.pack(">HH", QTYPES[qtype], 1)


def ask(sock, server, name, qtype, wait=0.3):
    sock.sendto(encode_query(name, qtype), (server, 53))
    sock.settimeout(wait)
    try:
        sock.recvfrom(4096)
    except (socket.timeout, OSError):
        pass
