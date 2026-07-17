module main

// CPU offload for the argon2 password verify (epoll/kqueue only — this file is
// excluded from Windows builds by the `_nix` suffix; see offload_windows.c.v for
// the stub that makes handle() fall back to a synchronous verify there).
//
// WHY: argon2id is ~200 ms and 64 MiB PER call, by design. Running it on the
// worker's event loop would block that worker for the whole span, stalling every
// other connection it holds (head-of-line blocking). Vanilla's answer is the same
// as for any slow dependency — park the connection and resume it from the reactor
// when the result is ready (see examples/async_pipe). Here the "result" is CPU
// work, so we hand it to a bounded pool of verifier threads and wake the worker
// over a pipe.
//
// SHAPE (per request):
//   handle() → try_offload(): clone the password OUT of the request buffer (the
//     zero-copy view dies at .suspend), make a pipe, queue {password, pipe_w} on
//     this worker's pool, watch the pipe read-end, return .suspend.
//   pool thread (hash_worker): run argon2, write a 1-byte verdict to pipe_w,
//     close pipe_w. It touches ONLY its own job — never the reactor, the
//     connection, or worker_state — so there is no cross-thread sharing to race.
//   token_done() (on the worker thread, when the pipe is readable): read the
//     verdict byte, close the read-end, append the 200+JWT or a 401.
//
// The pool is PER WORKER (built in make_state): shared-nothing, so verifier
// threads never contend across workers, and the resume always lands on the
// worker that parked the request (the pipe is registered in that worker's epoll).
import core

#include <unistd.h>

fn C.pipe(fds &int) int
fn C.write(fd int, buf voidptr, n usize) int
fn C.read(fd int, buf voidptr, n usize) int
fn C.close(fd int) int

// Bounds. hash_pool_size caps concurrent argon2 computations PER WORKER, so peak
// login memory is bounded at hash_pool_size × 64 MiB per worker instead of
// growing with the login rate. hash_queue_cap is the pending-login backlog before
// the server sheds load (503) rather than queue unboundedly.
const hash_pool_size = 2
const hash_queue_cap = 64

// HashJob carries one verify off the worker. `password` is an OWNED copy (the
// request-buffer view is invalid the moment handle() returns .suspend). `pipe_w`
// is the write-end the pool thread signals and then closes.
struct HashJob {
	password []u8
	pipe_w   int
}

// AuthState is the per-worker offload handle handed to every handler call as
// worker_state. One channel + hash_pool_size verifier threads, created once per
// worker in make_auth_state.
struct AuthState {
	jobs chan HashJob
}

// make_auth_state runs ONCE per worker (ServerConfig.make_state), on the worker
// thread. It starts this worker's private argon2 pool.
fn make_auth_state() voidptr {
	mut st := &AuthState{
		jobs: chan HashJob{cap: hash_queue_cap}
	}
	for _ in 0 .. hash_pool_size {
		spawn hash_worker(st.jobs)
	}
	return voidptr(st)
}

// hash_worker is a pool thread: it runs the CPU-heavy, memory-hard argon2 verify
// OFF the event loop, then writes a 1-byte verdict (1 = match, 0 = mismatch) to
// the request's pipe so the worker's reactor resumes the parked connection.
fn hash_worker(jobs chan HashJob) {
	for {
		job := <-jobs or { break } // channel closed on shutdown → thread exits
		mut verdict := u8(0)
		if verify_password(job.password, demo_password_phc) {
			verdict = 1
		}
		// The client may have disconnected mid-hash; the runtime then closed the
		// read-end, so this write can fail with EPIPE — ignore it, just release
		// the write-end. The pool thread owns pipe_w; the request owns pipe_r.
		C.write(job.pipe_w, &verdict, 1)
		C.close(job.pipe_w)
	}
}

// try_offload queues the verify and parks the connection. Returns false when the
// offload could not be set up (pipe failure, or the pool queue is full) — the
// caller then sheds the request with 503 instead of blocking the worker.
fn try_offload(worker_state voidptr, password []u8, mut event_loop core.EventLoop) bool {
	mut st := unsafe { &AuthState(worker_state) }
	mut fds := [2]int{}
	if C.pipe(unsafe { &fds[0] }) != 0 {
		return false
	}
	// password.clone(): copy out of the request buffer before it is recycled at
	// .suspend. This is the slow path, so the copy is free relative to argon2.
	job := HashJob{
		password: password.clone()
		pipe_w:   fds[1]
	}
	mut queued := false
	select {
		st.jobs <- job {
			queued = true
		}
		else {}
	}
	if !queued {
		C.close(fds[0])
		C.close(fds[1])
		return false
	}
	// Watch the read-end; token_done fires on the worker thread when the pool
	// signals. Non-persistent: the runtime closes this fd if the client
	// disconnects while parked.
	event_loop.watch_fd(fds[0], .readable, token_done, unsafe { nil })
	return true
}

// token_done resumes a parked /token request when its verify completes. Runs on
// the worker thread (never a pool thread); appends the same bytes the
// synchronous path would.
fn token_done(mut out []u8, ready_fd int, _ready_fd_error bool, _watch_payload voidptr, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	mut verdict := u8(0)
	// Read the data byte even on HUP: the pool writes the verdict and THEN closes
	// pipe_w, so a readable+hung-up read-end still carries the verdict first.
	nread := C.read(ready_fd, &verdict, 1)
	C.close(ready_fd) // the request owns the read-end
	if nread != 1 || verdict != 1 {
		out << resp_401
		return .done
	}
	write_token_200(mut out)
	return .done
}
