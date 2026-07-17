#!/usr/bin/env sh
# check_dependency_direction.sh — grep-enforced, one-direction dependency rule
# between vanilla's top-level modules (docs/ARCHITECTURE.md):
#
#   core <- { socket, transport, tls, epoll, io_uring, kqueue, iocp, poll,
#             http1_1, http2, websocket, grpc, static_assets } <- server
#
#   - core imports no other vanilla module.
#   - socket/, transport/, tls/ and the event wrappers (epoll, io_uring,
#     kqueue, iocp, poll) never import a protocol module or the engine.
#   - protocol modules never import the engine; protocol-to-protocol imports
#     are downward only (websocket -> http1_1, grpc -> http2).
#   - server/backend_* is the single sanctioned meeting point of platform +
#     transport + protocol, so server/ may import everything.
#
# Run from the repo root. Exits non-zero on any violation.

set -u

fail=0

# check_no_import <dir> <egrep-alternation-of-forbidden-top-level-modules>
check_no_import() {
    dir=$1
    forbidden=$2
    [ -d "$dir" ] || return 0
    bad=$(grep -rnE "^import[[:space:]]+($forbidden)(\.|[[:space:]]|\{|$)" \
        --include='*.v' "$dir" 2>/dev/null || true)
    if [ -n "$bad" ]; then
        echo "DEPENDENCY VIOLATION: $dir/ must not import: $forbidden"
        echo "$bad"
        echo
        fail=1
    fi
}

protocols='http1_1|http2|websocket|grpc'
wrappers='epoll|io_uring|kqueue|iocp|poll'

# core is the protocol-neutral floor: no vanilla imports at all.
check_no_import core "server|socket|transport|tls|$wrappers|$protocols|static_assets|testkit|vtest|pg_async"

# listen side, client transports, tls, event wrappers: bytes and fds only.
for d in socket transport tls epoll io_uring kqueue iocp poll; do
    check_no_import "$d" "server|$protocols|static_assets|testkit|vtest|pg_async"
done

# protocol modules: never the engine; protocol imports downward only.
check_no_import http1_1 'server|http2|websocket|grpc'
check_no_import http2 'server|websocket|grpc'
check_no_import websocket 'server|http2|grpc'
check_no_import grpc 'server|websocket|http1_1'

# static_assets serves through the handler contract: core + http1_1 only.
check_no_import static_assets 'server|http2|websocket|grpc'

# testkit stays dependency-free towards vanilla (docs it relies only on net/time).
check_no_import testkit "server|socket|transport|tls|$wrappers|$protocols|static_assets|vtest|pg_async"

if [ "$fail" -ne 0 ]; then
    echo 'Dependency direction check FAILED (rule: docs/ARCHITECTURE.md).'
    exit 1
fi
echo 'Dependency direction check OK.'
