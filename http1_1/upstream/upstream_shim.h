// upstream_shim.h — the socket calls the pooled HTTP/1.1 client makes that
// need platform constants or structs, as static inline helpers. In C so V
// binds no `struct msghdr` / `struct iovec` of its own. The resolver's calls
// (getaddrinfo, its pipes) moved with it to transport/transport_shim.h.
#ifndef VANILLA_UPSTREAM_SHIM_H
#define VANILLA_UPSTREAM_SHIM_H

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>

#if defined(__linux__)
// A GNU extension (glibc and musl have it): declared here, as <unistd.h> may
// already be in without _GNU_SOURCE.
extern int dup3(int oldfd, int newfd, int flags);
#endif

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 // macOS: transport.dial_addr sets SO_NOSIGPIPE instead
#endif

// upstream_dup_onto makes the fd number `onto` refer to the socket `fd`
// (close-on-exec), then closes `fd`: a re-dial that keeps a pooled slot's fd
// number, so a watch the runtime holds on that number never has to be moved
// (a retry from a continuation whose client left may only re-arm the same
// fd). The old socket at `onto` is closed by the dup. `onto`, or -errno (then
// `onto` still holds the old socket).
static inline int upstream_dup_onto(int fd, int onto) {
	int r;
#if defined(__linux__)
	do {
		r = dup3(fd, onto, O_CLOEXEC);
	} while (r < 0 && (errno == EINTR || errno == EBUSY));
#else
	do {
		r = dup2(fd, onto);
	} while (r < 0 && errno == EINTR);
	if (r >= 0) fcntl(onto, F_SETFD, FD_CLOEXEC);
#endif
	int e = errno;
	close(fd);
	return r < 0 ? -e : onto;
}

// upstream_send writes p1[0..n1) then p2[0..n2) with one writev-style call
// (no SIGPIPE): the byte count, or -errno (-EAGAIN when the socket is full).
static inline long upstream_send(int fd, const void *p1, size_t n1, const void *p2, size_t n2) {
	struct iovec iov[2];
	struct msghdr m;
	memset(&m, 0, sizeof(m));
	iov[0].iov_base = (void *)p1;
	iov[0].iov_len = n1;
	iov[1].iov_base = (void *)p2;
	iov[1].iov_len = n2;
	m.msg_iov = n1 > 0 ? iov : iov + 1;
	m.msg_iovlen = (n1 > 0 && n2 > 0) ? 2 : 1;
	long r;
	do {
		r = (long)sendmsg(fd, &m, MSG_NOSIGNAL);
	} while (r < 0 && errno == EINTR);
	return r < 0 ? -(long)errno : r;
}

// upstream_recv reads up to n bytes: the count, 0 at EOF, or -errno (-EAGAIN
// when nothing is there yet).
static inline long upstream_recv(int fd, void *p, size_t n) {
	long r;
	do {
		r = (long)recv(fd, p, n, 0);
	} while (r < 0 && errno == EINTR);
	return r < 0 ? -(long)errno : r;
}

// upstream_peek looks at fd without consuming anything: 1 when bytes are
// waiting, 0 at EOF, -1 when nothing is there yet, -2 on an error (a reset).
static inline int upstream_peek(int fd) {
	char b;
	long r;
	do {
		r = (long)recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT);
	} while (r < 0 && errno == EINTR);
	if (r > 0) return 1;
	if (r == 0) return 0;
	return (errno == EAGAIN || errno == EWOULDBLOCK) ? -1 : -2;
}

#endif
