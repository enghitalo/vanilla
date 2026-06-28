#!/usr/bin/env bash
# Server-under-load memory + CPU harness — LOCAL only.
#
# Micro-benchmarks (measure.sh / ci_bench.sh) time a pure function's CPU cost.
# They cannot see the two things that decide behaviour at scale:
#   * how memory grows under sustained load — per-request allocation / GC
#     pressure. BEST_PRACTICES.md section 10 wants the RSS slope FLAT under
#     `-gc none`; a rising slope is a leak/retention.
#   * how much CPU the server burns per request (its efficiency).
# This boots a server, drives it with wrk, and samples /proc/<pid> throughout.
#
# When: after a change to allocation, buffering, or the concurrency model, or to
# confirm RSS stays flat under -gc none — things the function-level micro-benches
# (measure.sh / ci_bench.sh) can't see. NOT for hosted CI: a load test on a
# shared, hardware-varying runner is too noisy to compare (the same reason
# ci_bench.sh does a same-runner A/B instead). Run it on a quiesced machine.
#
#   bench/load.sh                                  # examples/simple, GET /, 15s
#   DURATION=30 bench/load.sh examples/tiny/src / 3000
#   GC=boehm bench/load.sh                         # compare default GC vs -gc none
#
# Reports req/s, peak RSS, RSS slope (start->end), CPU-seconds, CPU% (cores
# busy), and CPU-ms per 1k requests.

set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

SRC="${1:-examples/simple/src}"
URL_PATH="${2:-/}"
PORT="${3:-3000}"
DURATION="${DURATION:-15}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"
GC="${GC:-none}"          # none = production (-gc none); boehm = default GC

command -v wrk  >/dev/null || { echo "ERROR: wrk not installed";  exit 2; }
command -v v    >/dev/null || { echo "ERROR: v not installed";    exit 2; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 2; }

hz=$(getconf CLK_TCK)

# /proc/<pid>/stat fields 14 (utime) + 15 (stime), summed over all threads of the
# process. comm (field 2) may contain spaces, so strip up to ") " first; in the
# remainder, state is $1, so utime is $12 and stime is $13.
read_cpu_ticks() {
	local stat rest
	stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
	rest=${stat#*) }
	# shellcheck disable=SC2086
	set -- $rest
	echo $(( ${12} + ${13} ))
}

gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
[ "$gov" = performance ] || echo "note: governor=$gov — set 'performance' for stable CPU% (RSS is robust regardless)."

gcflag="-gc none"; [ "$GC" = boehm ] && gcflag=""
bin=$(mktemp -u /tmp/loadsrv.XXXXXX)
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

echo "=== load: ${SRC}  ${URL_PATH}  (v -prod ${gcflag:--gc=default}) ==="
v wipe-cache >/dev/null 2>&1 || true
# shellcheck disable=SC2086
v -prod $gcflag -o "$bin" "$SRC" >/dev/null 2>&1 || { echo "ERROR: build failed"; exit 2; }

fuser -k "${PORT}/tcp" >/dev/null 2>&1; sleep 0.3
"$bin" >"$srvlog" 2>&1 &
srvpid=$!

ready=0
for _ in $(seq 1 80); do
	curl -s -o /dev/null --max-time 1 "http://localhost:${PORT}${URL_PATH}" && { ready=1; break; }
	sleep 0.25
done
[ "$ready" = 1 ] || { echo "ERROR: server did not start:"; tail -5 "$srvlog"; exit 2; }

# Background RSS sampler (kB), every 200 ms while the server lives.
( while kill -0 "$srvpid" 2>/dev/null; do
		awk '/^VmRSS:/{print $2}' "/proc/$srvpid/status" 2>/dev/null
		sleep 0.2
	done > "$rssfile" ) &
samplerpid=$!

cpu0=$(read_cpu_ticks "$srvpid")
t0=$EPOCHREALTIME
echo "running: wrk -t${THREADS} -c${CONNS} -d${DURATION}s ..."
wrk_out=$(wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -H 'Connection: keep-alive' \
	"http://localhost:${PORT}${URL_PATH}")
t1=$EPOCHREALTIME
cpu1=$(read_cpu_ticks "$srvpid")
kill "$samplerpid" 2>/dev/null; samplerpid=0

rps=$(echo "$wrk_out"   | awk '/Requests\/sec/{print $2}')
total=$(echo "$wrk_out" | awk '/requests in/{print $1}')

read -r rss_first rss_last rss_peak < <(awk '
	NR==1{first=$1} {last=$1; if($1>peak)peak=$1} END{print first, last, peak}' "$rssfile")

echo
echo "=== summary ==="
awk -v rps="${rps:-0}" -v total="${total:-0}" \
	-v c0="$cpu0" -v c1="$cpu1" -v hz="$hz" -v t0="$t0" -v t1="$t1" \
	-v rf="${rss_first:-0}" -v rl="${rss_last:-0}" -v rp="${rss_peak:-0}" 'BEGIN{
	wall  = t1 - t0
	cpus  = (c1 - c0) / hz
	pct   = (wall>0) ? cpus/wall*100 : 0
	cores = pct/100
	effms = (total>0) ? cpus*1000.0/(total/1000.0) : 0
	printf "throughput : %s req/s  (%s requests)\n", rps, total
	printf "CPU        : %.2f cpu-s over %.2f s wall = %.0f%% (%.1f cores busy)\n", cpus, wall, pct, cores
	printf "efficiency : %.3f cpu-ms / 1k req\n", effms
	printf "memory RSS : start %.1f MB  peak %.1f MB  end %.1f MB  ->  slope %+.1f MB\n", \
		rf/1024, rp/1024, rl/1024, (rl-rf)/1024
}'
if [ "$GC" = none ]; then
	echo "             under -gc none the slope should be ~flat; growth = leak/retention (BEST_PRACTICES.md §10)."
fi
echo
echo "$wrk_out" | sed 's/^/wrk | /'
