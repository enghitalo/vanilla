// upstream_shim.h — the socket, pipe and resolver calls the pooled HTTP/1.1
// client makes that need platform constants or structs, as static inline
// helpers. In C so V binds no `struct addrinfo` / `struct pollfd` of its own
// (pg_async and vtest already bind those tags; two modules must not).
#ifndef VANILLA_UPSTREAM_SHIM_H
#define VANILLA_UPSTREAM_SHIM_H

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>

#if defined(__linux__)
// GNU extensions (glibc and musl have both): declared here, as <unistd.h> may
// already be in without _GNU_SOURCE.
extern int dup3(int oldfd, int newfd, int flags);
extern int pipe2(int pipefd[2], int flags);
#endif

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 // macOS: transport.dial_addr sets SO_NOSIGPIPE instead
#endif

// upstream_addr is one resolved address, as upstream_resolve copies it out.
typedef struct {
	int family;
	unsigned int len;
	unsigned char data[128];
} upstream_addr;

// upstream_resolve resolves host:port (getaddrinfo, TCP) into out[0..max): the
// count of IPv4 / IPv6 addresses, in getaddrinfo's order, or -1 with the
// getaddrinfo error in *gai_err. Blocking: call it at startup or on the
// resolver thread, never on a worker.
static inline int upstream_resolve(const char *host, const char *port, upstream_addr *out, int max, int *gai_err) {
	struct addrinfo hints, *res = NULL, *ai;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	int rc = getaddrinfo(host, port, &hints, &res);
	if (rc != 0) {
		*gai_err = rc;
		return -1;
	}
	int n = 0;
	for (ai = res; ai != NULL && n < max; ai = ai->ai_next) {
		if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) continue;
		if (ai->ai_addrlen == 0 || ai->ai_addrlen > sizeof(out[n].data)) continue;
		out[n].family = ai->ai_family;
		out[n].len = (unsigned int)ai->ai_addrlen;
		memcpy(out[n].data, ai->ai_addr, ai->ai_addrlen);
		n++;
	}
	freeaddrinfo(res);
	return n;
}

static inline const char *upstream_gai_strerror(int rc) {
	return gai_strerror(rc);
}

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

// upstream_pipe opens a non-blocking, close-on-exec pipe: 0, or -errno.
static inline int upstream_pipe(int *fds) {
#if defined(__linux__)
	return pipe2(fds, O_NONBLOCK | O_CLOEXEC) == 0 ? 0 : -errno;
#else
	if (pipe(fds) != 0) return -errno;
	for (int i = 0; i < 2; i++) {
		fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL, 0) | O_NONBLOCK);
		fcntl(fds[i], F_SETFD, FD_CLOEXEC);
	}
	return 0;
#endif
}

// upstream_block_sigpipe blocks SIGPIPE on the calling thread: a write to a
// pipe without a reader then fails with EPIPE instead of killing the process.
static inline void upstream_block_sigpipe(void) {
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGPIPE);
	pthread_sigmask(SIG_BLOCK, &set, NULL);
}

// upstream_wait polls one fd for readability up to timeout_ms: > 0 when
// readable, 0 on timeout, -1 on error.
static inline int upstream_wait(int fd, int timeout_ms) {
	struct pollfd p;
	p.fd = fd;
	p.events = POLLIN;
	p.revents = 0;
	int r;
	do {
		r = poll(&p, 1, timeout_ms);
	} while (r < 0 && errno == EINTR);
	return r;
}

#endif
