#!/usr/bin/env bash
# macos_test_and_bench.sh — build every example, exercise every route, and
# benchmark examples/tiny/src on macOS. Results land in
# BENCHMARK_RESULTS_MACOS.md at the repo root.
#
# Usage:   ./scripts/macos_test_and_bench.sh
# Needs:   V on PATH. Installs wrk + hey via Homebrew if missing.
#          (ab ships with macOS; ffmpeg/libpq/PostgreSQL are optional —
#           the examples that need them are skipped when absent.)
#
# Compatible with the stock macOS bash 3.2 (no assoc arrays, no ${var,,}).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/BENCHMARK_RESULTS_MACOS.md"
WORK="$(mktemp -d /tmp/vanilla_bench.XXXXXX)"
BINDIR="$WORK/bins"
RUNDIR="$WORK/run"
PORT=3000
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0
SKIP=0
ROWS=""        # accumulated markdown table rows
FAIL_LOGS=""   # accumulated server-log excerpts for failures
SERVER_PID=""

mkdir -p "$BINDIR" "$RUNDIR"

# Benchmarks need way more fds than the macOS default of 256.
ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || true

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- tooling ---
say "Checking tools"
if ! command -v v >/dev/null 2>&1; then
	echo "ERROR: V compiler not on PATH (https://vlang.io)" >&2
	exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
	echo "WARNING: Homebrew missing — cannot auto-install wrk/hey" >&2
else
	command -v wrk >/dev/null 2>&1 || brew install wrk
	command -v hey >/dev/null 2>&1 || brew install hey
	# DB headers for simple3/hexagonal/database: vlib's db.sqlite darwin branch
	# links -lsqlite3 but never includes sqlite3.h, and db.pg needs libpq-fe.h —
	# both work via their $pkgconfig branches. Install the keg-only brew
	# packages and expose their .pc files.
	command -v pkg-config >/dev/null 2>&1 || brew install pkgconf
	brew list sqlite >/dev/null 2>&1 || brew install sqlite
	brew list libpq >/dev/null 2>&1 || brew install libpq
fi
if command -v brew >/dev/null 2>&1; then
	for pkg in sqlite libpq; do
		PREFIX="$(brew --prefix $pkg 2>/dev/null)"
		if [ -n "$PREFIX" ] && [ -d "$PREFIX/lib/pkgconfig" ]; then
			export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
		fi
	done
fi
command -v wrk >/dev/null 2>&1 || echo "WARNING: wrk not available — wrk benchmarks will be SKIPPED (brew install wrk)" >&2
command -v hey >/dev/null 2>&1 || echo "WARNING: hey not available — hey benchmark will be SKIPPED (brew install hey)" >&2
AB="$(command -v ab || echo /usr/sbin/ab)"
[ -x "$AB" ] || AB=""

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
	echo "ERROR: something is already listening on port $PORT — stop it first:" >&2
	lsof -nP -iTCP:$PORT -sTCP:LISTEN >&2
	exit 1
fi

# ------------------------------------------------------------ tiny helpers ---
# poor-man's timeout (macOS has no `timeout`)
with_timeout() { # seconds cmd...
	local secs=$1; shift
	"$@" & local p=$!
	( sleep "$secs"; kill "$p" 2>/dev/null ) & local w=$!
	wait "$p" 2>/dev/null; local rc=$?
	kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
	return $rc
}

port_in_use() { lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; }

wait_port_up() {
	local i=0
	while [ $i -lt 100 ]; do
		port_in_use && return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}

wait_port_down() {
	local i=0
	while [ $i -lt 100 ]; do
		port_in_use || return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}

# start_server <cwd> <binary> — runs binary with cwd set, logs to server.log
start_server() {
	local dir="$1" bin="$2"
	mkdir -p "$dir"
	( cd "$dir" && exec "$bin" ) > "$WORK/server.log" 2>&1 &
	SERVER_PID=$!
	if ! wait_port_up; then
		return 1
	fi
	return 0
}

stop_server() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
	# safety net: anything still squatting on the port
	lsof -nP -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null
	wait_port_down || true
}

row() { ROWS="$ROWS| $1 | $2 | $3 | $4 | $5 |"$'\n'; }

# check <example> <desc> <expected_code> [curl args...]
# An sse/stream check may hit curl's --max-time (exit 28) after receiving the
# status line — that still counts, we compare the received code only.
check() {
	local ex="$1" desc="$2" expect="$3"; shift 3
	local code rc
	code=$(curl -s -o "$WORK/body" -w '%{http_code}' --max-time 10 "$@" 2>/dev/null)
	rc=$?
	if [ "$code" = "$expect" ]; then
		PASS=$((PASS + 1)); row "$ex" "$desc" "$expect" "$code" "✅"
	elif [ $rc -ne 0 ] && [ $rc -ne 28 ]; then
		FAIL=$((FAIL + 1)); row "$ex" "$desc" "$expect" "curl exit $rc" "❌"
	else
		FAIL=$((FAIL + 1)); row "$ex" "$desc" "$expect" "$code" "❌"
	fi
}

skip() { SKIP=$((SKIP + 1)); row "$1" "$2" "-" "skipped: $3" "⏭️"; }

note_failure_log() { # example
	FAIL_LOGS="$FAIL_LOGS"$'\n'"### $1"$'\n''```'$'\n'"$(tail -20 "$WORK/server.log" 2>/dev/null)"$'\n''```'$'\n'
}

# build <example> <srcdir-relative> -> echoes binary path, rc!=0 on failure
build_example() {
	local ex="$1" src="$2" bin="$BINDIR/$1"
	if v -o "$bin" "$ROOT/$src" > "$WORK/build_$ex.log" 2>&1; then
		echo "$bin"; return 0
	fi
	return 1
}

# run_simple <example> <srcdir> then a list of checks via callback function
begin_example() { # example srcdir -> 0 ok (server running), 1 skipped/failed
	local ex="$1" src="$2"
	say "[$ex] build + start"
	local bin
	if ! bin=$(build_example "$ex" "$src"); then
		FAIL=$((FAIL + 1)); row "$ex" "BUILD" "ok" "compile error (see build_$ex.log)" "❌"
		FAIL_LOGS="$FAIL_LOGS"$'\n'"### $ex (build)"$'\n''```'$'\n'"$(tail -25 "$WORK/build_$ex.log")"$'\n''```'$'\n'
		return 1
	fi
	if ! start_server "$RUNDIR/$ex" "$bin"; then
		FAIL=$((FAIL + 1)); row "$ex" "START" "listening" "did not listen" "❌"
		note_failure_log "$ex"
		stop_server
		return 1
	fi
	return 0
}

end_example() { stop_server; }

# =================================================================== tests ===
say "Route tests for every example (sequential, all on port $PORT)"

# --- tiny ---
if begin_example tiny examples/tiny/src; then
	check tiny "GET /" 200 "$BASE/"
	end_example
fi

# --- simple ---
if begin_example simple examples/simple/src; then
	check simple "GET /" 200 "$BASE/"
	check simple "GET /user/42" 200 "$BASE/user/42"
	check simple "POST /user" 201 -X POST "$BASE/user"
	check simple "GET /nope (fallback)" 400 "$BASE/nope"
	end_example
fi

# --- simple2 ---
if begin_example simple2 examples/simple2/src; then
	check simple2 "GET /" 200 "$BASE/"
	check simple2 "GET /users" 200 "$BASE/users"
	check simple2 "GET /user/42" 200 "$BASE/user/42"
	check simple2 "POST /user" 201 -X POST "$BASE/user"
	end_example
fi

# --- simple3 (creates simple.db in cwd) ---
if begin_example simple3 examples/simple3/src; then
	check simple3 "GET /" 200 "$BASE/"
	check simple3 "GET /user/42" 200 "$BASE/user/42"
	check simple3 "POST /user" 201 -X POST "$BASE/user"
	end_example
fi

# --- auth (bearer token flow) ---
if begin_example auth examples/auth/src; then
	check auth "GET /token" 200 "$BASE/token"
	TOKEN=$(curl -s --max-time 10 "$BASE/token" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
	if [ -n "${TOKEN:-}" ]; then
		check auth "GET /protected (token)" 200 -H "Authorization: Bearer $TOKEN" "$BASE/protected"
	else
		FAIL=$((FAIL + 1)); row auth "GET /protected (token)" 200 "no token extracted" "❌"
	fi
	check auth "GET /protected (no token)" 401 "$BASE/protected"
	check auth "GET /service (good key)" 200 -H 'X-API-Key: secret-api-key-123' "$BASE/service"
	check auth "GET /service (bad key)" 401 -H 'X-API-Key: wrong' "$BASE/service"
	end_example
fi

# --- chunked_streaming ---
if begin_example chunked_streaming examples/chunked_streaming/src; then
	check chunked_streaming "GET / (chunked)" 200 "$BASE/"
	end_example
fi

# --- compression ---
if begin_example compression examples/compression/src; then
	check compression "GET / (gzip)" 200 --compressed -H 'Accept-Encoding: gzip' "$BASE/"
	check compression "GET / (identity)" 200 "$BASE/"
	end_example
fi

# --- cookies_sessions ---
if begin_example cookies_sessions examples/cookies_sessions/src; then
	JAR="$WORK/cookies.txt"; rm -f "$JAR"
	check cookies_sessions "GET /login (set cookie)" 200 -c "$JAR" "$BASE/login"
	check cookies_sessions "GET /me (with sid)" 200 -b "$JAR" "$BASE/me"
	check cookies_sessions "GET /me (no cookie)" 401 "$BASE/me"
	check cookies_sessions "GET /logout" 200 -b "$JAR" "$BASE/logout"
	end_example
fi

# --- cors ---
if begin_example cors examples/cors/src; then
	check cors "OPTIONS preflight (allowed origin)" 204 -X OPTIONS -H 'Origin: http://localhost:5173' -H 'Access-Control-Request-Method: PUT' "$BASE/"
	check cors "OPTIONS preflight (evil origin)" 403 -X OPTIONS -H 'Origin: https://evil.example' "$BASE/"
	check cors "GET / (allowed origin)" 200 -H 'Origin: http://localhost:5173' "$BASE/"
	check cors "GET / (no origin)" 200 "$BASE/"
	end_example
fi

# --- csrf (double-submit cookie) ---
if begin_example csrf examples/csrf/src; then
	JAR="$WORK/csrf.txt"; rm -f "$JAR"
	check csrf "GET /form (sets csrf cookie)" 200 -c "$JAR" "$BASE/form"
	CSRF=$(awk '$6 == "csrf" {print $7}' "$JAR" 2>/dev/null | tail -1)
	if [ -n "${CSRF:-}" ]; then
		check csrf "POST /submit (token ok)" 200 -X POST -b "csrf=$CSRF" -H "X-CSRF-Token: $CSRF" "$BASE/submit"
	else
		FAIL=$((FAIL + 1)); row csrf "POST /submit (token ok)" 200 "no csrf cookie extracted" "❌"
	fi
	check csrf "POST /submit (no token)" 403 -X POST "$BASE/submit"
	check csrf "GET / (safe method)" 200 "$BASE/"
	end_example
fi

# --- database (needs PostgreSQL on localhost:5435 + libpq) ---
if nc -z 127.0.0.1 5435 >/dev/null 2>&1; then
	if begin_example database examples/database/src; then
		check database "GET /" 200 "$BASE/"
		check database "GET /user" 200 "$BASE/user"
		check database "POST /user" 201 -X POST "$BASE/user"
		check database "GET /user/1" 200 "$BASE/user/1"
		end_example
	fi
else
	skip database "all routes" "no PostgreSQL at localhost:5435"
fi

# --- date_header ---
if begin_example date_header examples/date_header/src; then
	check date_header "GET /" 200 "$BASE/"
	end_example
fi

# --- etag ---
if begin_example etag examples/etag/src; then
	check etag "GET /" 200 "$BASE/"
	check etag "GET /user/123" 200 "$BASE/user/123"
	check etag "GET /user/123 (If-None-Match)" 304 -H 'If-None-Match: 202cb962ac59075b964b07152d234b70' "$BASE/user/123"
	check etag "POST /user" 201 -X POST "$BASE/user"
	end_example
fi

# --- graceful_shutdown (also verifies SIGTERM actually stops it) ---
if begin_example graceful_shutdown examples/graceful_shutdown/src; then
	check graceful_shutdown "GET /" 200 "$BASE/"
	kill -TERM "$SERVER_PID" 2>/dev/null
	if wait_port_down; then
		PASS=$((PASS + 1)); row graceful_shutdown "SIGTERM drains + exits" "port freed" "port freed" "✅"
	else
		FAIL=$((FAIL + 1)); row graceful_shutdown "SIGTERM drains + exits" "port freed" "still listening" "❌"
	fi
	end_example
fi

# --- hexagonal (CLI demo, not an HTTP server) ---
say "[hexagonal] build + run CLI demo"
if BIN=$(build_example hexagonal examples/hexagonal/src); then
	mkdir -p "$RUNDIR/hexagonal"
	if ( cd "$RUNDIR/hexagonal" && with_timeout 30 "$BIN" > cli.log 2>&1 ); then
		PASS=$((PASS + 1)); row hexagonal "CLI demo runs (sqlite)" "exit 0" "exit 0" "✅"
	else
		FAIL=$((FAIL + 1)); row hexagonal "CLI demo runs (sqlite)" "exit 0" "non-zero/timeout" "❌"
	fi
else
	FAIL=$((FAIL + 1)); row hexagonal "BUILD" "ok" "compile error" "❌"
fi

# --- io_uring_demo (uses default backend, runs everywhere) ---
if begin_example io_uring_demo examples/io_uring_demo/src; then
	check io_uring_demo "GET /" 200 "$BASE/"
	end_example
fi

# --- ip_block (localhost is always allowed) ---
if begin_example ip_block examples/ip_block/src; then
	check ip_block "GET / (localhost allowed)" 200 "$BASE/"
	end_example
fi

# --- json_api ---
if begin_example json_api examples/json_api/src; then
	check json_api "POST /users (valid)" 201 -H 'Content-Type: application/json' -d '{"name":"alice","email":"alice@example.com"}' "$BASE/users"
	check json_api "POST /users (invalid)" 400 -H 'Content-Type: application/json' -d '{"name":"","email":""}' "$BASE/users"
	# -H 'Expect:' — curl's default 100-continue split breaks the darwin
	# backend's single-burst read; send headers+body together.
	check json_api "POST /upload (multipart)" 200 -H 'Expect:' -F 'file=@/etc/hosts' "$BASE/upload"
	check json_api "GET / (fallback=400)" 400 "$BASE/"
	end_example
fi

# --- middleware ---
if begin_example middleware examples/middleware/src; then
	check middleware "GET /" 200 "$BASE/"
	check middleware "GET /me (tok-alice)" 200 -H 'Authorization: Bearer tok-alice' "$BASE/me"
	check middleware "GET /me (anon)" 401 "$BASE/me"
	check middleware "GET /admin (tok-root)" 200 -H 'Authorization: Bearer tok-root' "$BASE/admin"
	check middleware "GET /admin (tok-alice)" 403 -H 'Authorization: Bearer tok-alice' "$BASE/admin"
	check middleware "GET /nope" 404 "$BASE/nope"
	end_example
fi

# --- observability ---
if begin_example observability examples/observability/src; then
	check observability "GET /healthz" 200 "$BASE/healthz"
	check observability "GET /readyz" 200 "$BASE/readyz"
	check observability "GET /metrics" 200 "$BASE/metrics"
	check observability "GET /" 200 "$BASE/"
	end_example
fi

# --- proxy_aware ---
if begin_example proxy_aware examples/proxy_aware/src; then
	check proxy_aware "GET / (XFF)" 200 -H 'X-Forwarded-For: 203.0.113.7, 10.0.0.2' -H 'X-Forwarded-Proto: https' "$BASE/"
	check proxy_aware "GET / (no XFF)" 200 "$BASE/"
	end_example
fi

# --- rate_limit (burst past 20-token bucket, expect 429) ---
if begin_example rate_limit examples/rate_limit/src; then
	check rate_limit "GET / (first)" 200 "$BASE/"
	i=0; while [ $i -lt 25 ]; do curl -s -o /dev/null --max-time 5 "$BASE/"; i=$((i + 1)); done
	check rate_limit "GET / (bucket drained)" 429 "$BASE/"
	end_example
fi

# --- redirects ---
if begin_example redirects examples/redirects/src; then
	check redirects "GET /old" 301 "$BASE/old"
	check redirects "POST /login" 303 -X POST "$BASE/login"
	check redirects "POST /login?next=/settings" 303 -X POST "$BASE/login?next=/settings"
	check redirects "GET /login" 200 "$BASE/login"
	check redirects "GET /api/v1/resource" 308 "$BASE/api/v1/resource"
	check redirects "GET /anything (fallback)" 200 "$BASE/anything"
	end_example
fi

# --- request_limits ---
if begin_example request_limits examples/request_limits/src; then
	check request_limits "GET /" 200 "$BASE/"
	BIG="$WORK/big.bin"
	[ -f "$BIG" ] || dd if=/dev/zero of="$BIG" bs=1048576 count=11 2>/dev/null
	check request_limits "POST 11MiB body (413)" 413 -X POST -H 'Content-Type: application/octet-stream' --data-binary "@$BIG" "$BASE/"
	PAD=$(/usr/bin/python3 -c 'print("a"*20000)')
	check request_limits "20KB header (431)" 431 -H "X-Pad: $PAD" "$BASE/"
	end_example
fi

# --- security_headers ---
if begin_example security_headers examples/security_headers/src; then
	check security_headers "GET /" 200 "$BASE/"
	HDRS=$(curl -sI --max-time 10 "$BASE/")
	if echo "$HDRS" | grep -qi 'strict-transport-security' && echo "$HDRS" | grep -qi 'content-security-policy'; then
		PASS=$((PASS + 1)); row security_headers "HSTS + CSP present" "present" "present" "✅"
	else
		FAIL=$((FAIL + 1)); row security_headers "HSTS + CSP present" "present" "missing" "❌"
	fi
	end_example
fi

# --- sse (long-lived stream; curl exit 28 after --max-time is fine) ---
if begin_example sse examples/sse/src; then
	check sse "GET /events (stream)" 200 -N --max-time 3 "$BASE/events"
	check sse "POST /broadcast" 200 -X POST -d 'hello subscribers' "$BASE/broadcast"
	check sse "GET / (fallback=400)" 400 "$BASE/"
	end_example
fi

# --- static_files (needs ./public in cwd) ---
mkdir -p "$RUNDIR/static_files/public"
printf '<h1>hello vanilla</h1>\n' > "$RUNDIR/static_files/public/index.html"
if begin_example static_files examples/static_files/src; then
	check static_files "GET / (index.html)" 200 "$BASE/"
	check static_files "GET /index.html (Range)" 206 -H 'Range: bytes=0-3' "$BASE/index.html"
	ETAG=$(curl -sI --max-time 10 "$BASE/index.html" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
	if [ -n "${ETAG:-}" ]; then
		check static_files "GET /index.html (If-None-Match)" 304 -H "If-None-Match: $ETAG" "$BASE/index.html"
	else
		FAIL=$((FAIL + 1)); row static_files "GET /index.html (If-None-Match)" 304 "no ETag header" "❌"
	fi
	check static_files "POST / (405)" 405 -X POST "$BASE/"
	check static_files "GET /../etc/passwd (traversal)" 404 --path-as-is "$BASE/../etc/passwd"
	check static_files "GET /missing.txt" 404 "$BASE/missing.txt"
	end_example
fi

# --- url_form ---
if begin_example url_form examples/url_form/src; then
	check url_form "GET with query params" 200 "$BASE/x?q=hello%20world&tag=c%2B%2B"
	check url_form "POST urlencoded form" 200 -H 'Content-Type: application/x-www-form-urlencoded' -d 'name=jo%C3%A3o&city=s%C3%A3o+paulo' "$BASE/"
	check url_form "GET / (empty)" 200 "$BASE/"
	end_example
fi

# --- veb_like (lives at examples/veb_like, no src/) ---
if begin_example veb_like examples/veb_like; then
	check veb_like "GET /users" 200 "$BASE/users"
	check veb_like "POST /users" 201 -X POST "$BASE/users"
	check veb_like "GET /users/7" 200 "$BASE/users/7"
	check veb_like "PUT /users/7" 200 -X PUT "$BASE/users/7"
	check veb_like "PATCH /users/7" 200 -X PATCH "$BASE/users/7"
	check veb_like "DELETE /users/7" 200 -X DELETE "$BASE/users/7"
	check veb_like "GET /users/7/profile" 200 "$BASE/users/7/profile"
	check veb_like "GET /users/7/posts/99" 200 "$BASE/users/7/posts/99"
	check veb_like "GET /users/7/posts/99/comments/3" 200 "$BASE/users/7/posts/99/comments/3"
	check veb_like "GET /tags/a/b/c" 200 "$BASE/tags/a/b/c"
	check veb_like "GET /search/vlang" 200 "$BASE/search/vlang"
	check veb_like "GET /files/css/app.css" 200 "$BASE/files/css/app.css"
	check veb_like "GET /proxy/api.example.com/v1" 200 "$BASE/proxy/api.example.com/v1"
	check veb_like "POST /users/7 (405)" 405 -X POST "$BASE/users/7"
	check veb_like "GET /nope (404)" 404 "$BASE/nope"
	end_example
fi

# --- video_stream (file route; webcam is Linux/V4L2-only) ---
if command -v ffmpeg >/dev/null 2>&1; then
	if begin_example video_stream examples/video_stream/src; then
		sleep 2 # give the one-time ffmpeg sample.mp4 generation a moment
		check video_stream "GET /" 200 "$BASE/"
		check video_stream "GET /video (Range)" 206 -H 'Range: bytes=0-1023' "$BASE/video"
		check video_stream "GET /video (full)" 200 "$BASE/video"
		check video_stream "POST / (405)" 405 -X POST "$BASE/"
		skip video_stream "GET /webcam" "V4L2 webcam capture is Linux-only"
		end_example
	fi
else
	skip video_stream "all routes" "ffmpeg not installed (brew install ffmpeg)"
fi

# ============================================================== benchmarks ===
say "Benchmarks: examples/tiny/src built with -prod"
BENCH_OUT="$WORK/bench"
mkdir -p "$BENCH_OUT"
TINY_PROD="$BINDIR/tiny_prod"
BENCH_OK=0
if v -prod -o "$TINY_PROD" "$ROOT/examples/tiny/src" > "$WORK/build_tiny_prod.log" 2>&1; then
	if start_server "$RUNDIR/tiny_bench" "$TINY_PROD"; then
		BENCH_OK=1
		# warmup
		i=0; while [ $i -lt 500 ]; do curl -s -o /dev/null "$BASE/"; i=$((i + 1)); done

		if command -v wrk >/dev/null 2>&1; then
			say "wrk: 8t/64c, 8t/256c, 16t/512c — 10s each, keep-alive"
			wrk -t8  -c64  -d10s "$BASE/" > "$BENCH_OUT/wrk_8t_64c.txt"   2>&1
			wrk -t8  -c256 -d10s "$BASE/" > "$BENCH_OUT/wrk_8t_256c.txt"  2>&1
			wrk -t16 -c512 -d10s -H 'Connection: keep-alive' "$BASE/" > "$BENCH_OUT/wrk_16t_512c.txt" 2>&1
		fi
		if command -v hey >/dev/null 2>&1; then
			say "hey: 128c for 10s"
			hey -z 10s -c 128 "$BASE/" > "$BENCH_OUT/hey_128c.txt" 2>&1
		fi
		if [ -n "$AB" ]; then
			say "ab: 200k requests, 128c, keep-alive"
			"$AB" -k -n 200000 -c 128 "$BASE/" > "$BENCH_OUT/ab_128c.txt" 2>&1 || true
		fi
		stop_server
	else
		echo "ERROR: tiny -prod build did not listen" >&2
	fi
else
	echo "ERROR: v -prod build of examples/tiny/src failed (see $WORK/build_tiny_prod.log)" >&2
fi

# ================================================================== report ===
say "Writing $OUT"
{
	echo "# vanilla — macOS route tests & benchmarks"
	echo
	echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z') by \`scripts/macos_test_and_bench.sh\`"
	echo
	echo "## System"
	echo
	echo '```'
	sw_vers
	echo "arch:        $(uname -m)"
	echo "cpu:         $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
	echo "cores:       $(sysctl -n hw.ncpu)"
	echo "memory:      $(($(sysctl -n hw.memsize) / 1073741824)) GiB"
	echo "v:           $(v version)"
	echo "wrk:         $(command -v wrk >/dev/null 2>&1 && wrk --version 2>&1 | head -1 || echo 'NOT INSTALLED — wrk results missing')"
	echo "hey:         $(command -v hey >/dev/null 2>&1 && echo installed || echo 'NOT INSTALLED — hey results missing')"
	[ -n "$AB" ] && echo "ab:          $("$AB" -V 2>/dev/null | head -1)"
	echo "ulimit -n:   $(ulimit -n)"
	echo "somaxconn:   $(sysctl -n kern.ipc.somaxconn 2>/dev/null)"
	echo '```'
	echo
	echo "> Backend: kqueue (darwin default). Examples were built with plain \`v\`;"
	echo "> the benchmark target \`examples/tiny/src\` was built with \`v -prod\`."
	echo
	echo "## Route tests — all examples"
	echo
	echo "Result: **$PASS passed**, **$FAIL failed**, **$SKIP skipped**"
	echo
	echo "| Example | Check | Expected | Got | Result |"
	echo "|---|---|---|---|---|"
	printf '%s' "$ROWS"
	echo
	if [ -n "$FAIL_LOGS" ]; then
		echo "## Failure logs (last lines)"
		printf '%s\n' "$FAIL_LOGS"
	fi
	echo "## Benchmarks — examples/tiny/src (\`v -prod\`, kqueue backend)"
	echo
	if [ $BENCH_OK -eq 1 ]; then
		for f in wrk_8t_64c wrk_8t_256c wrk_16t_512c hey_128c ab_128c; do
			if [ -s "$BENCH_OUT/$f.txt" ]; then
				case $f in
					wrk_8t_64c)   echo "### wrk — 8 threads, 64 connections, 10 s" ;;
					wrk_8t_256c)  echo "### wrk — 8 threads, 256 connections, 10 s" ;;
					wrk_16t_512c) echo "### wrk — 16 threads, 512 connections, 10 s (CONTRIBUTING.md config)" ;;
					hey_128c)     echo "### hey — 128 connections, 10 s" ;;
					ab_128c)      echo "### ab — 200 000 requests, 128 connections, keep-alive" ;;
				esac
				echo
				echo '```'
				cat "$BENCH_OUT/$f.txt"
				echo '```'
				echo
			fi
		done
	else
		echo "_Benchmark run failed — see $WORK/build_tiny_prod.log_"
	fi
	command -v wrk >/dev/null 2>&1 || {
		echo "> **wrk was not installed** — run \`brew install wrk\` and rerun this script for wrk numbers."
		echo
	}
	echo "## Notes"
	echo
	echo "- The darwin kqueue backend now supports HTTP keep-alive, SO_NOSIGPIPE,"
	echo "  TCP_NODELAY on accepted sockets, correct EV_EOF handling, and the"
	echo "  configured \`Limits\` (413/431) — see git log for the macOS fix set."
	echo "- macOS \`kern.ipc.somaxconn\` defaults to 128; for high-connection-count"
	echo "  benchmarks consider \`sudo sysctl -w kern.ipc.somaxconn=1024\`."
	echo "- ab on macOS sometimes aborts with \`apr_socket_recv\`; rerun if needed."
} > "$OUT"

say "Done: $PASS passed, $FAIL failed, $SKIP skipped"
say "Report: $OUT"
say "Scratch (server/build/bench logs): $WORK"
[ $FAIL -eq 0 ]
