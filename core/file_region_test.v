module core

import os

// append_file_region (file_region_nix.c.v): what it appends, what it returns,
// and that a short or refused read leaves the buffer framed by what was read.
// POSIX only, like the function.

const fr_data = '0123456789abcdefghij'

fn fr_fixture(tag string) !string {
	path := os.join_path(os.temp_dir(), 'vanilla_core_file_region_${tag}_${os.getpid()}.txt')
	os.write_file(path, fr_data)!
	return path
}

fn test_append_file_region_reads_the_region_after_existing_bytes() ! {
	$if !windows {
		path := fr_fixture('full')!
		mut f := os.open(path)!
		defer {
			f.close()
			os.rm(path) or {}
		}
		mut buf := []u8{cap: 4}
		buf << 'HDR:'.bytes()
		n := append_file_region(mut buf, f.fd, 4, 6)
		assert n == 6
		assert buf.bytestr() == 'HDR:456789'
		// The fd's own position is untouched (pread): a read() starts at 0.
		mut first := []u8{len: 3}
		got := f.read(mut first)!
		assert got == 3
		assert first.bytestr() == '012'
	}
}

fn test_append_file_region_short_read_truncates_to_what_was_read() ! {
	$if !windows {
		path := fr_fixture('short')!
		mut f := os.open(path)!
		defer {
			f.close()
			os.rm(path) or {}
		}
		mut buf := 'HDR:'.bytes()
		// 15 bytes asked from offset 15 of a 20-byte file: 5 exist.
		n := append_file_region(mut buf, f.fd, 15, 15)
		assert n == 5
		assert buf.bytestr() == 'HDR:fghij'
		// Entirely past EOF: nothing appended.
		assert append_file_region(mut buf, f.fd, 100, 8) == 0
		assert buf.bytestr() == 'HDR:fghij'
	}
}

// Every refusal returns 0 and leaves the buffer's bytes as they were. Only the
// bytes: a bad fd fails after the buffer was grown for the read, so its
// capacity may have changed.
fn test_append_file_region_refusals_leave_the_bytes_unchanged() {
	$if !windows {
		mut buf := 'HDR:'.bytes()
		assert append_file_region(mut buf, -1, 0, 8) == 0 // EBADF
		assert append_file_region(mut buf, 0, 0, 0) == 0
		assert append_file_region(mut buf, 0, 0, -5) == 0
		// A region that would take the buffer past max_int bytes is refused
		// before anything is grown (it would not fit an array length).
		assert append_file_region(mut buf, 0, 0, i64(max_int)) == 0
		assert buf.bytestr() == 'HDR:'
		assert buf.cap < 1024
	}
}
