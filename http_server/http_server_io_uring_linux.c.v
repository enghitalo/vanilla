module http_server

import io_uring
import http1_1.response

#include <errno.h>

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int

pub fn run_io_uring_backend(request_handler fn ([]u8, int) ![]u8, port int, mut threads []thread) {
	num_workers := max_thread_pool_size

	for i in 0 .. num_workers {
		mut worker := &io_uring.Worker{}
		worker.cpu_id = i
		worker.listen_fd = -1
		io_uring.pool_init(mut worker)

		// Try to initialize io_uring ring with SQPOLL, fall back if it fails
		mut params := C.io_uring_params{}
		params.flags |= 1 << 3 // IORING_SETUP_SQPOLL
		params.sq_thread_cpu = i // Pin SQ thread to worker CPU
		mut sqpoll_failed := false
		if C.io_uring_queue_init_params(u32(io_uring.default_ring_entries), &worker.ring,
			&params) < 0 {
			eprintln('[io_uring] worker ${i}: SQPOLL failed, falling back to normal io_uring')
			// Try again without SQPOLL
			params = C.io_uring_params{}
			if C.io_uring_queue_init_params(u32(io_uring.default_ring_entries), &worker.ring,
				&params) < 0 {
				eprintln('Failed to initialize io_uring for worker ${i}')
				exit(1)
			}
			sqpoll_failed = true
		}
		// Use single-shot accept for SO_REUSEPORT
		//    worker.use_multishot = false
		if sqpoll_failed {
			eprintln('[io_uring] worker ${i}: single-shot accept enabled (no SQPOLL)')
		} else {
			eprintln('[io_uring] worker ${i}: single-shot accept + SQPOLL enabled')
		}

		// Create per-worker listener
		worker.listen_fd = io_uring.create_listener(port)
		if worker.listen_fd < 0 {
			eprintln('Failed to create listener for worker ${i}')
			exit(1)
		}
		// Spawn worker thread
		threads[i] = spawn io_uring_worker_loop(worker, request_handler)
	}

	println('listening on http://localhost:${port}/ (io_uring)')

	// Keep main thread alive
	for {
		C.sleep(1)
	}
}

// --- io_uring CQE Handlers ---
fn handle_io_uring_accept(worker &io_uring.Worker, cqe &C.io_uring_cqe) {
	res := cqe.res
	if res >= 0 {
		fd := res
		$if verbose ? {
			eprintln('[DEBUG] Accept: new fd=${fd}')
		}
		io_uring.tune_socket(fd)
		mut nc := io_uring.pool_acquire_from_ptr(worker, fd)
		if unsafe { nc != nil } {
			io_uring.prepare_recv(&worker.ring, mut *nc)
		} else {
			C.close(fd)
		}
	}
	// Re-arm accept if needed
	if (cqe.flags & u32(1 << 1)) == 0 || res < 0 {
		$if verbose ? {
			eprintln('[DEBUG] Re-arming accept (end of multishot or error)')
		}
		io_uring.prepare_accept(&worker.ring, worker.listen_fd, worker.use_multishot)
	}
}

fn handle_io_uring_read(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn ([]u8, int) ![]u8) {
	res := cqe.res
	c_ptr := io_uring.decode_connection_ptr(C.io_uring_cqe_get_data64(cqe))
	if res <= 0 {
		$if verbose ? {
			eprintln('[DEBUG] Read EOF/error: ${res}')
		}
		if unsafe { c_ptr != nil } {
			mut conn := unsafe { &io_uring.Connection(c_ptr) }
			io_uring.pool_release_from_ptr(worker, mut *conn)
		}
	} else if unsafe { c_ptr != nil } {
		mut conn := unsafe { &io_uring.Connection(c_ptr) }
		conn.bytes_read = res
		$if verbose ? {
			eprintln('[DEBUG] Read ${res} bytes from fd=${conn.fd}')
		}
		request_data := unsafe { conn.buf[..conn.bytes_read] }
		response_data := handler(request_data, conn.fd) or {
			response.send_bad_request_response(conn.fd)
			io_uring.pool_release_from_ptr(worker, mut *conn)
			C.io_uring_cqe_seen(&worker.ring, cqe)
			C.io_uring_submit(&worker.ring)
			return
		}
		conn.response_buffer = response_data
		conn.bytes_sent = 0
		$if verbose ? {
			eprintln('[DEBUG] Preparing write of ${conn.response_buffer.len} bytes')
		}
		io_uring.prepare_send(&worker.ring, mut *conn, conn.response_buffer.data, usize(conn.response_buffer.len))
	}
}

fn handle_io_uring_write(worker &io_uring.Worker, cqe &C.io_uring_cqe) {
	res := cqe.res
	c_ptr := io_uring.decode_connection_ptr(C.io_uring_cqe_get_data64(cqe))
	if res >= 0 {
		$if verbose ? {
			eprintln('[DEBUG] Wrote ${res} bytes')
		}
		if unsafe { c_ptr != nil } {
			mut conn := unsafe { &io_uring.Connection(c_ptr) }
			conn.bytes_sent += res
			if conn.bytes_sent < conn.response_buffer.len {
				remaining := conn.response_buffer.len - conn.bytes_sent
				io_uring.prepare_send(&worker.ring, mut *conn, unsafe {
					&u8(u64(conn.response_buffer.data) + u64(conn.bytes_sent))
				}, usize(remaining))
			} else {
				$if verbose ? {
					eprintln('[DEBUG] Write complete, keep-alive next read')
				}
				conn.bytes_read = 0
				unsafe { conn.response_buffer.free() }
				conn.response_buffer = []u8{}
				io_uring.prepare_recv(&worker.ring, mut *conn)
			}
		}
	} else {
		$if verbose ? {
			eprintln('[DEBUG] Write error: ${res}')
		}
		if unsafe { c_ptr != nil } {
			mut conn := unsafe { &io_uring.Connection(c_ptr) }
			io_uring.pool_release_from_ptr(worker, mut *conn)
		}
	}
}

fn dispatch_io_uring_cqe(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn ([]u8, int) ![]u8) {
	data := C.io_uring_cqe_get_data64(cqe)
	op := io_uring.decode_op_type(data)
	match op {
		io_uring.op_accept { handle_io_uring_accept(worker, cqe) }
		io_uring.op_read { handle_io_uring_read(worker, cqe, handler) }
		io_uring.op_write { handle_io_uring_write(worker, cqe) }
		else {}
	}
}

fn io_uring_worker_loop(worker &io_uring.Worker, handler fn ([]u8, int) ![]u8) {
	io_uring.prepare_accept(&worker.ring, worker.listen_fd, worker.use_multishot)
	C.io_uring_submit(&worker.ring)
	$if verbose ? {
		eprintln('[DEBUG] Worker started, listening on fd=${worker.listen_fd}')
	}

	for {
		$if verbose ? {
			eprintln('[DEBUG] Waiting for CQE...')
		}
		mut cqe := &C.io_uring_cqe(unsafe { nil })
		ret := C.io_uring_wait_cqe(&worker.ring, &cqe)
		if ret == -C.EINTR {
			continue
		}
		if ret < 0 {
			$if verbose ? {
				eprintln('[DEBUG] wait_cqe error: ${ret}')
			}
			break
		}
		dispatch_io_uring_cqe(worker, cqe, handler)
		C.io_uring_cqe_seen(&worker.ring, cqe)
		submitted := C.io_uring_submit(&worker.ring)
		$if verbose ? {
			eprintln('[DEBUG] Submitted ${submitted} SQE(s)\n')
		}
	}

	mut pending := 0
	for {
		mut cqe := &C.io_uring_cqe(unsafe { nil })
		for C.io_uring_peek_cqe(&worker.ring, &cqe) == 0 {
			dispatch_io_uring_cqe(worker, cqe, handler)
			pending++
			C.io_uring_cqe_seen(&worker.ring, cqe)
		}
		if pending > 0 {
			submitted := C.io_uring_submit(&worker.ring)
			$if verbose ? {
				eprintln('[DEBUG] Submitted ${submitted} SQE(s)')
			}
			pending = 0
		}
	}
}
