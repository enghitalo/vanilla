#!/usr/bin/env python3
"""A scriptable fake third-party HTTP(S) API for examples/https_upstream's tests.

usage: fake_upstream.py --port-file F --stats-file S [--tls CERTDIR] [--cert server|wronghost]

Listens on 127.0.0.1:<ephemeral> (the port is written to --port-file once it
listens). With --tls it serves TLS 1.3 with CERTDIR/<cert>.crt / .key (from
pg_async/testdata/gen_test_ca.sh). Keep-alive HTTP/1.1; the path picks the answer:

  /ok           200, Content-Length JSON
  /chunked      200, chunked body "hello world" with a trailer
  /continue     100 Continue, then 201 Created "ok"
  /nocontent    204
  /connclose    200 + Connection: close, then closes
  /close        200, body delimited by closing the connection (TLS: close_notify first)
  /trunc        200, close-delimited body, then a bare close (TLS: no close_notify)
  /idleclose    200, then closes the idle connection after 100 ms
  /drop         reads the request, closes without answering
  /slow         never answers (until the client goes away)
  /echo         200, the request body's length and sha256 (hex)
  /delay/<ms>   200, after <ms> milliseconds
  /big/<n>      200, an n-byte body
  /e413         413 + Connection: close right after the head; reads nothing more for 1 s
  /cont100      100 Continue right after the head, then as /echo once the body is in
  /tickets      (TLS) stops reading, sends 2 TLS 1.3 session tickets mid-upload, then as /echo

The stats file holds key=value lines: accepted, handshakes, requests, and
path:<path>=<count>.
"""
import argparse
import hashlib
import os
import select
import socket
import ssl
import sys
import threading
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port-file", required=True)
ap.add_argument("--stats-file", required=True)
ap.add_argument("--tls")
ap.add_argument("--cert", default="server")
args = ap.parse_args()

ctx = None
if args.tls:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(os.path.join(args.tls, args.cert + ".crt"), os.path.join(args.tls, args.cert + ".key"))

lock = threading.Lock()
stats = {"accepted": 0, "handshakes": 0, "requests": 0}


def bump(key):
    with lock:
        stats[key] = stats.get(key, 0) + 1
        tmp = args.stats_file + ".tmp"
        with open(tmp, "w") as f:
            for k, v in stats.items():
                f.write("%s=%d\n" % (k, v))
        os.replace(tmp, args.stats_file)


def read_head(s, buf):
    while b"\r\n\r\n" not in buf:
        d = s.recv(65536)
        if not d:
            return None, buf
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head, rest


def content_length(head):
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            return int(v.strip())
    return 0


def new_session_tickets(conn, n):
    """Makes OpenSSL send n TLS 1.3 NewSessionTicket messages now, mid-request
    (pg_async/testdata/fake_pg.py has the same helper): the ssl module has no
    call for it, so SSL_new_session_ticket is reached through ctypes, and
    do_handshake() flushes the tickets out."""
    import ctypes
    lib = ctypes.CDLL(ssl._ssl.__file__)
    for name in ('SSL_version', 'SSL_is_server', 'SSL_new_session_ticket'):
        getattr(lib, name).argtypes = [ctypes.c_void_p]
    off = object.__basicsize__ + ctypes.sizeof(ctypes.c_void_p)
    ptr = ctypes.c_void_p.from_address(id(conn._sslobj) + off).value
    if not ptr or lib.SSL_version(ptr) != 0x0304 or lib.SSL_is_server(ptr) != 1:
        raise RuntimeError('fake_upstream: cannot reach the SSL* of this connection')
    for _ in range(n):
        if lib.SSL_new_session_ticket(ptr) != 1:
            raise RuntimeError('fake_upstream: SSL_new_session_ticket failed')
    conn.do_handshake()
    bump("tickets")


def wait_closed(s, secs):
    """Block until the peer closes (or secs pass), answering nothing."""
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([s], [], [], 0.05)
        if r:
            try:
                if isinstance(s, ssl.SSLSocket):
                    if not s.recv(1):
                        return
                elif not s.recv(1, socket.MSG_PEEK):
                    return
            except Exception:
                return


def serve(raw):
    bump("accepted")
    s = raw
    if ctx is not None:
        try:
            raw.settimeout(5)
            s = ctx.wrap_socket(raw, server_side=True)
        except Exception:
            raw.close()
            return
        bump("handshakes")
    s.settimeout(10)
    buf = b""
    try:
        while True:
            head, buf = read_head(s, buf)
            if head is None:
                s.close()
                return
            line = head.split(b"\r\n", 1)[0].split(b" ")
            method, path = line[0], line[1].decode()
            bump("requests")
            bump("path:" + path)
            n = content_length(head)
            if path == "/tickets" and isinstance(s, ssl.SSLSocket):
                # Let the upload fill the socket (a record of the client's left
                # pending), then send TLS 1.3 tickets into it, then read on.
                time.sleep(0.2)
                new_session_tickets(s, 2)
                time.sleep(0.2)
            if path == "/cont100":
                # An interim answer right after the head, then the whole body.
                s.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            if path == "/e413":
                s.sendall(b"HTTP/1.1 413 Content Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
                time.sleep(1.0)
                s.close()
                return
            while len(buf) < n:
                d = s.recv(65536)
                if not d:
                    s.close()
                    return
                buf += d
            body, buf = buf[:n], buf[n:]
            if path == "/ok":
                b = b'{"status":"paid"}'
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(b)
                          + (b"" if method == b"HEAD" else b))
            elif path == "/chunked":
                s.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                          b"5\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: abc\r\n\r\n")
            elif path == "/continue":
                s.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
                time.sleep(0.02)
                s.sendall(b"HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")
            elif path == "/nocontent":
                s.sendall(b"HTTP/1.1 204 No Content\r\n\r\n")
            elif path == "/connclose":
                s.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok")
                s.close()
                return
            elif path == "/close":
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose-delimited body")
                if isinstance(s, ssl.SSLSocket):
                    try:
                        s.unwrap()  # close_notify
                    except Exception:
                        pass
                s.close()
                return
            elif path == "/trunc":
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\ncut sho")
                s.shutdown(socket.SHUT_RDWR)  # a bare FIN: an SSLSocket sends no close_notify here
                s.close()
                return
            elif path == "/idleclose":
                b = b'{"status":"paid"}'
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(b) + b)
                time.sleep(0.1)
                s.close()
                return
            elif path == "/drop":
                s.close()
                return
            elif path == "/slow":
                wait_closed(s, 60)
                s.close()
                return
            elif path == "/echo" or path == "/cont100" or path == "/tickets":
                b = b"%d %s" % (len(body), hashlib.sha256(body).hexdigest().encode())
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(b) + b)
            elif path.startswith("/delay/"):
                time.sleep(int(path[7:]) / 1000.0)
                b = b'{"status":"paid"}'
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(b) + b)
            elif path.startswith("/big/"):
                size = int(path[5:])
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % size + b"x" * size)
            else:
                s.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    except Exception:
        try:
            s.close()
        except Exception:
            pass


ls = socket.socket()
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", 0))
ls.listen(128)
tmp = args.port_file + ".tmp"
with open(tmp, "w") as f:
    f.write(str(ls.getsockname()[1]))
os.replace(tmp, args.port_file)
bump("started")
while True:
    c, _ = ls.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
