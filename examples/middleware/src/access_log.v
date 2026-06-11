module main

// Access logging — the most efficient shape that stays correct under the
// thread-per-core worker model (the handler closure runs concurrently on every
// worker; it gets only the request bytes + fd, no worker id, so any shared log
// must be safe without per-worker state).
//
// Why this is fast, in order of impact over the naive `println` + full-decode:
//
//   • NO syscall per request. The log is a buffered C stream opened in append
//     mode; fwrite accumulates in glibc's ~8 KB buffer and flushes in batches,
//     so hundreds of requests share a single write(2).
//   • NO full parse. "METHOD PATH" is the contiguous prefix of the request line
//     (up to the 2nd space) — found with one memchr. Headers are never scanned.
//   • NO heap allocation. The line is assembled in a stack buffer and written in
//     ONE fwrite. glibc holds the stream lock for that single call, so the line
//     is atomic across the concurrent workers (no interleaving) without us
//     adding any userspace mutex.
//
// The remaining cost is glibc's per-fwrite stream lock; the truly lock-free step
// (per-worker buffers via thread-local storage, flushed independently) is noted
// in the README as the next optimization — it needs a thread-local slot, which
// this server doesn't expose to the handler.

// Buffered, thread-safe (glibc locks the stream), append-mode C stdio.
fn C.fopen(path &char, mode &char) voidptr
fn C.fwrite(ptr voidptr, size usize, nmemb usize, stream voidptr) usize
fn C.fflush(stream voidptr) int
fn C.memchr(buf voidptr, c int, n usize) voidptr

struct AccessLog {
	cfile voidptr // C FILE*, opened "ab" (append + fully buffered)
}

// new_access_log opens (or creates) the log file in append mode. Shared by all
// workers — pass the returned pointer to access_log_mw.
fn new_access_log(path string) !&AccessLog {
	cfile := C.fopen(&char(path.str), c'ab')
	if cfile == unsafe { nil } {
		return error('access log: cannot open ${path}')
	}
	return &AccessLog{
		cfile: cfile
	}
}

// access_log_mw returns a Middleware that logs one line per request. The log is
// captured by pointer and shared across all workers.
fn access_log_mw(log &AccessLog) Middleware {
	return fn [log] (next Handler) Handler {
		return fn [log, next] (req_buffer []u8, fd int) ![]u8 {
			resp := next(req_buffer, fd)!
			log.record(req_buffer, resp)
			return resp
		}
	}
}

// record assembles "METHOD PATH STATUS\n" and writes it in a single fwrite.
// Zero heap allocation; no header parse. Silently skips a malformed request line
// or a pathologically long request-target (logging must never break a response).
fn (l &AccessLog) record(req_buffer []u8, resp []u8) {
	if req_buffer.len < 4 || resp.len < 12 {
		return
	}
	unsafe {
		// First space ends the method; the prefix up to the SECOND space is the
		// contiguous "METHOD SP PATH" we want to log.
		sp1 := C.memchr(&req_buffer[0], ` `, usize(req_buffer.len))
		if sp1 == nil {
			return
		}
		after_method := int(&u8(sp1) - &req_buffer[0]) + 1
		if after_method >= req_buffer.len {
			return
		}
		sp2 := C.memchr(&req_buffer[after_method], ` `, usize(req_buffer.len - after_method))
		if sp2 == nil {
			return
		}
		prefix_len := int(&u8(sp2) - &req_buffer[0]) // "METHOD SP PATH"

		// line = prefix + ' ' + 3-byte status code (resp[9..12]) + '\n'
		total := prefix_len + 1 + 3 + 1
		mut line := [512]u8{}
		if total > line.len {
			return
		}
		vmemcpy(&line[0], &req_buffer[0], prefix_len)
		mut n := prefix_len
		line[n] = ` `
		n++
		vmemcpy(&line[n], &resp[9], 3)
		n += 3
		line[n] = `\n`
		n++
		C.fwrite(&line[0], 1, usize(n), l.cfile)
	}
}

// flush drains glibc's buffer to disk. Call on shutdown, or the buffered tail is
// lost (the cost of batching).
fn (l &AccessLog) flush() {
	C.fflush(l.cfile)
}
