// http_server_windows.c.v
// Windows-specific HTTP server entry point or helpers

module http_server

pub fn run(mut server Server) {
	eprintln('Windows is not supported yet. Please, use WSL or Linux.')
	exit(1)
}
