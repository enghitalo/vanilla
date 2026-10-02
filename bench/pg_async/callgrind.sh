#!/usr/bin/env bash
# pg_async allocations per request, by call site — callgrind over
# bench/pg_async/e2e_server in steady state (docs/V_PERF_TOOLBOX.md,
# "Profiling allocations"). LOCAL only.
#
#   bench/pg_async/callgrind.sh            # shapes: dbp db errors disconnects
#   bench/pg_async/callgrind.sh dbp
#
# The recipe: build -cc gcc -g -prod -gc none (gcc for file:line, -gc none so
# every allocation is a libc call callgrind sees); start under valgrind with
# instrumentation OFF; warm up hard (pool bring-up, SCRAM and every buffer
# reaching its high-water mark run uninstrumented); `callgrind_control -i on`;
# drive the measured load; SIGTERM valgrind (a live dump hangs while every
# worker sits in epoll_wait; SIGTERM interrupts it and callgrind dumps at
# exit); then count allocator calls by immediate caller per request
# (callgrind_allocs.py). Steady state must read 0.
#
# Shapes: dbp (/dbp, pipelined), db (/db, acquire/release), errors (50%
# /dberr), disconnects (clients hanging up mid-query on /dbslow).
# Environment: WARMUP [10] s, WINDOW [10] s, POOL [2]; one worker (valgrind
# serializes threads anyway).

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

WARMUP="${WARMUP:-10}"
WINDOW="${WINDOW:-10}"
POOL="${POOL:-2}"
PORT="${BENCH_PORT:-8099}"
shapes=("$@")
[ ${#shapes[@]} -gt 0 ] || shapes=(dbp db errors disconnects)
for shape in "${shapes[@]}"; do
	case "$shape" in
		dbp | db | errors | disconnects) ;;
		*) echo "unknown shape '$shape' (dbp db errors disconnects)" >&2; exit 2 ;;
	esac
done

for tool in wrk v valgrind callgrind_control python3; do
	command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done

work=$(mktemp -d)
pg_started=0
vg_pid=
cleanup() {
	[ -n "$vg_pid" ] && kill "$vg_pid" 2>/dev/null
	[ "$pg_started" = 1 ] && pg_async/testdata/throwaway_pg.sh stop
	rm -rf "$work"
}
trap cleanup EXIT

if [ -z "${PGHOST:-}" ]; then
	pg_env=$(pg_async/testdata/throwaway_pg.sh start) || exit 2
	eval "$pg_env"
	pg_started=1
fi

echo "building bench/pg_async/e2e_server (-prod -gc none -cc gcc -g)..."
v -prod -gc none -cc gcc -g -o "$work/server" bench/pg_async/e2e_server >"$work/build.log" 2>&1 || {
	cat "$work/build.log"
	exit 2
}

cat >"$work/errors.lua" <<'LUA'
local i = 0
request = function()
	i = i + 1
	if i % 2 == 0 then
		return wrk.format("GET", "/dberr")
	end
	return wrk.format("GET", "/dbp")
end
LUA

# drive <shape> <seconds> — prints the number of requests sent.
drive() {
	local out
	case "$1" in
		dbp) out=$(wrk -t1 -c8 -d"$2s" "http://127.0.0.1:$PORT/dbp" 2>&1) ;;
		db) out=$(wrk -t1 -c"$POOL" -d"$2s" "http://127.0.0.1:$PORT/db" 2>&1) ;;
		errors) out=$(wrk -t1 -c8 -d"$2s" -s "$work/errors.lua" "http://127.0.0.1:$PORT/" 2>&1) ;;
		disconnects)
			python3 bench/pg_async/disconnect_load.py --port "$PORT" --path /dbslow --threads 4 \
				--duration "$2" --park-ms 2
			return
			;;
		*) echo "unknown shape $1" >&2; exit 2 ;;
	esac
	awk '/requests in/ {print $1}' <<<"$out"
}

for shape in "${shapes[@]}"; do
	echo
	echo "=== $shape ==="
	out_file="$work/callgrind.$shape.out"
	VANILLA_WORKERS=1 PG_POOL_SIZE=$POOL BENCH_PORT=$PORT VANILLA_NO_IOURING=1 \
		valgrind --tool=callgrind --instr-atstart=no --callgrind-out-file="$out_file" \
		"$work/server" >"$work/vg.log" 2>&1 &
	vg_pid=$!
	up=0
	for _ in $(seq 1 600); do
		curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { up=1; break; }
		sleep 0.1
	done
	[ "$up" = 1 ] || { echo "server did not come up under valgrind:" >&2; cat "$work/vg.log" >&2; exit 1; }
	drive "$shape" "$WARMUP" >/dev/null
	callgrind_control -i on "$vg_pid" >/dev/null
	reqs=$(drive "$shape" "$WINDOW")
	callgrind_control -i off "$vg_pid" >/dev/null
	kill -TERM "$vg_pid"
	wait "$vg_pid" 2>/dev/null
	vg_pid=
	python3 bench/pg_async/callgrind_allocs.py "$out_file" "${reqs:-0}"
done
