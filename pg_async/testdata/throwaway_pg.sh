#!/usr/bin/env bash
# throwaway_pg.sh — a disposable, seeded PostgreSQL cluster for pg_async's live
# tests and benchmarks, built from the local server binaries (initdb + pg_ctl;
# no Docker needed). CI uses service containers instead (pg_async.yml); this is
# the same setup for a developer machine.
#
#   eval "$(pg_async/testdata/throwaway_pg.sh start)"   # prints the PG* exports
#   v test pg_async/                                     # the live tests now run
#   pg_async/testdata/throwaway_pg.sh stop
#
# Environment:
#   PG_PORT  TCP port on 127.0.0.1 (default 55432)
#   PG_DIR   cluster directory (default ${TMPDIR:-/tmp}/vanilla-pg-$PG_PORT)
#   PG_BIN   directory holding initdb/pg_ctl/psql (default: the newest
#            /usr/lib/postgresql/*/bin, else PATH)
#   PG_TLS=1 a TLS-only cluster: ssl=on with a fresh test CA (gen_test_ca.sh,
#            written to $PG_DIR/certs), and every TCP pg_hba line hostssl —
#            user `bench` authenticates with scram-sha-256, user `pw_user`
#            with `password` (cleartext, over TLS only). Plaintext TCP is
#            rejected.
#   PG_CPUS  taskset CPU list for the server and its backends (benchmarks)
#
# The cluster: user bench / password benchpw, database bench, scram-sha-256,
# seeded with pg_async_demo (examples/async_db_pg's table). Run as root, the
# server runs as the `postgres` user (PostgreSQL refuses to run as root).

set -euo pipefail

port="${PG_PORT:-55432}"
dir="${PG_DIR:-${TMPDIR:-/tmp}/vanilla-pg-$port}"
here="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${PG_BIN:-}" ]; then
	PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)
	[ -n "$PG_BIN" ] || PG_BIN=$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/initdb)")
fi
[ -x "$PG_BIN/initdb" ] || { echo "throwaway_pg: no initdb in $PG_BIN (set PG_BIN)" >&2; exit 2; }

# as_pg runs a command as the cluster owner.
as_pg() {
	if [ "$(id -u)" = 0 ]; then
		runuser -u postgres -- "$@"
	else
		"$@"
	fi
}

stop() {
	if [ -f "$dir/data/postmaster.pid" ]; then
		as_pg "$PG_BIN/pg_ctl" -D "$dir/data" -m immediate -w stop >/dev/null 2>&1 || true
	fi
	rm -rf "$dir"
}

start() {
	stop
	mkdir -p "$dir"
	printf 'benchpw\n' > "$dir/pwfile"
	if [ "$(id -u)" = 0 ]; then
		chown -R postgres "$dir"
		as_pg test -r "$dir/pwfile" || {
			echo "throwaway_pg: the postgres user cannot reach $dir (a parent directory is not traversable): set PG_DIR" >&2
			exit 2
		}
	fi
	as_pg "$PG_BIN/initdb" -D "$dir/data" -U bench --pwfile="$dir/pwfile" \
		--auth=scram-sha-256 -E UTF8 --locale=C >"$dir/initdb.log" 2>&1
	{
		echo "listen_addresses = '127.0.0.1'"
		echo "port = $port"
		echo "unix_socket_directories = ''" # TCP only: a deep $dir overflows sun_path
		echo "max_connections = 400"
		echo "fsync = off"
		echo "synchronous_commit = off"
		echo "full_page_writes = off"
	} >> "$dir/data/postgresql.conf"
	if [ "${PG_TLS:-0}" = 1 ]; then
		"$here/gen_test_ca.sh" "$dir/certs" >/dev/null
		[ "$(id -u)" = 0 ] && chown -R postgres "$dir/certs"
		{
			echo "ssl = on"
			echo "ssl_cert_file = '$dir/certs/server.crt'"
			echo "ssl_key_file = '$dir/certs/server.key'"
			echo "ssl_min_protocol_version = 'TLSv1.2'"
		} >> "$dir/data/postgresql.conf"
		cat > "$dir/data/pg_hba.conf" <<-HBA
			hostssl   all  pw_user  127.0.0.1/32  password
			hostssl   all  all      127.0.0.1/32  scram-sha-256
			hostnossl all  all      0.0.0.0/0     reject
		HBA
	else
		cat > "$dir/data/pg_hba.conf" <<-HBA
			host  all  all  127.0.0.1/32  scram-sha-256
		HBA
	fi
	[ "$(id -u)" = 0 ] && chown postgres "$dir/data/pg_hba.conf"
	pin=()
	[ -n "${PG_CPUS:-}" ] && pin=(taskset -c "$PG_CPUS") # the backends inherit it
	as_pg "${pin[@]}" "$PG_BIN/pg_ctl" -D "$dir/data" -l "$dir/server.log" -w start >/dev/null
	export PGPASSWORD=benchpw
	if [ "${PG_TLS:-0}" = 1 ]; then
		export PGSSLMODE=verify-full PGSSLROOTCERT="$dir/certs/ca.crt"
	fi
	"$PG_BIN/psql" -h 127.0.0.1 -p "$port" -U bench -d postgres -qAt -c 'create database bench' >/dev/null
	"$PG_BIN/psql" -h 127.0.0.1 -p "$port" -U bench -d bench -qAt -v ON_ERROR_STOP=1 >/dev/null <<-SQL
		create table pg_async_demo (id int4 primary key, name text);
		insert into pg_async_demo values (1, 'alpha'), (2, 'beta'), (3, 'gamma');
		create role pw_user login password 'pwpass';
		grant all on pg_async_demo to pw_user;
	SQL
	echo "export PGHOST=127.0.0.1 PGPORT=$port PGUSER=bench PGPASSWORD=benchpw PGDATABASE=bench"
	if [ "${PG_TLS:-0}" = 1 ]; then
		echo "export PG_TEST_CA=$dir/certs/ca.crt PG_TEST_CERTS=$dir/certs"
	fi
	echo "# throwaway PostgreSQL ($("$PG_BIN/postgres" --version)) up in $dir" >&2
}

case "${1:-}" in
	start) start ;;
	stop) stop ;;
	*)
		echo "usage: $0 start|stop" >&2
		exit 2
		;;
esac
