#!/usr/bin/env python3
"""Bounded UDP log listener: udplog.py <outdir> <seconds> <port>...
Writes each datagram, timestamped, to <outdir>/udp-<port>.log. Exits after <seconds>."""
import os
import select
import socket
import sys
import time

outdir, secs, ports = sys.argv[1], float(sys.argv[2]), [int(p) for p in sys.argv[3:]]
os.makedirs(outdir, exist_ok=True)
socks, files = {}, {}
for p in ports:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", p))
    socks[s] = p
    files[p] = open(os.path.join(outdir, f"udp-{p}.log"), "a", buffering=1)
end = time.time() + secs
while (left := end - time.time()) > 0:
    r, _, _ = select.select(list(socks), [], [], left)
    for s in r:
        data, addr = s.recvfrom(65535)
        f = files[socks[s]]
        for line in data.decode(errors="replace").splitlines():
            f.write(f"{time.strftime('%H:%M:%S')} {addr[0]} {line}\n")
