#!/usr/bin/env bash
# Controlled measurement harness — the discipline for telling a real change from
# noise (MIT 6.172 Lecture 10, "Measurement and Timing").
#
# wrk.sh gates END-TO-END throughput. THIS script answers a different question:
# "is the delta I just measured real, or is it the machine?" It does three things
# wrk.sh does not:
#
#   1. Reports the ENVIRONMENT that shaped the numbers (governor, turbo, the
#      pinned core's SMT sibling) so a pasted result is attributable — and warns,
#      with the exact fix, when the environment is not quiesced.
#   2. PINS the work to one core (taskset). A migrating process pays cold caches
#      and cross-core scheduling jitter; a fixed core removes that variable.
#   3. Runs the command N times and reports the MINIMUM (plus spread). The minimum
#      is the right estimator: every source of noise on a real machine — an
#      interrupt, a scheduler migration, a turbo step-down, a noisy neighbour —
#      only ever makes a run SLOWER, never faster. So the fastest run is the one
#      closest to the true cost; the mean just drags toward the noise. The spread
#      is your noise floor: a delta smaller than the spread is not measurable here.
#
# Wrap a *prebuilt* micro-bench binary (NOT `v run`, which recompiles every call):
#
#   v -prod -gc none -o /tmp/rp bench/request_parser/request_parser_bench.v
#   bench/measure.sh /tmp/rp                  # 7 runs -> min / median / spread
#   BENCH_PERF=1 bench/measure.sh /tmp/rp     # + perf stat (cycles, IPC, misses)
#   BENCH_RUNS=15 BENCH_CORE=7 bench/measure.sh /tmp/rp
#
# A/B a change: build the binary on `main`, measure; build on your branch,
# measure; compare the MINIMUMS. If the delta is smaller than the spread%, the
# environment is too noisy to trust it — quiesce further (the warnings tell you how).

set -uo pipefail

# Force a C numeric locale so EPOCHREALTIME, awk, and sort all agree on '.' as the
# radix char. Without this, a comma-decimal locale + a non-locale-aware awk (mawk,
# Ubuntu's default) silently truncates timings at the comma and the math is wrong.
export LC_ALL=C

RUNS="${BENCH_RUNS:-7}"
CORE="${BENCH_CORE:-}"
MAX_SPREAD="${BENCH_MAX_SPREAD:-3}"   # % over which a measured delta is untrustworthy

[ "$#" -ge 1 ] || {
	echo "usage: [BENCH_RUNS=N] [BENCH_CORE=n] [BENCH_PERF=1] $0 <command> [args...]" >&2
	exit 2
}

# Default to the highest-numbered CPU — core 0 fields the most IRQs.
[ -n "$CORE" ] || CORE=$(( $(nproc) - 1 ))

read_sys() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null; }

# High-resolution wall clock. bash 5 has EPOCHREALTIME (microseconds); fall back
# to date for older shells.
if [ -n "${EPOCHREALTIME:-}" ]; then
	now() { echo "$EPOCHREALTIME"; }
else
	now() { date +%s.%N; }
fi

echo "=== environment ==="
printf 'cpu        : %s\n' "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}')"
printf 'kernel     : %s\n' "$(uname -r)"
printf 'pinned core: %s\n'  "$CORE"

gov=$(read_sys "/sys/devices/system/cpu/cpu${CORE}/cpufreq/scaling_governor")
printf 'governor   : %s\n' "${gov:-unknown}"
if [ -n "$gov" ] && [ "$gov" != performance ]; then
	echo '             ^ WARN: not "performance" — frequency will drift between runs.'
	echo '               fix: sudo cpupower frequency-set -g performance'
fi

if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
	if [ "$(read_sys /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ]; then
		echo 'turbo      : off'
	else
		echo 'turbo      : ON'
		echo '             ^ WARN: turbo makes early (cool) runs faster than later ones.'
		echo '               fix: echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo'
	fi
elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
	if [ "$(read_sys /sys/devices/system/cpu/cpufreq/boost)" = 0 ]; then
		echo 'turbo      : off'
	else
		echo 'turbo      : ON'
		echo '             ^ WARN: boost makes early (cool) runs faster than later ones.'
		echo '               fix: echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost'
	fi
else
	echo 'turbo      : unknown'
fi

sib=$(read_sys "/sys/devices/system/cpu/cpu${CORE}/topology/thread_siblings_list")
if [ -n "$sib" ] && [ "$sib" != "$CORE" ]; then
	printf 'smt sibling: %s\n' "$sib"
	echo '             ^ keep it idle, or pin to a core whose sibling is isolated.'
fi

# `v run` recompiles on every invocation — that compile time would land in the
# measurement. Catch the common mistake.
if [ "$1" = v ]; then
	case " $* " in
		*" run "*) echo 'WARN: "v run" recompiles each call — build once with "-o BIN" and pass BIN.' ;;
	esac
fi

if command -v taskset >/dev/null; then
	PIN=(taskset -c "$CORE")
else
	PIN=()
	echo 'WARN: taskset not found — runs are NOT core-pinned (install util-linux).'
fi

echo
echo "=== ${RUNS} runs (seconds, lower is better) ==="
samples=$(mktemp)
for i in $(seq 1 "$RUNS"); do
	t0=$(now)
	"${PIN[@]}" "$@" >/dev/null 2>&1
	t1=$(now)
	awk -v a="$t0" -v b="$t1" 'BEGIN{ printf "%.6f\n", b-a }' >> "$samples"
	printf '  run %2d: %s\n' "$i" "$(tail -1 "$samples")"
done

sort -g "$samples" -o "$samples"
min=$(head -1 "$samples")
max=$(tail -1 "$samples")
med=$(sed -n "$(( (RUNS + 1) / 2 ))p" "$samples")
spread=$(awk -v mn="$min" -v mx="$max" 'BEGIN{ printf "%.1f", (mn>0)?((mx-mn)/mn*100):0 }')
rm -f "$samples"

echo
echo "=== summary ==="
printf 'min    : %s s   <-- report THIS for A/B comparisons\n' "$min"
printf 'median : %s s\n' "$med"
printf 'max    : %s s\n' "$max"
printf 'spread : %s%%  (max-min)/min — your noise floor\n' "$spread"
if awk -v s="$spread" -v m="$MAX_SPREAD" 'BEGIN{ exit !(s > m) }'; then
	echo "WARN: spread > ${MAX_SPREAD}% — too noisy to trust a delta smaller than this."
	echo "      quiesce: close apps, governor=performance, turbo off, pin to an isolated core."
fi

if [ "${BENCH_PERF:-0}" = 1 ]; then
	echo
	echo "=== perf stat -d (one extra pinned run) ==="
	if command -v perf >/dev/null; then
		# perf writes BOTH its counter table and any error to stderr; capture it so
		# the user sees the reason on failure instead of an empty header.
		perflog=$(mktemp)
		"${PIN[@]}" perf stat -d "$@" >/dev/null 2>"$perflog" || true
		cat "$perflog"
		if grep -q perf_event_paranoid "$perflog"; then
			echo
			echo '      ^ counters blocked. fix: sudo sysctl kernel.perf_event_paranoid=1'
			echo '        (or =-1 for full access; persist in /etc/sysctl.conf)'
		fi
		rm -f "$perflog"
	else
		echo 'perf not installed — sudo apt install linux-tools-$(uname -r)'
	fi
fi
