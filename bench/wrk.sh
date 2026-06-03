#!/usr/bin/env bash
# End-to-end throughput regression gate (the "if necessary" wrk runs).
#
# Boots each example server, drives it with wrk using the documented flags,
# parses Requests/sec, and FAILS if any workload regresses >5% versus its
# recorded baseline. Exit code is non-zero on any regression, so this can gate
# CI / a merge.
#
#   bench/wrk.sh            # default 15s per workload
#   bench/wrk.sh 30         # 30s per workload (closer to the recorded runs)
#
# Requires: wrk, v, curl. For the pure hot-path functions (parser, header/query
# lookup) there's no need for wrk — use `v -prod run bench/request_parser_bench.v`.

set -uo pipefail

DUR="${1:-15}"
THREADS=16
CONNS=512
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

# Baselines recorded in the repo (wrk -t16 -c512, keep-alive):
#   tiny/simple       510,197 req/s  (README.md)
#   veb_like static   393,008 req/s  (examples/veb_like/router_static.v)
#   veb_like dynamic  310,602 req/s  (examples/veb_like/router_dynamic.v)
# Format: name | server source | port | path | baseline_req_per_s
WORKLOADS=(
	"tiny|./examples/tiny/src|3000|/|510197"
	"veb_static|./examples/veb_like|3000|/users|393008"
	"veb_dynamic|./examples/veb_like|3000|/users/1/posts/2|310602"
)

command -v wrk  >/dev/null || { echo "ERROR: wrk not installed";  exit 2; }
command -v v    >/dev/null || { echo "ERROR: v not installed";    exit 2; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 2; }

# Hygiene — without this the numbers are meaningless:
#   1. wipe V's build cache so we never benchmark a stale binary (a stale/mixed
#      build is the classic cause of an "absurd" drop);
#   2. free the port up front so no leftover server skews the run.
echo "Wiping V cache (v wipe-cache) and freeing :3000 ..."
v wipe-cache >/dev/null 2>&1 || true
for p in 3000 8443; do fuser -k "${p}/tcp" >/dev/null 2>&1; done
sleep 0.5

fail=0
printf '%-14s %14s %14s %9s  %s\n' "workload" "req/s" "baseline" "ratio" "result"
printf -- '------------------------------------------------------------------------\n'

for w in "${WORKLOADS[@]}"; do
	IFS='|' read -r name src port path baseline <<< "$w"

	fuser -k "${port}/tcp" >/dev/null 2>&1; sleep 0.3
	v -prod run "$src" > "/tmp/wrk_srv_${name}.log" 2>&1 &
	srvpid=$!

	# Wait until the server answers (or give up).
	ready=0
	for _ in $(seq 1 60); do
		if curl -s -o /dev/null --max-time 1 "http://localhost:${port}${path}"; then ready=1; break; fi
		sleep 0.25
	done
	if [ "$ready" -ne 1 ]; then
		printf '%-14s %14s\n' "$name" "SERVER FAILED — see /tmp/wrk_srv_${name}.log"
		kill "$srvpid" 2>/dev/null; fail=1; continue
	fi

	out=$(wrk -t"${THREADS}" -c"${CONNS}" -d"${DUR}s" -H 'Connection: keep-alive' "http://localhost:${port}${path}")
	rps=$(echo "$out" | awk '/Requests\/sec/{print $2}')

	kill "$srvpid" 2>/dev/null; fuser -k "${port}/tcp" >/dev/null 2>&1; sleep 0.3

	ratio=$(awk -v r="${rps:-0}" -v b="$baseline" 'BEGIN{ printf "%.1f", (b>0)?(r/b)*100:0 }')
	if awk -v r="${rps:-0}" -v b="$baseline" 'BEGIN{ exit !(r < b*0.95) }'; then
		result="FAIL (>5% regression)"; fail=1
	else
		result="PASS"
	fi
	printf '%-14s %14s %14s %8s%%  %s\n' "$name" "${rps:-0}" "$baseline" "$ratio" "$result"
done

printf -- '------------------------------------------------------------------------\n'
[ "$fail" -eq 0 ] && echo "OK: no regression >5%" || echo "REGRESSION DETECTED"
exit $fail
