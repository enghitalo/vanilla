module core

// The userspace twin of a queued file region (sendfile_slot.c.v): the same
// bytes sendfile(2) would send, read into a buffer instead. POSIX only, since
// it is pread(2). Shared by every worker that has to materialise a region and
// by handlers whose backend refused queue_file, so there is one copy of it.

#include <unistd.h>

// pread(2) reads at an explicit offset and leaves the fd's own position alone,
// so one shared fd is safe to read from many threads at once (the property
// sendfile(2) with an explicit offset has too).
fn C.pread(fd int, buf voidptr, count usize, offset i64) isize

// append_file_region appends the bytes [off, off+length) of a borrowed file fd
// to `buf` and returns how many it appended. It reads straight into `buf`'s
// spare capacity, grown in place, so a reused buffer (a connection's write
// buffer) costs no allocation once it reaches its high-water mark.
//
// A short read (the file shrank under the caller, or a read error) truncates
// `buf` to the bytes actually read, and the result is then < length: a caller
// that already promised `length` bytes (a Content-Length on the wire) must
// zero-fill the rest or close. length <= 0, or a region that would take `buf`
// past max_int bytes, appends nothing and returns 0. The fd is never closed.
//
// Workers use it to emit a queued region as bytes when they cannot sendfile it
// (a pipelined response must follow it in order, or the connection is
// closing); handlers use it when queue_file returns false.
@[manualfree]
pub fn append_file_region(mut buf []u8, file_fd int, off i64, length i64) i64 {
	if length <= 0 || length > i64(max_int) - i64(buf.len) {
		return 0
	}
	start := buf.len
	unsafe { buf.grow_len(int(length)) }
	mut got := i64(0)
	for got < length {
		n := C.pread(file_fd, unsafe { &u8(buf.data) + start + int(got) }, usize(length - got),
			off + got)
		if n <= 0 {
			break // EOF (the file shrank) or a read error: keep what was read
		}
		got += i64(n)
	}
	if got < length {
		unsafe {
			buf.len = start + int(got)
		}
	}
	return got
}
