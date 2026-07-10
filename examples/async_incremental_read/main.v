module main

// Async-runtime example: incremental read from a slow fd, forwarded as it
// arrives. A child process produces a few lines with pauses; we wrap its pipe,
// watch it readable, and each time bytes show up we forward them as one HTTP
// chunk and re-arm — never blocking the worker while the producer sleeps. This
// is the reverse-proxy / `tail -f` shape: read what's available, stream it, wait
// for more.
//
// Run:   v run examples/async_incremental_read/
// Try:   curl -N http://localhost:8093/stream
//        # -> "line 1" ... "line 5", each ~200ms apart, chunk-encoded
//
// epoll only watches pollable fds (pipes/sockets), NOT regular files — a file
// reads as "always ready", so streaming one needs no async at all. The pipe here
// is the realistic case: the bytes genuinely arrive over time.
import http_server
import http_server.core

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

fn C.popen(command &char, mode &char) voidptr
fn C.pclose(stream voidptr) int
fn C.fileno(stream voidptr) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.read(fd int, buf voidptr, count usize) int

const chunk_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn handle(req []u8, mut out []u8, mut ctx core.Ctx) core.Step {
	if !req.bytestr().contains('/stream') {
		out << not_found
		return .done
	}
	// A producer whose output is spread over time — the whole point of streaming.
	fp := C.popen(c'for i in 1 2 3 4 5; do echo "line $i"; sleep 0.2; done', c'r')
	if fp == unsafe { nil } {
		out << not_found
		return .done
	}
	fd := C.fileno(fp)
	C.fcntl(fd, C.F_SETFL, C.O_NONBLOCK) // so read() returns EAGAIN instead of blocking
	out << chunk_headers // flushed after the initial .suspend
	ctx.watch(fd, .readable, on_chunk, fp) // carry FILE* so we can pclose at EOF
	return .suspend
}

// on_chunk runs whenever the pipe has bytes (or hit EOF): forward what is there
// as one chunk and re-arm. Each chunk flushes on .suspend, so the client sees
// output as the producer emits it.
fn on_chunk(mut out []u8, mut ctx core.Ctx) core.Step {
	mut buf := [4096]u8{}
	n := C.read(ctx.ready_fd(), &buf[0], 4096)
	if n > 0 {
		// HTTP chunk = <hex length>\r\n<bytes>\r\n
		out << '${n.hex()}\r\n'.bytes()
		out << buf[..n]
		out << '\r\n'.bytes()
		ctx.watch(ctx.ready_fd(), .readable, on_chunk, ctx.udata)
		return .suspend
	}
	if n == 0 {
		out << '0\r\n\r\n'.bytes() // terminating chunk
		C.pclose(ctx.udata)
		return .done
	}
	// n < 0: nothing ready yet (EAGAIN) → wait for the next readable edge.
	if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
		ctx.watch(ctx.ready_fd(), .readable, on_chunk, ctx.udata)
		return .suspend
	}
	C.pclose(ctx.udata) // a real read error → drop the connection
	return .close
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8093
		io_multiplexing: .epoll
		handler:         handle
	})!
	server.run()
}
