module main

// The log file. Every worker opens the same path with its own O_APPEND
// descriptor and writes whole lines, many per write(2): each write lands at
// the end of the file whatever the other workers write, so lines never
// interleave (nginx's access_log buffer= model). Nothing is shared but the
// path and one atomic generation: SIGHUP and a size rotation bump it, and a
// worker that sees it moved reopens before its next write.
import sync.stdatomic

#include <fcntl.h>
#include <sys/stat.h>

// write_file appends the buffer to the log file, reopening it first when
// SIGHUP or a rotation asked for it. A failed open or write drops the
// buffer's lines (counted): the next tick tries again.
fn (mut w Worker) write_file() {
	gen := stdatomic.load_i64(&w.sh.reopen_gen)
	if w.fd < 0 || gen != w.gen {
		w.reopen(gen)
	}
	if w.fd < 0 || !write_all(w.fd, w.buf) {
		w.counts.write_errors++
		w.counts.dropped += w.lines
		return
	}
	w.counts.written += w.buf.len
}

// reopen closes this worker's descriptor and opens the path again: after a
// rename (logrotate, or check_rotation) that is a new, empty file.
fn (mut w Worker) reopen(gen i64) {
	if w.fd >= 0 {
		C.close(w.fd)
		w.counts.reopens++
	}
	w.fd = C.open(&char(w.sh.path.str), C.O_WRONLY | C.O_CREAT | C.O_APPEND | C.O_CLOEXEC,
		0o644)
	w.gen = gen
}

// write_all writes all of b, retrying short writes and EINTR.
fn write_all(fd int, b []u8) bool {
	mut off := 0
	for off < b.len {
		n := C.write(fd, unsafe { &u8(b.data) + off }, usize(b.len - off))
		if n < 0 {
			if C.errno == C.EINTR {
				continue
			}
			return false
		}
		off += n
	}
	return true
}

// check_rotation runs on worker 0's tick, so one thread renames and no lock
// is needed: once the file reached max_bytes it shifts path.<keep-1> to
// path.<keep> … path to path.1 (the oldest is overwritten) and bumps
// reopen_gen, and every worker reopens a fresh path before its next write. A
// line another worker writes between the rename and its reopen lands at the
// end of path.1: late, never lost. The file can pass max_bytes by what the
// workers write in one tick.
fn (mut w Worker) check_rotation() {
	mut st := C.stat{}
	if unsafe { C.stat(&char(w.sh.path.str), &st) } != 0 || i64(st.st_size) < w.sh.max_bytes {
		return
	}
	for i := w.sh.rotated.len - 1; i > 0; i-- {
		C.rename(&char(w.sh.rotated[i - 1].str), &char(w.sh.rotated[i].str))
	}
	if C.rename(&char(w.sh.path.str), &char(w.sh.rotated[0].str)) != 0 {
		w.counts.write_errors++
		return
	}
	w.counts.rotations++
	stdatomic.add_i64(&w.sh.reopen_gen, 1)
}
