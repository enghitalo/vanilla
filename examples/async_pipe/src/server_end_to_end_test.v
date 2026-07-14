module main

import http_server

// Drives the async runtime end to end through the real backend (epoll on Linux,
// kqueue on macOS): a /async request parks on a pipe watch and is answered from
// the continuation. This is what validates the macOS kqueue async path in CI.
fn test_async_pipe_end_to_end() ! {
	req := 'GET /async HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8096
		handler:         handle
		io_multiplexing: unsafe { http_server.IOBackend(0) } // .epoll on Linux, .kqueue on macOS
	})!
	responses := server.test([req]) or { panic('[test] server.test failed: ${err}') }
	assert responses.len == 1
	assert responses[0].bytestr().contains('async-ok')
	println('[test] async pipe end-to-end passed!')
}
