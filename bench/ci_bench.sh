#!/usr/bin/env bash
# Same-runner A/B benchmark, for CI to comment on the PR that landed on main.
#
# Absolute benchmark numbers published over time are misleading: a hosted CI
# runner is noisy and uses different hardware on every run, so a "slower" number
# may just be a slower machine. The honest measurement is a SAME-RUNNER A/B —
# build and measure both HEAD and its parent in one job on one machine — and
# report the DELTA the landed commit introduced. Cross-machine variance cancels;
# what's left is the change itself (still floored by the runner's own noise, so
# treat a small delta as noise — see BENCH_THRESHOLD).
#
# Per build it reports the MINIMUM of N runs via bench/measure.sh (the minimum
# rejects upward noise — see that script and BEST_PRACTICES.md section 10).
#
#   bench/ci_bench.sh                  # HEAD vs HEAD~1, default bench set
#   BASE_REF=main BENCH_RUNS=7 bench/ci_bench.sh
#
# Emits a Markdown report to stdout (capture it for the PR comment) and, when
# running under Actions, also to $GITHUB_STEP_SUMMARY.

set -uo pipefail

# Match measure.sh: a C numeric locale so the dot-decimals it prints parse back
# cleanly through printf/awk here (a comma locale otherwise rejects "0.764").
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

BASE_REF="${BASE_REF:-HEAD~1}"
THRESHOLD="${BENCH_THRESHOLD:-5}"            # |Δ%| below this is reported as noise in the table
ISSUE_THRESHOLD="${BENCH_ISSUE_THRESHOLD:-10}" # a regression must clear THIS to open an issue —
                                             # higher than THRESHOLD so hosted-runner noise (often
                                             # 5-10%) does not file issues on its own
export BENCH_RUNS="${BENCH_RUNS:-5}"         # passed through to measure.sh

# Hot-path micro-benches to A/B. name | source [| extra V flags [| run args
# [| iterations]]] — each built with -prod -gc none (plus its flags) and run with
# its args; iterations, when given, replace BENCH_ITERS for that entry. All run
# on every invocation; BENCH_ITERS (below) keeps the full set to a few minutes
# in CI. The pg_async codec bench runs one phase per entry, at its own default
# work (its BENCH_ITERS counts queries or rows, not loop iterations), from one
# binary per side (see its header).
BENCHES=(
	"request_parser|bench/request_parser/request_parser_bench.v"
	"middleware|bench/middleware/middleware_bench.v"
	"etag_hash|bench/etag_hash/etag_hash.v"
	"static_assets|bench/static_assets_bench/static_assets_bench.v"
	"router|bench/router/router_bench.v"
	"pg_async_submit|bench/pg_async/codec_bench.v|-d pg_async_bench|submit|800000"
	"pg_async_frame|bench/pg_async/codec_bench.v|-d pg_async_bench|frame|400000"
	"pg_async_rows|bench/pg_async/codec_bench.v|-d pg_async_bench|rows|3000000"
	"pg_async_types|bench/pg_async/codec_bench.v|-d pg_async_bench|types|10000000"
)
# Standardize the loop count for the A/B: the benches read BENCH_ITERS. 2M keeps
# even the cheapest bench (request_parser, ~0.3s) comfortably above the runner's
# noise floor while a full run stays a few minutes; raise it if a bench's spread
# is high on the runner. Unset (or run a bench directly) to use the 5M default.
export BENCH_ITERS="${BENCH_ITERS:-2000000}"

# Always measure with HEAD's measure.sh (one methodology for both sides), even
# when the baseline ref predates it.
MEASURE="$ROOT/bench/measure.sh"

bins="$(mktemp -d)"
wt="$(mktemp -d)"
cleanup() {
	git worktree remove --force "$wt" >/dev/null 2>&1 || true
	rm -rf "$wt" "$bins"
}
trap cleanup EXIT

head_sha="$(git rev-parse --short HEAD)"
base_sha="$(git rev-parse --short "$BASE_REF" 2>/dev/null || echo 'unknown')"

# Stale objects are the classic cause of an "absurd" delta — wipe once up front.
v wipe-cache >/dev/null 2>&1 || true

# Isolated checkout of the baseline; the main worktree is untouched.
worktree_ok=1
git worktree add --detach "$wt" "$BASE_REF" >/dev/null 2>&1 || worktree_ok=0

# build <checkout-dir> <bench-relpath> <flags>: sets BIN to the binary, or to ""
# when the build fails (the bench is absent at that ref). One build per
# (checkout, source, flags): entries that only differ in their run args share it.
# (A function, not $(...): the cache must outlive the call.)
declare -A built=()
build() {
	local key="$1|$2|$3" bin
	if [ -z "${built[$key]+set}" ]; then
		bin="$bins/bin_${#built[@]}"
		# shellcheck disable=SC2086 # flags is a word list
		if ( cd "$1" && v -prod -gc none $3 -o "$bin" "$2" ) >/dev/null 2>&1; then
			built[$key]=$bin
		else
			built[$key]=
		fi
	fi
	BIN=${built[$key]}
}

# measure <binary> <args> <iterations> -> min seconds, or "" when a run fails
# (measure.sh then prints no summary).
measure() {
	# shellcheck disable=SC2086 # args is a word list
	BENCH_ITERS="${3:-$BENCH_ITERS}" BENCH_PERF=0 "$MEASURE" "$1" $2 2>/dev/null |
		awk '/^min/{print $3; exit}'
}

emit() {
	printf '%s\n' "$*"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
	fi
	return 0   # never let the summary-append status leak (Actions runs steps with -e)
}

# Hidden marker so a future run could find-and-update this comment instead of
# stacking a new one.
emit '<!-- vanilla-bench-bot -->'
emit "## 📊 Benchmark delta — \`${head_sha}\` vs \`${base_sha}\`"
emit ''
if [ "$worktree_ok" -ne 1 ]; then
	emit "⚠️ Could not check out baseline \`${BASE_REF}\` (shallow clone? need \`fetch-depth: 2\`). No comparison."
	exit 0
fi
emit "Same-runner A/B on \`${RUNNER_OS:-local}\`, toolchain \`$(v version 2>/dev/null || echo 'V unknown')\`. Hosted runners are noisy — treat **|Δ| < ${THRESHOLD}%** as noise. Each side is the **minimum of ${BENCH_RUNS} runs** of ${BENCH_ITERS} iterations (the \`pg_async\` phases: their own default work) (\`bench/measure.sh\`)."
emit ''
emit '| bench | baseline | this commit | Δ | |'
emit '|---|--:|--:|--:|:--|'

regressions=0         # > THRESHOLD       (flagged in the table)
issue_regressions=0   # > ISSUE_THRESHOLD (confident enough to open an issue)
for entry in "${BENCHES[@]}"; do
	IFS='|' read -r name src flags args iters <<< "$entry"
	build "$wt" "$src" "$flags"
	base_bin=$BIN
	build "$ROOT" "$src" "$flags"
	head_bin=$BIN
	base_min=
	head_min=
	[ -n "$base_bin" ] && base_min="$(measure "$base_bin" "$args" "$iters")"
	[ -n "$head_bin" ] && head_min="$(measure "$head_bin" "$args" "$iters")"

	if [ -z "$head_min" ]; then
		why='run failed'
		[ -z "$head_bin" ] && why='build failed'
		base_cell='—'
		[ -n "$base_min" ] && base_cell="$(printf '%.3f' "$base_min")s"
		emit "| \`$name\` | $base_cell | — | — | ❌ $why (HEAD) |"
		continue
	elif [ -z "$base_min" ]; then
		# Absent at the baseline, or present but unable to run this entry's
		# args (a phase added since): new either way.
		emit "| \`$name\` | — | $(printf '%.3f' "$head_min")s | — | 🆕 new bench |"
		continue
	fi

	delta="$(awk -v h="$head_min" -v b="$base_min" 'BEGIN{ printf "%+.1f", (b>0)?((h-b)/b*100):0 }')"
	# Classify numerically (an awk word), then map to display text — never inspect
	# the emoji byte-wise.
	flag="$(awk -v d="$delta" -v t="$THRESHOLD" 'BEGIN{ if (d>t) print "slow"; else if (d<-t) print "fast"; else print "noise" }')"
	case "$flag" in
		slow) status='⚠️ slower'; regressions=$((regressions + 1)) ;;
		fast) status='✅ faster' ;;
		*)    status='≈ noise' ;;
	esac
	if [ "$flag" = slow ] && awk -v d="$delta" -v t="$ISSUE_THRESHOLD" 'BEGIN{ exit !(d > t) }'; then
		issue_regressions=$((issue_regressions + 1))
	fi
	emit "| \`$name\` | $(printf '%.3f' "$base_min")s | $(printf '%.3f' "$head_min")s | ${delta}% | $status |"
done

emit ''
if [ "$issue_regressions" -gt 0 ]; then
	emit "**${issue_regressions} regression(s) > ${ISSUE_THRESHOLD}%** — opening/updating an issue. Confirm locally on a quiesced machine (\`governor=performance\`, turbo off) before acting — see BEST_PRACTICES.md §10."
elif [ "$regressions" -gt 0 ]; then
	emit "**${regressions} possible regression(s) > ${THRESHOLD}%** but below the ${ISSUE_THRESHOLD}% issue bar — likely runner noise. Confirm locally (§10)."
else
	emit "_No change beyond the ${THRESHOLD}% noise floor._"
fi
emit ''
emit "<sub>min of ${BENCH_RUNS} core-pinned runs per build · generated by \`.github/workflows/bench.yml\`</sub>"

# Hand the verdict to the workflow (which decides whether to open an issue).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		[ "$issue_regressions" -gt 0 ] && echo "regressed=true" || echo "regressed=false"
		echo "regressions=${regressions}"
		echo "issue_regressions=${issue_regressions}"
	} >> "$GITHUB_OUTPUT"
fi

# Measurement succeeded — report via the comment/summary/issue, not the exit
# code. A regression never fails the CI step (this runs post-merge; failing it
# would block nothing and only add red noise).
exit 0
