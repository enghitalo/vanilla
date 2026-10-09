#!/usr/bin/env bash
# HTTP/2 (h2c) server-under-load memory harness — LOCAL only.
#
# The sibling of load.sh for the http2 path. load.sh drives with `wrk`, which
# speaks HTTP/1.1 only — pointed at an http2 example it would exercise the h1
# path, not the http2 codec. This drives with `h2load` (nghttp2), which speaks
# cleartext HTTP/2 with PRIOR KNOWLEDGE by default for http:// URLs — exactly
# what vanilla's http2 examples accept (no ALPN, no Upgrade).
#
# It answers the one thing micro-benchmarks can't: does RSS stay FLAT under
# sustained http2 load with `-gc none` (BEST_PRACTICES.md section 10)? A rising
# slope is a per-request leak — fatal under `-gc none`, where nothing is
# reclaimed.
#
#   bench/load_h2.sh                                  # examples/http2_cleartext, GET /
#   REQUESTS=4000000 CONNS=256 STREAMS=32 bench/load_h2.sh
#   GC=boehm bench/load_h2.sh                         # compare default GC vs -gc none
#
# Reports req/s (h2load), start / peak / end RSS, and the start->end slope.
# Run on a quiesced machine; NOT for hosted CI (a load test on shared,
# hardware-varying runners is too noisy — same reason ci_bench.sh does a
# same-runner A/B).

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

SRC="${1:-examples/http2_cleartext/src}"
URL_PATH="${2:-/}"
PORT="${3:-3000}"
REQUESTS="${REQUESTS:-2000000}"
CONNS="${CONNS:-256}"
STREAMS="${STREAMS:-32}"
GC="${GC:-none}" # none = production (-gc none); boehm = default GC

command -v h2load >/dev/null || { echo "ERROR: h2load not installed (apt install nghttp2-client)"; exit 2; }
command -v v >/dev/null || { echo "ERROR: v not installed"; exit 2; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 2; }

gcflag="-gc none"
[ "$GC" = boehm ] && gcflag=""
bin=$(mktemp -u /tmp/loadh2.XXXXXX)
srvlog=$(mktemp)
rssfile=$(mktemp)
samplerpid=0
srvpid=0
cleanup() {
	[ "$samplerpid" -ne 0 ] && kill "$samplerpid" 2>/dev/null
	[ "$srvpid" -ne 0 ] && kill "$srvpid" 2>/dev/null
	fuser -k "${PORT}/tcp" >/dev/null 2>&1
	rm -f "$bin" "$srvlog" "$rssfile"
}
trap cleanup EXIT

echo "=== h2c load: ${SRC}  ${URL_PATH}  (v -prod ${gcflag:--gc=default}) ==="
echo "=== ${REQUESTS} requests, ${CONNS} conns x ${STREAMS} streams ==="
v wipe-cache >/dev/null 2>&1 || true
# shellcheck disable=SC2086
v -prod $gcflag -o "$bin" "$SRC" >/dev/null 2>&1 || { echo "ERROR: build failed"; exit 2; }

fuser -k "${PORT}/tcp" >/dev/null 2>&1
sleep 0.3
"$bin" >"$srvlog" 2>&1 &
srvpid=$!

ready=0
for _ in $(seq 1 80); do
	curl -s -o /dev/null --max-time 1 "http://localhost:${PORT}${URL_PATH}" && {
		ready=1
		break
	}
	sleep 0.25
done
[ "$ready" = 1 ] || {
	echo "ERROR: server did not start:"
	tail -5 "$srvlog"
	exit 2
}

# VmRSS (kB) of the server process, sampled every 200 ms while it lives.
rss_kb() { awk '/VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null; }
start_rss=$(rss_kb "$srvpid")
(while kill -0 "$srvpid" 2>/dev/null; do
	rss_kb "$srvpid"
	sleep 0.2
done) >"$rssfile" &
samplerpid=$!

# h2c prior-knowledge load. -n total, -c connections, -m concurrent streams/conn.
h2load -n "$REQUESTS" -c "$CONNS" -m "$STREAMS" "http://127.0.0.1:${PORT}${URL_PATH}" \
	2>&1 | awk '/finished in|req\/s|status codes|succeeded/{print "  " $0}'

kill "$samplerpid" 2>/dev/null
samplerpid=0
end_rss=$(rss_kb "$srvpid")
peak_rss=$(sort -n "$rssfile" | tail -1)

echo "--- RSS ---"
echo "  start: ${start_rss} kB"
echo "  peak:  ${peak_rss} kB"
echo "  end:   ${end_rss} kB"
if [ -n "$start_rss" ] && [ -n "$end_rss" ]; then
	slope=$((end_rss - start_rss))
	echo "  slope (end-start): ${slope} kB"
	# A flat slope (within a few MB of warmup growth) means no per-request leak.
	# A slope that scales with REQUESTS is a leak — fatal under -gc none.
	if [ "$slope" -gt 51200 ]; then
		echo "  WARNING: RSS grew >50 MB — likely a per-request leak under -gc none."
	else
		echo "  OK: RSS slope is flat (no per-request leak detected)."
	fi
fi
