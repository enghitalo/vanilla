// vtest build: !windows
// The modules that call poll(2) compile beside vlib's os (#391). V refuses a
// second `fn C.` declaration with another signature, and os declares C.poll
// with a size type that differs per V and per OS (platform-width on V master,
// u32 on BSDs and macOS); vanilla calls it as
// C.vanilla_poll (core/libc_shim.h), so the program builds on every V.
import os
import poll
import testkit
import vtest as _

fn test_poll_modules_build_beside_os() {
	assert os.getwd() != ''
	// A zero-fd, zero-timeout wait returns at once: 0 ready.
	assert poll.wait(unsafe { nil }, 0, 0) == 0
	// poll ignores a negative fd: nothing ready, so false.
	assert !testkit.fd_wait_writable(-1, 0)
}
