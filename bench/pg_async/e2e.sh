#!/usr/bin/env bash
# pg_async end-to-end load benchmark — LOCAL only (a shared CI runner is too
# noisy to compare loads; see bench/load.sh). Boots bench/pg_async/e2e_server
# against a local, seeded PostgreSQL, drives it with wrk and reports, per
# pooling shape, the req/s of RUNS independent runs (fresh server each) as
# min / median / max / spread, plus the median p50 / p99 latency.
#
#   bench/pg_async/e2e.sh                # both shapes: db (acquire) and dbp (acquire_pipelined)
#   RUNS=7 DURATION=15 bench/pg_async/e2e.sh dbp
#   GC=boehm bench/pg_async/e2e.sh       # the default-GC build instead of -gc none
#   TLS=1 bench/pg_async/e2e.sh          # over TLS: -d vanilla_tls, verify-full
#
# Without PGHOST it starts pg_async/testdata/throwaway_pg.sh (and stops it at
# exit). A/B a change: run on main, run on the branch, same machine state,
# compare the medians against the spread — a delta inside the spread is noise.
# The throughput of this setup is usually bound by PostgreSQL itself, so the
# server's CPU cost per request (µs of user+system time, from /proc) is the
# column that shows a driver-side change; bench/pg_async/codec_bench.v
# isolates it further.
#
# Environment (defaults in brackets):
#   WORKERS [2]   server worker threads (VANILLA_WORKERS, pinned)
#   POOL [4]      PostgreSQL connections per worker
#   CONNS_DB      wrk connections for db [WORKERS*POOL: every request finds a slot]
#   CONNS_DBP     wrk connections for dbp [4*WORKERS*POOL: pipelines ~4 deep]
#   THREADS [2]   wrk threads
#   DURATION [10] seconds measured per run, after a 2 s warm-up
#   RUNS [5]      runs per shape
#   GC [none]     none (-gc none, production) | boehm
#   TLS [0]       1: build with -d vanilla_tls and talk TLS (PGSSLMODE /
#                 PGSSLROOTCERT; a throwaway cluster is started TLS-only)
#   SERVER_CPUS / LOAD_CPUS / PG_CPUS   taskset lists [0-1 / 2 / 3 on 4 cores]

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

WORKERS="${WORKERS:-2}"
POOL="${POOL:-4}"
CONNS_DB="${CONNS_DB:-$((WORKERS * POOL))}"
CONNS_DBP="${CONNS_DBP:-$((4 * WORKERS * POOL))}"
THREADS="${THREADS:-2}"
DURATION="${DURATION:-10}"
RUNS="${RUNS:-5}"
GC="${GC:-none}"
PORT="${BENCH_PORT:-8099}"
ncpu=$(nproc)
SERVER_CPUS="${SERVER_CPUS:-0-$((WORKERS - 1))}"
LOAD_CPUS="${LOAD_CPUS:-$(((WORKERS) % ncpu))}"
PG_CPUS="${PG_CPUS:-$((ncpu - 1))}"
shapes=("$@")
[ ${#shapes[@]} -gt 0 ] || shapes=(db dbp)

command -v wrk >/dev/null || { echo "ERROR: wrk not installed" >&2; exit 2; }
command -v v >/dev/null || { echo "ERROR: v not installed" >&2; exit 2; }

work=$(mktemp -d)
pg_started=0
srv_pid=
cleanup() {
	[ -n "$srv_pid" ] && kill "$srv_pid" 2>/dev/null
	[ "$pg_started" = 1 ] && pg_async/testdata/throwaway_pg.sh stop
	rm -rf "$work"
}
trap cleanup EXIT

if [ -z "${PGHOST:-}" ]; then
	pg_env=$(PG_CPUS=$PG_CPUS PG_TLS="${TLS:-0}" pg_async/testdata/throwaway_pg.sh start) || exit 2
	eval "$pg_env"
	pg_started=1
fi

gcflag=(-gc none)
[ "$GC" = boehm ] && gcflag=()
[ "${TLS:-0}" = 1 ] && gcflag+=(-d vanilla_tls)
echo "building bench/pg_async/e2e_server (-prod ${gcflag[*]})..."
v -prod "${gcflag[@]}" -o "$work/server" bench/pg_async/e2e_server >"$work/build.log" 2>&1 || {
	cat "$work/build.log"
	exit 2
}

start_server() {
	VANILLA_WORKERS=$WORKERS PG_POOL_SIZE=$POOL BENCH_PORT=$PORT VANILLA_NO_IOURING=1 \
		taskset -c "$SERVER_CPUS" "$work/server" >"$work/server.log" 2>&1 &
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

hz=$(getconf CLK_TCK)

# cpu_ticks is the server's utime + stime, all threads (/proc/<pid>/stat
# fields 14 + 15; comm may hold spaces, so strip through ") " first).
cpu_ticks() {
	local stat
	stat=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
	awk '{print $12 + $13}' <<<"${stat##*) }"
}

# to_ms converts a wrk latency ("812.00us", "1.20ms", "2.01s") to ms.
to_ms() {
	awk -v x="$1" 'BEGIN {
		n = x + 0
		if (x ~ /us$/) n /= 1000; else if (x ~ /ms$/) n += 0; else if (x ~ /s$/) n *= 1000
		printf "%.3f", n }'
}

echo "=== environment ==="
printf 'cpu        : %s\n' "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}')"
printf 'kernel     : %s\n' "$(uname -r)"
printf 'postgres   : %s\n' "$(psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -Atc 'show server_version' 2>/dev/null)"
printf 'server     : %s workers on cpus %s, %s pg connections each, -prod %s\n' "$WORKERS" "$SERVER_CPUS" "$POOL" "${gcflag[*]:-(boehm)}"
printf 'load       : wrk -t%s on cpus %s, %ss per run after a 2s warm-up, %s runs\n' "$THREADS" "$LOAD_CPUS" "$DURATION" "$RUNS"

for shape in "${shapes[@]}"; do
	case "$shape" in
		db) conns=$CONNS_DB ;;
		dbp) conns=$CONNS_DBP ;;
		*) echo "unknown shape $shape (db|dbp)" >&2; exit 2 ;;
	esac
	rps_file="$work/rps.$shape"
	: >"$rps_file"
	p50s=()
	p99s=()
	cpus=()
	echo
	echo "=== /$shape: $conns connections ==="
	for run in $(seq 1 "$RUNS"); do
		start_server
		taskset -c "$LOAD_CPUS" wrk -t"$THREADS" -c"$conns" -d2s "http://127.0.0.1:$PORT/$shape" >/dev/null 2>&1
		t0=$(cpu_ticks "$srv_pid")
		out=$(taskset -c "$LOAD_CPUS" wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" --latency "http://127.0.0.1:$PORT/$shape" 2>&1)
		t1=$(cpu_ticks "$srv_pid")
		stop_server
		reqs=$(awk '/requests in/ {print $1}' <<<"$out")
		cpu_us=$(awk -v t="$((t1 - t0))" -v hz="$hz" -v n="${reqs:-0}" 'BEGIN { printf "%.2f", (n > 0) ? t / hz * 1e6 / n : 0 }')
		rps=$(awk '/^Requests\/sec:/ {print $2}' <<<"$out")
		p50=$(to_ms "$(awk '$1 == "50%" {print $2}' <<<"$out")")
		p99=$(to_ms "$(awk '$1 == "99%" {print $2}' <<<"$out")")
		non2xx=$(awk '/Non-2xx or 3xx responses:/ {print $NF}' <<<"$out")
		errs=$(awk '/Socket errors:/ {print $0}' <<<"$out")
		echo "$rps" >>"$rps_file"
		p50s+=("$p50")
		p99s+=("$p99")
		cpus+=("$cpu_us")
		printf '  run %d: %10s req/s   p50 %8s ms   p99 %8s ms   server cpu %6s us/req%s%s\n' "$run" "$rps" \
			"$p50" "$p99" "$cpu_us" "${non2xx:+   non-2xx: $non2xx}" "${errs:+   $errs}"
	done
	sort -g "$rps_file" -o "$rps_file"
	min=$(head -1 "$rps_file")
	max=$(tail -1 "$rps_file")
	med=$(sed -n "$(((RUNS + 1) / 2))p" "$rps_file")
	spread=$(awk -v mn="$min" -v mx="$max" 'BEGIN { printf "%.1f", (mn > 0) ? ((mx - mn) / mn * 100) : 0 }')
	p50med=$(printf '%s\n' "${p50s[@]}" | sort -g | sed -n "$(((RUNS + 1) / 2))p")
	p99med=$(printf '%s\n' "${p99s[@]}" | sort -g | sed -n "$(((RUNS + 1) / 2))p")
	cpumed=$(printf '%s\n' "${cpus[@]}" | sort -g | sed -n "$(((RUNS + 1) / 2))p")
	cpumin=$(printf '%s\n' "${cpus[@]}" | sort -g | head -1)
	cpumax=$(printf '%s\n' "${cpus[@]}" | sort -g | tail -1)
	echo "  /$shape req/s: min $min  median $med  max $max  spread $spread%"
	echo "  /$shape latency (median of runs): p50 $p50med ms  p99 $p99med ms"
	echo "  /$shape server cpu us/req: min $cpumin  median $cpumed  max $cpumax"
done
