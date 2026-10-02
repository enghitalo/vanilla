#!/usr/bin/env bash
# pg_async leak harness — the RSS slope, in bytes per request, of
# bench/pg_async/e2e_server under sustained load, plus its open-fd count
# before and after. LOCAL only (see bench/load.sh on why not hosted CI).
#
# Method (docs/V_PERF_TOOLBOX.md, "Profiling allocations"): every shape runs
# twice, once built -prod -gc none (nothing is ever freed: a per-request
# allocation is a leak that grows RSS linearly) and once -prod with the Boehm
# GC (the same server's unavoidable floor: glibc arenas, buffers reaching
# their high-water mark). After a warm-up, RSS and the fd count are sampled,
# the measured window runs, and they are sampled again once the load stops.
# The report is gc_none_growth - boehm_growth per request: the genuinely
# collectable per-request allocation. ~0 is the target.
#
#   bench/pg_async/leak.sh                   # every shape
#   WINDOW=60 bench/pg_async/leak.sh errors  # one shape, longer window
#
# Shapes:
#   steady       wrk on /dbp (pipelined queries, every one succeeds)
#   exclusive    wrk on /db (acquire / release)
#   errors       wrk alternating /dbp and /dberr: 50% of queries fail
#   disconnects  clients that hang up while parked on /dbslow (tombstones)
#   churn        wrk on /dbp while every pooled backend is killed
#                (pg_terminate_backend) every CHURN_MS: forced re-dials; the
#                report adds bytes per reconnect
#
# Environment: WORKERS [2], POOL [4], CONNS [32], WARMUP [5] s, WINDOW [20] s,
# CHURN_MS [500], SERVER_CPUS / LOAD_CPUS / PG_CPUS (as in e2e.sh). Without
# PGHOST a throwaway PostgreSQL is started (and stopped at exit).

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

WORKERS="${WORKERS:-2}"
POOL="${POOL:-4}"
CONNS="${CONNS:-32}"
WARMUP="${WARMUP:-5}"
WINDOW="${WINDOW:-20}"
CHURN_MS="${CHURN_MS:-500}"
PORT="${BENCH_PORT:-8099}"
ncpu=$(nproc)
SERVER_CPUS="${SERVER_CPUS:-0-$((WORKERS - 1))}"
LOAD_CPUS="${LOAD_CPUS:-$((WORKERS % ncpu))}"
PG_CPUS="${PG_CPUS:-$((ncpu - 1))}"
shapes=("$@")
[ ${#shapes[@]} -gt 0 ] || shapes=(steady exclusive errors disconnects churn)
for shape in "${shapes[@]}"; do
	case "$shape" in
		steady | exclusive | errors | disconnects | churn) ;;
		*) echo "unknown shape '$shape' (steady exclusive errors disconnects churn)" >&2; exit 2 ;;
	esac
done

for tool in wrk v python3 psql; do
	command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done

work=$(mktemp -d)
pg_started=0
srv_pid=
churn_pid=
cleanup() {
	[ -n "$churn_pid" ] && kill "$churn_pid" 2>/dev/null
	[ -n "$srv_pid" ] && kill "$srv_pid" 2>/dev/null
	[ "$pg_started" = 1 ] && pg_async/testdata/throwaway_pg.sh stop
	rm -rf "$work"
}
trap cleanup EXIT

if [ -z "${PGHOST:-}" ]; then
	pg_env=$(PG_CPUS=$PG_CPUS pg_async/testdata/throwaway_pg.sh start) || exit 2
	eval "$pg_env"
	pg_started=1
fi

for gc in none boehm; do
	flags=(-gc none)
	[ "$gc" = boehm ] && flags=()
	echo "building bench/pg_async/e2e_server (-prod ${flags[*]})..."
	v -prod "${flags[@]}" -o "$work/server_$gc" bench/pg_async/e2e_server >"$work/build.log" 2>&1 || {
		cat "$work/build.log"
		exit 2
	}
done

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

rss_kib() { awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
fd_count() { ls "/proc/$1/fd" 2>/dev/null | wc -l; }

start_server() { # <gc>
	VANILLA_WORKERS=$WORKERS PG_POOL_SIZE=$POOL BENCH_PORT=$PORT VANILLA_NO_IOURING=1 \
		taskset -c "$SERVER_CPUS" "$work/server_$1" >"$work/server.log" 2>&1 &
	srv_pid=$!
	for _ in $(seq 1 100); do
		curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
		sleep 0.05
	done
	echo "server did not come up:" >&2
	cat "$work/server.log" >&2
	exit 1
}

stop_server() {
	kill "$srv_pid" 2>/dev/null
	wait "$srv_pid" 2>/dev/null
	srv_pid=
}

# load <shape> <seconds> — runs the shape's load, prints the requests sent.
load() {
	local out
	case "$1" in
		steady | churn)
			out=$(taskset -c "$LOAD_CPUS" wrk -t2 -c"$CONNS" -d"$2s" "http://127.0.0.1:$PORT/dbp" 2>&1)
			;;
		exclusive)
			out=$(taskset -c "$LOAD_CPUS" wrk -t2 -c"$((WORKERS * POOL))" -d"$2s" "http://127.0.0.1:$PORT/db" 2>&1)
			;;
		errors)
			out=$(taskset -c "$LOAD_CPUS" wrk -t2 -c"$CONNS" -d"$2s" -s "$work/errors.lua" "http://127.0.0.1:$PORT/" 2>&1)
			;;
		disconnects)
			taskset -c "$LOAD_CPUS" python3 bench/pg_async/disconnect_load.py --port "$PORT" --path /dbslow \
				--threads 8 --duration "$2"
			return
			;;
	esac
	echo "$out" >"$work/wrk.out"
	awk '/requests in/ {print $1}' <<<"$out"
}

# churn_loop kills every pooled backend of the bench user every CHURN_MS and
# appends the number killed to $work/killed.
churn_loop() {
	: >"$work/killed"
	while :; do
		psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -Atc \
			"select count(pg_terminate_backend(pid)) from pg_stat_activity where usename = current_user and pid <> pg_backend_pid() and backend_type = 'client backend'" \
			>>"$work/killed" 2>/dev/null
		sleep "$(awk -v ms="$CHURN_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
	done
}

echo "=== environment ==="
printf 'server     : %s workers on cpus %s, %s pg connections each\n' "$WORKERS" "$SERVER_CPUS" "$POOL"
printf 'window     : %ss warm-up, %ss measured\n' "$WARMUP" "$WINDOW"

for shape in "${shapes[@]}"; do
	echo
	echo "=== $shape ==="
	declare -A bpr=()
	for gc in none boehm; do
		start_server "$gc"
		[ "$shape" = churn ] && { churn_loop & churn_pid=$!; }
		load "$shape" "$WARMUP" >/dev/null
		rss0=$(rss_kib "$srv_pid")
		fd0=$(fd_count "$srv_pid")
		# Count the window's kills only: what the warm-up's cost is in rss0.
		[ "$shape" = churn ] && : >"$work/killed"
		: >"$work/rss.csv"
		(
			t=0
			while kill -0 "$srv_pid" 2>/dev/null; do
				echo "$t,$(rss_kib "$srv_pid")" >>"$work/rss.csv"
				sleep 1
				t=$((t + 1))
			done
		) &
		sampler=$!
		reqs=$(load "$shape" "$WINDOW")
		if [ -n "$churn_pid" ]; then
			kill "$churn_pid" 2>/dev/null
			wait "$churn_pid" 2>/dev/null
			churn_pid=
		fi
		sleep 1 # let in-flight replies and tombstones drain
		rss1=$(rss_kib "$srv_pid")
		fd1=$(fd_count "$srv_pid")
		kill "$sampler" 2>/dev/null
		wait "$sampler" 2>/dev/null
		# Recovered? The last kill may have landed just before the load
		# stopped, so give the pool up to 5 s to answer 200 again.
		after=000
		for _ in $(seq 1 50); do
			after=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/dbp")
			[ "$after" = 200 ] && break
			sleep 0.1
		done
		failed=$(awk '/Non-2xx or 3xx responses:/ {print $NF}' "$work/wrk.out" 2>/dev/null)
		[ "$shape" = disconnects ] && failed=
		stop_server
		growth=$((rss1 - rss0))
		bpr[$gc]=$(awk -v g="$growth" -v n="${reqs:-0}" 'BEGIN { printf "%.2f", (n > 0) ? g * 1024 / n : 0 }')
		peak=$(cut -d, -f2 "$work/rss.csv" | sort -n | tail -1)
		extra=
		if [ "$shape" = churn ]; then
			killed=$(awk '{s += $1} END {print s + 0}' "$work/killed")
			per_reconnect=$(awk -v g="$growth" -v k="$killed" 'BEGIN { printf "%.0f", (k > 0) ? g * 1024 / k : 0 }')
			extra="   backends killed $killed ($per_reconnect B/reconnect)"
		fi
		printf '  -gc %-5s requests %9s   RSS %6s -> %6s KiB (peak %6s)   growth %6s KiB = %8s B/req   fds %s -> %s   /dbp after: %s%s%s\n' \
			"$gc" "${reqs:-0}" "$rss0" "$rss1" "${peak:-?}" "$growth" "${bpr[$gc]}" "$fd0" "$fd1" "$after" \
			"${failed:+   non-2xx $failed}" "$extra"
	done
	echo "  => $shape: gc_none - boehm = $(awk -v a="${bpr[none]}" -v b="${bpr[boehm]}" 'BEGIN { printf "%.2f", a - b }') bytes/request"
	unset bpr
done
