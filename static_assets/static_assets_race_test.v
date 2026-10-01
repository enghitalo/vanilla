module static_assets

// follow_disk under contention: the target of `v -race` (ThreadSanitizer).
//
// Readers on spawned threads serve one asset in a loop, each into its own
// preallocated buffer, while the test thread replaces the file 300 times,
// alternating a small version (A, kept in RAM) and one above the sendfile
// threshold (B). With revalidate_ms 0 every request stats the file and several
// readers race to rebuild each new version; with revalidate_ms 1 they also
// race on the next_check CAS that elects each window's one checker. Every
// response must be a complete, consistent version: a body that is A or B,
// with that body's Content-Length and ETag. A torn or unpublished snapshot
// shows up as a wrong body, a framing mismatch or (under -race) a reported
// data race. Each reader also records the snapshots current() hands it, and
// every one must be on the final cur/prev chain: a snapshot published and then
// overwritten by a concurrent rebuild is reachable from nothing (an orphan),
// while a borrowed send may still point into it.
import os
import time
import sync.stdatomic
import hash as wyhash

const race_readers = 8
const race_swaps = 300
const race_threshold = 16 * 1024
// Room for every snapshot a reader can be handed: at most one per change of
// the file, plus slack so an orphan shows up as one, not as an overflow.
const race_max_snaps = 2 * race_swaps + 2

struct RaceCase {
	s      &AssetServer
	rep    &Variant // f.bin's identity representation
	a      []u8
	b      []u8
	etag_a string
	etag_b string // '' when B is disk-backed (its ETag hashes size and mtime)
mut:
	stop u64
}

struct RaceTally {
	seen_a   int
	seen_b   int
	bad      int
	first    string // the first bad response, for the failure message
	snaps    []u64  // the distinct snapshots current() returned, in order
	overflow int    // snapshots that did not fit in `snaps`
}

fn race_pattern(n int, seed int) []u8 {
	mut b := []u8{len: n}
	for i in 0 .. n {
		b[i] = u8((i * 13 + seed * 29 + i / 509) & 0xff)
	}
	return b
}

fn race_replace(dir string, content []u8) {
	tmp := os.join_path(dir, '.tmp')
	os.write_file_array(tmp, content) or { panic(err) }
	os.rename(tmp, os.join_path(dir, 'f.bin')) or { panic(err) }
}

// content_etag is the ETag of a body kept in RAM: the quoted 16-hex-digit
// wyhash of the body.
fn content_etag(body []u8) string {
	mut b := etag_placeholder.bytes()
	put_hex16(mut b, 1, wyhash.wyhash_c(body.data, u64(body.len), 0))
	return b.bytestr()
}

// race_check returns '' when `resp` is a complete, consistent A or B, else why
// not. Its result also tells which version it was.
fn race_check(c &RaceCase, resp []u8) (string, bool) {
	s := resp.bytestr()
	i := s.index('\r\n\r\n') or { return 'no header terminator', false }
	head := s[..i]
	body := resp[i + 4..]
	if !head.starts_with('HTTP/1.1 200 OK\r\n') {
		return 'status: ${head.all_before('\r\n')}', false
	}
	mut clen := -1
	mut etag := ''
	for line in head.split('\r\n') {
		if line.starts_with('Content-Length: ') {
			clen = line.all_after(': ').int()
		} else if line.starts_with('ETag: ') {
			etag = line.all_after(': ')
		}
	}
	if clen != body.len {
		return 'Content-Length ${clen} for a ${body.len}-byte body', false
	}
	if body == c.a {
		if etag != c.etag_a {
			return 'A with ETag ${etag}', false
		}
		return '', false
	}
	if body == c.b {
		if (c.etag_b != '' && etag != c.etag_b) || etag == c.etag_a || etag.len != 18 {
			return 'B with ETag ${etag}', true
		}
		return '', true
	}
	return 'a body that is neither A nor B (${body.len} bytes)', false
}

fn race_reader(c &RaceCase) RaceTally {
	request := 'GET /f.bin HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	mut out := []u8{cap: c.b.len + 1024}
	mut snaps := []u64{len: race_max_snaps}
	mut kept := 0
	mut overflow := 0
	mut seen_a := 0
	mut seen_b := 0
	mut bad := 0
	mut first := ''
	for stdatomic.load_u64(&c.stop) == 0 {
		// What a request is served from (decide() calls current() the same way).
		// A reader's snapshots only move forward along the chain, so a repeat of
		// the last one is not recorded again.
		p := u64(voidptr(c.rep.current()))
		if kept == 0 || snaps[kept - 1] != p {
			if kept < snaps.len {
				snaps[kept] = p
				kept++
			} else {
				overflow++
			}
		}
		out.clear()
		c.s.respond_into(request, mut out) or { panic(err) }
		why, is_b := race_check(c, out)
		if why != '' {
			if bad == 0 {
				first = why
			}
			bad++
		} else if is_b {
			seen_b++
		} else {
			seen_a++
		}
	}
	snaps.trim(kept)
	return RaceTally{
		seen_a:   seen_a
		seen_b:   seen_b
		bad:      bad
		first:    first
		snaps:    snaps
		overflow: overflow
	}
}

fn run_race(tag string, memory_fallback bool, revalidate_ms int) {
	dir := os.join_path(os.temp_dir(), 'vanilla_sa_race_${tag}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	a := race_pattern(3000, 1)
	b := race_pattern(3 * race_threshold, 2)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := new(Config{
		root:               dir
		follow_disk:        true
		revalidate_ms:      revalidate_ms
		sendfile_min_bytes: race_threshold
		memory_fallback:    memory_fallback
	}) or { panic(err) }
	mut c := &RaceCase{
		s:      &s
		rep:    s.assets['f.bin'] or { panic('no asset') }.reps[slot_identity]
		a:      a
		b:      b
		etag_a: content_etag(a)
		etag_b: if memory_fallback { content_etag(b) } else { '' }
	}
	assert s.etag_for('f.bin') or { panic(err) } == c.etag_a

	mut readers := []thread RaceTally{}
	for _ in 0 .. race_readers {
		readers << spawn race_reader(c)
	}
	for i in 0 .. race_swaps {
		race_replace(dir, if i % 2 == 0 { b } else { a })
		time.sleep(200 * time.microsecond) // let the readers see each version
	}
	stdatomic.store_u64(&c.stop, 1)
	tallies := readers.wait()

	mut seen_a := 0
	mut seen_b := 0
	for t in tallies {
		assert t.bad == 0, '${t.bad} bad responses, first: ${t.first}'
		assert t.overflow == 0, '${t.overflow} snapshots past ${race_max_snaps} in one reader'
		seen_a += t.seen_a
		seen_b += t.seen_b
	}
	// Both versions were actually served while the file changed under them.
	assert seen_a > 0 && seen_b > 0

	// The last swap restored A (past the window, so the next request checks).
	if revalidate_ms > 0 {
		time.sleep(20 * time.millisecond)
	}
	mut out := []u8{}
	s.respond_into('GET /f.bin HTTP/1.1\r\n\r\n'.bytes(), mut out) or { panic(err) }
	why, is_b := race_check(c, out)
	assert why == '' && !is_b
	// Every published snapshot is retained (prev), never more than one per
	// change of the file, and every snapshot a reader was served is one of them.
	mut chain := map[u64]bool{}
	mut p := c.rep.snap()
	for !isnil(p) {
		chain[u64(voidptr(p))] = true
		p = p.prev
	}
	assert chain.len >= 2 && chain.len <= race_swaps + 1
	mut served := 0
	mut orphans := 0
	for t in tallies {
		for q in t.snaps {
			served++
			if q !in chain {
				orphans++
			}
		}
	}
	assert served > 0
	assert orphans == 0, '${orphans} of ${served} snapshots served are not on the cur/prev chain'
}

fn test_follow_disk_under_contention_memory_fallback() {
	$if windows {
		return // no follow_disk on Windows
	}
	run_race('mem', true, 0)
}

fn test_follow_disk_under_contention_disk_backed() {
	$if windows {
		return // no follow_disk on Windows
	}
	run_race('disk', false, 0)
}

fn test_follow_disk_under_contention_window_memory_fallback() {
	$if windows {
		return // no follow_disk on Windows
	}
	run_race('win_mem', true, 1)
}

fn test_follow_disk_under_contention_window_disk_backed() {
	$if windows {
		return // no follow_disk on Windows
	}
	run_race('win_disk', false, 1)
}
