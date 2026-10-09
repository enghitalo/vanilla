// pg_async_shim.h — the socket calls pg_async's dialer makes that need
// platform constants or structs (pollfd), as static inline helpers; the
// connect itself and the TCP tuning are transport.dial_addr's. In C so V does
// not bind `struct pollfd` program-wide: vtest already binds it, and two
// modules must not bind the same C tag (see testkit_shim.h).
#ifndef VANILLA_PG_ASYNC_SHIM_H
#define VANILLA_PG_ASYNC_SHIM_H

#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// pg_async_wait polls one fd for `events` (POLLIN / POLLOUT) up to
// timeout_ms (0 = just look): the revents, 0 on timeout, -1 on error.
static inline int pg_async_wait(int fd, int events, int timeout_ms) {
	struct pollfd p;
	p.fd = fd;
	p.events = (short)events;
	p.revents = 0;
	int r;
	do {
		r = poll(&p, 1, timeout_ms);
	} while (r < 0 && errno == EINTR);
	return r <= 0 ? r : p.revents;
}

// pg_async_gai_strerror is getaddrinfo's reason for a non-zero result.
static inline char *pg_async_gai_strerror(int rc) {
	return (char *)gai_strerror(rc);
}

// pg_async_getsockopt_int reads an int socket option: SO_ERROR after a
// non-blocking connect, and the tuning in tests. -1 if it cannot be read.
static inline int pg_async_getsockopt_int(int fd, int level, int name) {
	int v = -1;
	socklen_t len = sizeof(v);
	if (getsockopt(fd, level, name, &v, &len) != 0) return -1;
	return v;
}

// pg_async_pending_bytes is how many received bytes the socket holds unread
// (FIONREAD): after the one-byte answer to SSLRequest there must be none.
// -1 if it cannot be read.
static inline int pg_async_pending_bytes(int fd) {
	int n = 0;
	if (ioctl(fd, FIONREAD, &n) != 0) return -1;
	return n;
}

#endif
