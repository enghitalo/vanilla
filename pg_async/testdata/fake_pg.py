#!/usr/bin/env python3
"""fake_pg.py — a scriptable fake PostgreSQL server for pg_async's tests.

Python 3, standard library only. It speaks protocol 3.0 the way pg_async uses
it: StartupMessage, then SCRAM-SHA-256 (the server signature is computed for
real, so pg_async's verification passes) or trust auth, ParameterStatus,
BackendKeyData, ReadyForQuery; then the extended-query flow — every message up
to a Sync is one group, answered with ParseComplete, BindComplete,
RowDescription, DataRows, CommandComplete (or an ErrorResponse) and
ReadyForQuery. Results are binary, as pg_async's Bind asks for.

What a query returns is decided by its SQL text (see answer_statement):
  select 1/0 ...                     ERROR 22012 division_by_zero
  select N  /  select N::int4        one int4 row: N
  select g from generate_series(1, N) g    N int4 rows: 1..N
  select $1::int4, $2::text, ...     one row echoing the parameters (int4,
                                     int8, bool or text, from each cast)
  begin / commit / rollback          the transaction status in ReadyForQuery
  anything else                      ERROR 0A000 naming the unsupported text

Failure modes are chosen per run, so a test can make the server-side event it
needs happen deterministically:
  --close delayed|immediate|fatal   after answering --close-after queries
      (default 1) on a connection: delayed = close 50 ms after the reply;
      immediate = the reply and the FIN together; fatal = the reply, then
      FATAL 57P01 (administrator command) 50 ms later, then close
  --hang-after K                    the K-th and later queries of a connection
      are never answered (the connection stays open)
  --auth scram|trust                (default scram; password --password)

--stats-file PATH keeps `key=value` counters (accepted, authenticated, queries,
server_closes, ssl_requests, cancel_requests) up to date, so a test can assert
on what the server saw. Every connection is logged to stderr.

usage: fake_pg.py --port-file PATH [options]
"""

import argparse
import base64
import hashlib
import hmac
import os
import re
import socket
import struct
import sys
import threading
import time

PROTOCOL_3_0 = 196608
SSL_REQUEST = 80877103
CANCEL_REQUEST = 80877102
GSSENC_REQUEST = 80877104

OID_BOOL = 16
OID_INT8 = 20
OID_INT4 = 23
OID_TEXT = 25

SALT = b'vanilla-fake-pg-salt'
ITERATIONS = 4096

ARGS = None
STATS = {}
STATS_LOCK = threading.Lock()


def log(cid, text):
    print(f'fake-pg conn {cid}: {text}', file=sys.stderr, flush=True)


def bump(key, n=1):
    with STATS_LOCK:
        STATS[key] = STATS.get(key, 0) + n
        if ARGS.stats_file:
            tmp = ARGS.stats_file + '.tmp'
            with open(tmp, 'w') as f:
                for k in sorted(STATS):
                    f.write(f'{k}={STATS[k]}\n')
            os.replace(tmp, ARGS.stats_file)


# ── wire helpers ────────────────────────────────────────────────────────────


def msg(typ, payload=b''):
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
    if ln < 4:
        raise EOFError
    return typ, recv_exact(conn, ln - 4)


def cstr(b, pos):
    end = b.index(b'\x00', pos)
    return b[pos:end], end + 1


def error_response(severity, code, message):
    sev = severity.encode()
    return msg(b'E', b'S' + sev + b'\x00V' + sev + b'\x00C' + code.encode() + b'\x00M' +
               message.encode() + b'\x00\x00')


def row_description(cols):
    """cols: [(name, type_oid, typlen)] — every column in binary format (1)."""
    out = struct.pack('!h', len(cols))
    for name, oid, typlen in cols:
        out += name.encode() + b'\x00' + struct.pack('!IhIhih', 0, 0, oid, typlen, -1, 1)
    return msg(b'T', out)


def data_row(values):
    """values: [bytes or None (SQL NULL)]."""
    out = struct.pack('!h', len(values))
    for v in values:
        if v is None:
            out += struct.pack('!i', -1)
        else:
            out += struct.pack('!i', len(v)) + v
    return msg(b'D', out)


# ── auth ────────────────────────────────────────────────────────────────────


def scram_auth(conn):
    conn.sendall(msg(b'R', struct.pack('!I', 10) + b'SCRAM-SHA-256\x00\x00'))
    typ, body = read_typed(conn)  # SASLInitialResponse
    if typ != b'p':
        raise EOFError
    mech, pos = cstr(body, 0)
    if mech != b'SCRAM-SHA-256':
        raise EOFError
    data_len = struct.unpack('!i', body[pos:pos + 4])[0]
    client_first = body[pos + 4:pos + 4 + data_len].decode()
    if not client_first.startswith('n,,'):
        raise EOFError  # channel binding is not offered
    client_first_bare = client_first[3:]
    cnonce = dict(kv.split('=', 1) for kv in client_first_bare.split(','))['r']
    nonce = cnonce + base64.b64encode(os.urandom(12)).decode()
    server_first = f'r={nonce},s={base64.b64encode(SALT).decode()},i={ITERATIONS}'
    conn.sendall(msg(b'R', struct.pack('!I', 11) + server_first.encode()))
    typ, body = read_typed(conn)  # SASLResponse
    if typ != b'p':
        raise EOFError
    client_final = body.decode()
    without_proof = client_final[:client_final.index(',p=')]
    proof = base64.b64decode(client_final[client_final.index(',p=') + 3:])
    auth_message = f'{client_first_bare},{server_first},{without_proof}'.encode()
    salted = hashlib.pbkdf2_hmac('sha256', ARGS.password.encode(), SALT, ITERATIONS)
    client_key = hmac.new(salted, b'Client Key', hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    client_sig = hmac.new(stored_key, auth_message, hashlib.sha256).digest()
    if bytes(a ^ b for a, b in zip(client_sig, proof)) != client_key:
        conn.sendall(error_response('FATAL', '28P01', 'password authentication failed for user'))
        raise EOFError
    server_key = hmac.new(salted, b'Server Key', hashlib.sha256).digest()
    sig = hmac.new(server_key, auth_message, hashlib.sha256).digest()
    conn.sendall(msg(b'R', struct.pack('!I', 12) + b'v=' + base64.b64encode(sig)))


def startup(conn, cid):
    """Reads the startup packet (answering an SSLRequest with 'N' first) and
    authenticates. Returns the startup parameters, or None for a request that
    ends the connection (CancelRequest)."""
    while True:
        ln = struct.unpack('!I', recv_exact(conn, 4))[0]
        body = recv_exact(conn, ln - 4)
        code = struct.unpack('!I', body[:4])[0]
        if code == SSL_REQUEST:
            bump('ssl_requests')
            conn.sendall(b'N')
            continue
        if code == GSSENC_REQUEST:
            conn.sendall(b'N')
            continue
        if code == CANCEL_REQUEST:
            bump('cancel_requests')
            log(cid, 'CancelRequest')
            return None
        if code != PROTOCOL_3_0:
            raise EOFError
        params = {}
        pos = 4
        while pos < len(body) and body[pos] != 0:
            k, pos = cstr(body, pos)
            v, pos = cstr(body, pos)
            params[k.decode()] = v.decode()
        break
    if ARGS.auth == 'scram':
        scram_auth(conn)
    conn.sendall(msg(b'R', struct.pack('!I', 0)))
    status = b''
    for k, v in (('server_version', '16.0 (vanilla fake_pg)'), ('integer_datetimes', 'on'),
                 ('client_encoding', 'UTF8'), ('TimeZone', 'UTC')):
        status += msg(b'S', k.encode() + b'\x00' + v.encode() + b'\x00')
    status += msg(b'K', struct.pack('!I', 1000 + cid) + os.urandom(4))
    # Counted before the client can see ReadyForQuery, so a test that asserts
    # right after its connect returns never reads a stale counter.
    bump('authenticated')
    log(cid, f'authenticated ({ARGS.auth}) user={params.get("user", "")}')
    conn.sendall(status + msg(b'Z', b'I'))
    return params


# ── queries ─────────────────────────────────────────────────────────────────

CAST = re.compile(r'\$(\d+)(?:::(\w+))?')
LITERAL = re.compile(r'^\s*select\s+(-?\d+)(?:::int4)?\s*$', re.I)
SERIES = re.compile(r'generate_series\(\s*1\s*,\s*(\d+)\s*\)', re.I)


def encode_param(value, cast):
    if value is None:
        return None, OID_TEXT, -1
    if cast == 'int4':
        return struct.pack('!i', int(value)), OID_INT4, 4
    if cast == 'int8':
        return struct.pack('!q', int(value)), OID_INT8, 8
    if cast == 'bool':
        return (b'\x01' if value in (b't', b'true', b'1') else b'\x00'), OID_BOOL, 1
    return value, OID_TEXT, -1


def answer_statement(sql, params, tx):
    """One statement's reply after its ParseComplete/BindComplete: returns
    (bytes, transaction status after it, whether it failed)."""
    text = sql.strip().rstrip(';').strip()
    low = text.lower()
    if '1/0' in low.replace(' ', ''):
        return error_response('ERROR', '22012', 'division by zero'), tx, True
    if low in ('begin', 'start transaction'):
        return msg(b'n') + msg(b'C', b'BEGIN\x00'), b'T', False
    if low in ('commit', 'end'):
        tag = b'ROLLBACK' if tx == b'E' else b'COMMIT'
        return msg(b'n') + msg(b'C', tag + b'\x00'), b'I', False
    if low in ('rollback', 'abort'):
        return msg(b'n') + msg(b'C', b'ROLLBACK\x00'), b'I', False
    if tx == b'E':
        return error_response('ERROR', '25P02', 'current transaction is aborted, commands ignored '
                              'until end of transaction block'), b'E', True
    m = LITERAL.match(text)
    if m:
        return (row_description([('?column?', OID_INT4, 4)]) +
                data_row([struct.pack('!i', int(m.group(1)))]) + msg(b'C', b'SELECT 1\x00')), tx, False
    m = SERIES.search(text)
    if m:
        n = int(m.group(1))
        out = row_description([('g', OID_INT4, 4)])
        out += b''.join(data_row([struct.pack('!i', i)]) for i in range(1, n + 1))
        return out + msg(b'C', b'SELECT %d\x00' % n), tx, False
    casts = CAST.findall(text)
    if low.startswith('select') and casts:
        cols, vals = [], []
        for idx, cast in casts:
            i = int(idx) - 1
            if i >= len(params):
                return error_response('ERROR', '08P01', f'missing parameter ${idx}'), tx, True
            v, oid, typlen = encode_param(params[i], cast.lower())
            cols.append(('?column?', oid, typlen))
            vals.append(v)
        return row_description(cols) + data_row(vals) + msg(b'C', b'SELECT 1\x00'), tx, False
    return error_response('ERROR', '0A000', f'fake_pg does not support: {text[:80]}'), tx, True


def parse_bind_params(body):
    _, pos = cstr(body, 0)  # portal
    _, pos = cstr(body, pos)  # statement
    nfmt = struct.unpack('!h', body[pos:pos + 2])[0]
    pos += 2 + 2 * nfmt
    nparams = struct.unpack('!h', body[pos:pos + 2])[0]
    pos += 2
    params = []
    for _ in range(nparams):
        ln = struct.unpack('!i', body[pos:pos + 4])[0]
        pos += 4
        if ln < 0:
            params.append(None)
        else:
            params.append(body[pos:pos + ln])
            pos += ln
    return params


def serve(conn, cid):
    tx = b'I'
    queries = 0
    stmts = []  # [sql, params] of the current group (up to Sync)
    sql = ''
    while True:
        typ, body = read_typed(conn)
        if typ == b'X':
            log(cid, 'Terminate')
            return
        if typ == b'Q':
            # The simple-query protocol (psql) is not what pg_async speaks:
            # refuse it cleanly rather than leave the client waiting.
            conn.sendall(error_response('ERROR', '0A000', 'fake_pg speaks the extended query protocol only') +
                         msg(b'Z', tx))
            continue
        if typ == b'P':
            _, pos = cstr(body, 0)
            q, _ = cstr(body, pos)
            sql = q.decode()
        elif typ == b'B':
            stmts.append([sql, parse_bind_params(body)])
        elif typ == b'S':
            queries += 1
            bump('queries')
            if ARGS.hang_after and queries >= ARGS.hang_after:
                log(cid, f'query {queries}: hanging (never answered)')
                stmts = []
                continue
            reply = b''
            for stmt_sql, params in stmts:
                reply += msg(b'1') + msg(b'2')
                part, tx, failed = answer_statement(stmt_sql, params, tx)
                reply += part
                if failed:
                    # An explicit transaction is now aborted; an implicit one
                    # (no BEGIN) just ends. The server skips the rest of the
                    # group until Sync.
                    if tx == b'T':
                        tx = b'E'
                    break
            stmts = []
            reply += msg(b'Z', tx)
            if ARGS.close != 'none' and queries >= ARGS.close_after:
                close_after_reply(conn, cid, reply)
                return
            conn.sendall(reply)
        # Describe / Execute / Flush need no answer of their own here: the
        # whole group is answered at its Sync.


def close_after_reply(conn, cid, reply):
    bump('server_closes')
    if ARGS.close == 'immediate':
        conn.sendall(reply)
        conn.shutdown(socket.SHUT_RDWR)
        log(cid, 'answered, then closed IMMEDIATELY (reply + FIN together)')
        return
    conn.sendall(reply)
    time.sleep(0.05)
    if ARGS.close == 'fatal':
        conn.sendall(error_response('FATAL', '57P01', 'terminating connection due to administrator command'))
        log(cid, 'sent FATAL 57P01, closing')
    else:
        log(cid, 'answered, closing 50 ms later')
    conn.shutdown(socket.SHUT_RDWR)


def handle(conn, cid):
    try:
        if startup(conn, cid) is not None:
            serve(conn, cid)
    except (EOFError, OSError, ValueError, IndexError, struct.error):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port-file', required=True, help='written with the listening port once ready')
    ap.add_argument('--stats-file', default='')
    ap.add_argument('--auth', choices=('scram', 'trust'), default='scram')
    ap.add_argument('--password', default='secret')
    ap.add_argument('--close', choices=('none', 'delayed', 'immediate', 'fatal'), default='none')
    ap.add_argument('--close-after', type=int, default=1)
    ap.add_argument('--hang-after', type=int, default=0)
    ap.add_argument('--lifetime', type=float, default=300.0, help='exit after this many seconds')
    ARGS = ap.parse_args()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', 0))
    srv.listen(128)
    srv.settimeout(0.2)
    bump('accepted', 0)
    tmp = ARGS.port_file + '.tmp'
    with open(tmp, 'w') as f:
        f.write(str(srv.getsockname()[1]))
    os.replace(tmp, ARGS.port_file)  # atomic: the reader never sees a partial port
    deadline = time.time() + ARGS.lifetime
    cid = 0
    while time.time() < deadline:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        bump('accepted')
        threading.Thread(target=handle, args=(conn, cid), daemon=True).start()
        cid += 1


if __name__ == '__main__':
    main()
