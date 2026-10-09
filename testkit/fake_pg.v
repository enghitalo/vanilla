module testkit

import os
import time

// fake_pg_script is pg_async/testdata/fake_pg.py in this checkout: the
// scriptable fake PostgreSQL server (python3, stdlib only) that makes a
// server-side close, a FATAL or a hung reply deterministic in tests. Its
// docstring lists the modes.
pub const fake_pg_script = os.join_path(@VMODROOT, 'pg_async', 'testdata', 'fake_pg.py')

// FakePg is one running fake_pg.py process. Point a pg_async.ConnConfig at
// 127.0.0.1:port (user anything, password 'secret' unless --password), and
// stop() it when done.
pub struct FakePg {
pub:
	port       int
	stats_path string
mut:
	proc &os.Process = unsafe { nil }
	dir  string
}

// fake_pg_available reports whether the fake server can run here: python3 on
// PATH. A test that needs it skips when it is missing, unless
// VANILLA_REQUIRE_FAKE_PG is set (CI), where a missing python3 is a failure.
pub fn fake_pg_available() bool {
	if _ := os.find_abs_path_of_executable('python3') {
		return true
	}
	if os.getenv('VANILLA_REQUIRE_FAKE_PG') != '' {
		panic('VANILLA_REQUIRE_FAKE_PG is set but python3 is not on PATH')
	}
	return false
}

// start_fake_pg launches fake_pg.py with extra command-line `args` (e.g.
// ['--close', 'fatal']) and returns once it listens.
pub fn start_fake_pg(args []string) !FakePg {
	python := os.find_abs_path_of_executable('python3') or {
		return error('fake_pg: python3 not found on PATH')
	}
	dir := os.join_path(os.temp_dir(), 'vanilla_fake_pg_${os.getpid()}_${time.sys_mono_now()}')
	os.mkdir_all(dir)!
	port_file := os.join_path(dir, 'port')
	stats := os.join_path(dir, 'stats')
	mut p := os.new_process(python)
	mut all := [fake_pg_script, '--port-file', port_file, '--stats-file', stats]
	all << args
	p.set_args(all)
	p.run()
	// The script writes the port file atomically once it listens.
	for _ in 0 .. 1000 {
		if os.exists(port_file) {
			port := (os.read_file(port_file) or { '' }).trim_space().int()
			if port > 0 {
				return FakePg{
					port:       port
					stats_path: stats
					proc:       p
					dir:        dir
				}
			}
		}
		if !p.is_alive() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	p.signal_kill()
	p.wait()
	p.close()
	os.rmdir_all(dir) or {}
	return error('fake_pg: the server did not start (args ${args})')
}

// stop kills the fake server and removes its files.
pub fn (mut f FakePg) stop() {
	if f.proc != unsafe { nil } {
		f.proc.signal_kill()
		f.proc.wait()
		f.proc.close()
		f.proc = unsafe { nil }
	}
	os.rmdir_all(f.dir) or {}
}

// gen_test_ca_script is pg_async/testdata/gen_test_ca.sh: the throwaway test
// CA and server certificates for TLS tests (openssl, at test time).
pub const gen_test_ca_script = os.join_path(@VMODROOT, 'pg_async', 'testdata', 'gen_test_ca.sh')

// test_certs_available reports whether test_certs can run here: openssl on
// PATH. Like fake_pg_available, a missing openssl is a failure instead of a
// skip when VANILLA_REQUIRE_FAKE_PG is set (CI).
pub fn test_certs_available() bool {
	if _ := os.find_abs_path_of_executable('openssl') {
		return true
	}
	if os.getenv('VANILLA_REQUIRE_FAKE_PG') != '' {
		panic('VANILLA_REQUIRE_FAKE_PG is set but openssl is not on PATH')
	}
	return false
}

// test_certs writes a fresh test CA and certificates (gen_test_ca.sh: ca.crt,
// server.crt/.key for localhost, 127.0.0.1 and ::1, wronghost.crt/.key,
// other_ca.crt) into a new temporary directory and returns it. The keys are
// generated here, never committed; remove the directory when done.
pub fn test_certs() !string {
	dir := os.join_path(os.temp_dir(), 'vanilla_test_certs_${os.getpid()}_${time.sys_mono_now()}')
	res := os.execute('${os.quoted_path(gen_test_ca_script)} ${os.quoted_path(dir)}')
	if res.exit_code != 0 {
		return error('gen_test_ca.sh failed: ${res.output}')
	}
	return dir
}

// stat returns one of the fake server's counters (accepted, authenticated,
// queries — one per Sync —, statements — one per Bind —, rollbacks,
// conflicts, server_closes, ssl_requests, tls_handshakes, sni, tickets,
// cancel_requests), 0 when not seen yet.
pub fn (f &FakePg) stat(key string) int {
	content := os.read_file(f.stats_path) or { return 0 }
	for line in content.split_into_lines() {
		if line.starts_with(key + '=') {
			return line.all_after('=').int()
		}
	}
	return 0
}
