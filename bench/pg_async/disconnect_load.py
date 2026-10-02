#!/usr/bin/env python3
"""disconnect_load.py — clients that hang up while their request is parked.

Each thread loops: connect, send one GET, wait --park-ms (the request is now
parked on its pooled PostgreSQL connection), close without reading the reply.
The close reaches the server as a fresh readable edge on a parked connection,
which takes the tombstone path (the reply is consumed in order, then
discarded). Prints the number of requests sent. Python 3 stdlib only.

usage: disconnect_load.py --port P [--path /dbslow] [--threads 8] [--duration 20] [--park-ms 1]
"""

import argparse
import socket
import threading
import time


def worker(args, deadline, counts, i):
    req = f'GET {args.path} HTTP/1.1\r\nHost: x\r\n\r\n'.encode()
    n = 0
    while time.time() < deadline:
        try:
            s = socket.create_connection(('127.0.0.1', args.port))
            s.sendall(req)
            time.sleep(args.park_ms / 1000.0)
            s.close()
            n += 1
        except OSError:
            time.sleep(0.01)
    counts[i] = n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--path', default='/dbslow')
    ap.add_argument('--threads', type=int, default=8)
    ap.add_argument('--duration', type=float, default=20.0)
    ap.add_argument('--park-ms', type=float, default=1.0)
    args = ap.parse_args()
    deadline = time.time() + args.duration
    counts = [0] * args.threads
    threads = [threading.Thread(target=worker, args=(args, deadline, counts, i)) for i in range(args.threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print(sum(counts))


if __name__ == '__main__':
    main()
