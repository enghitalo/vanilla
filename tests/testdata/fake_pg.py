"""Minimal fake PostgreSQL server for pg_async's connection-loss tests
(tests/pg_async_conn_loss_test.v, vanilla#191). Python 3, stdlib only.

    python3 fake_pg.py <port-file> [lifetime_s]

Listens on 127.0.0.1:<ephemeral>, writes the port to <port-file>, and serves
each connection on a thread: StartupMessage, real SCRAM-SHA-256 (RFC 5802 /
7677 — the server signature is computed for real, so pg_async's check passes),
AuthenticationOk, ReadyForQuery. Then it answers extended-protocol queries
(Parse/Bind/Describe/Execute/Sync), choosing the reply from the SQL text:

  select <n>        one int4 row holding <n>
  select backend    one int4 row holding this connection's id (0, 1, 2, ...
                    in accept order) — tells a re-dialed connection apart
  select 1/0        ERROR 22012 "division by zero", then ReadyForQuery
  select fatal      FATAL 57P01 instead of a reply, then close (a backend
                    terminated mid-query, as pg_terminate_backend does)

and a suffix decides what happens to the connection after a reply:

  -- then-fin       close at once: the reply and the FIN arrive together (in
                    one segment on Linux, via TCP_CORK)
  -- then-close     close 50 ms later (an idle connection closed by the server)
  -- then-fatal     50 ms later send FATAL 57P01, then close (an idle backend
                    terminated by pg_terminate_backend)

A close is a half-close (SHUT_WR) followed by draining whatever the client
still sends until it hangs up, so the client always sees a clean EOF rather
than a reset racing the bytes already sent to it.
"""
import base64
import hashlib
import hmac
import os
import socket
import struct
import sys
import threading
import time

PASSWORD = 'secret'
SALT = b'vanilla-fake-pg-salt'
ITER = 4096
FATAL_57P01 = (b'SFATAL\x00VFATAL\x00C57P01\x00'
               b'Mterminating connection due to administrator command\x00\x00')


def msg(typ, payload):
    return typ + struct.pack('!I', 4 + len(payload)) + payload


def recv_exact(conn, n):
    buf = b''
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_typed(conn):
    typ = recv_exact(conn, 1)
    ln = struct.unpack('!I', recv_exact(conn, 4))[0]
    return typ, recv_exact(conn, ln - 4)


def authenticate(conn):
    ln = struct.unpack('!I', recv_exact(conn, 4))[0]
    recv_exact(conn, ln - 4)  # StartupMessage
    conn.sendall(msg(b'R', struct.pack('!I', 10) + b'SCRAM-SHA-256\x00\x00'))
    _, body = read_typed(conn)  # SASLInitialResponse
    mech_end = body.index(b'\x00')
    data_len = struct.unpack('!i', body[mech_end + 1:mech_end + 5])[0]
    client_first_bare = body[mech_end + 5:mech_end + 5 + data_len].decode()[3:]
    cnonce = dict(kv.split('=', 1) for kv in client_first_bare.split(','))['r']
    nonce = cnonce + base64.b64encode(os.urandom(12)).decode()
    server_first = f'r={nonce},s={base64.b64encode(SALT).decode()},i={ITER}'
    conn.sendall(msg(b'R', struct.pack('!I', 11) + server_first.encode()))
    _, body = read_typed(conn)  # SASLResponse
    client_final = body.decode()
    without_proof = client_final[:client_final.index(',p=')]
    auth_message = f'{client_first_bare},{server_first},{without_proof}'.encode()
    salted = hashlib.pbkdf2_hmac('sha256', PASSWORD.encode(), SALT, ITER)
    server_key = hmac.new(salted, b'Server Key', hashlib.sha256).digest()
    sig = hmac.new(server_key, auth_message, hashlib.sha256).digest()
    conn.sendall(msg(b'R', struct.pack('!I', 12) + b'v=' + base64.b64encode(sig)))
    conn.sendall(msg(b'R', struct.pack('!I', 0)) + msg(b'Z', b'I'))


def int4_reply(value):
    field = b'?column?\x00' + struct.pack('!IhIhih', 0, 0, 23, 4, -1, 1)
    return (msg(b'1', b'') + msg(b'2', b'') + msg(b'T', struct.pack('!h', 1) + field)
            + msg(b'D', struct.pack('!hI', 1, 4) + struct.pack('!i', value))
            + msg(b'C', b'SELECT 1\x00') + msg(b'Z', b'I'))


def close(conn):
    try:
        conn.shutdown(socket.SHUT_WR)
        conn.settimeout(10)
        while conn.recv(4096):
            pass
    except OSError:
        pass
    conn.close()


def handle(conn, cid):
    try:
        authenticate(conn)
        print(f'fake-pg conn {cid}: authenticated', flush=True)
        query = ''
        while True:
            typ, body = read_typed(conn)
            if typ == b'X':
                conn.close()
                return
            if typ == b'P':
                query = body.split(b'\x00')[1].decode()
                continue
            if typ != b'S':
                continue
            sql, _, then = query.partition(' -- ')
            arg = sql.split()[1] if len(sql.split()) > 1 else ''
            if arg == 'fatal':
                conn.sendall(msg(b'E', FATAL_57P01))
                print(f'fake-pg conn {cid}: FATAL 57P01 instead of a reply', flush=True)
                close(conn)
                return
            if arg == '1/0':
                conn.sendall(msg(b'E', b'SERROR\x00VERROR\x00C22012\x00Mdivision by zero\x00\x00')
                             + msg(b'Z', b'I'))
                continue
            if then == 'then-fin' and hasattr(socket, 'TCP_CORK'):
                # Hold the reply so shutdown() tacks the FIN onto the same
                # segment: the client then sees both in one read (Linux).
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CORK, 1)
            conn.sendall(int4_reply(cid if arg == 'backend' else int(arg)))
            if then == 'then-fin':
                print(f'fake-pg conn {cid}: reply + FIN', flush=True)
                close(conn)
                return
            if then in ('then-close', 'then-fatal'):
                time.sleep(0.05)
                if then == 'then-fatal':
                    conn.sendall(msg(b'E', FATAL_57P01))
                print(f'fake-pg conn {cid}: closed by the server ({then})', flush=True)
                close(conn)
                return
    except (EOFError, OSError):
        conn.close()


def main():
    port_file = sys.argv[1]
    lifetime = float(sys.argv[2]) if len(sys.argv) > 2 else 120
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', 0))
    srv.listen(64)
    tmp = port_file + '.tmp'
    with open(tmp, 'w') as f:
        f.write(str(srv.getsockname()[1]))
    os.replace(tmp, port_file)  # the reader never sees a half-written port
    deadline = time.time() + lifetime
    srv.settimeout(0.5)
    cid = 0
    while time.time() < deadline:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        threading.Thread(target=handle, args=(conn, cid), daemon=True).start()
        cid += 1


if __name__ == '__main__':
    main()
