// transport_shim.h — module-local typedef aliases for the sockaddr shapes
// transport/ dials with. The socket/ module already declares V bindings for
// `struct sockaddr_in`/`sockaddr_un` under their real C names; aliasing here
// keeps transport/ free of any vanilla import (dependency rule,
// docs/ARCHITECTURE.md) without redeclaring the same C type name twice.
#ifndef VANILLA_TRANSPORT_SHIM_H
#define VANILLA_TRANSPORT_SHIM_H

#ifdef _WIN32
#include <winsock2.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
#else
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/un.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
typedef struct sockaddr_un transport_sockaddr_un;

// transport_tune sets a TCP socket's options (0 leaves one at the OS
// default): TCP_NODELAY, keepalive (idle seconds, probe interval, probe count)
// and TCP_USER_TIMEOUT (Linux: how long sent data may stay unacknowledged
// before the kernel drops the connection). Best effort: an option the
// platform lacks is skipped.
static inline void transport_tune(int fd, int nodelay, int ka_idle, int ka_intvl, int ka_cnt, int user_timeout_ms) {
	int one = 1;
	if (nodelay) setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	if (ka_idle > 0) {
		setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
#if defined(TCP_KEEPIDLE)
		setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &ka_idle, sizeof(ka_idle));
#elif defined(TCP_KEEPALIVE)
		setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &ka_idle, sizeof(ka_idle));
#endif
#if defined(TCP_KEEPINTVL)
		if (ka_intvl > 0) setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &ka_intvl, sizeof(ka_intvl));
#endif
#if defined(TCP_KEEPCNT)
		if (ka_cnt > 0) setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &ka_cnt, sizeof(ka_cnt));
#endif
	}
#if defined(TCP_USER_TIMEOUT)
	if (user_timeout_ms > 0) {
		unsigned int t = (unsigned int)user_timeout_ms;
		setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &t, sizeof(t));
	}
#else
	(void)user_timeout_ms;
#endif
}

// transport_dial starts a non-blocking connect to the sockaddr `sa` (`len`
// bytes, address family `family`) on a new close-on-exec stream socket, tuned
// with transport_tune when it is TCP: the fd (the connect possibly still in
// flight), or -errno. No allocation, no message: a failed dial on a request
// path costs nothing.
static inline int transport_dial(int family, const void *sa, unsigned int len, int nodelay, int ka_idle, int ka_intvl, int ka_cnt, int user_timeout_ms) {
	int fd;
#if defined(SOCK_NONBLOCK) && defined(SOCK_CLOEXEC)
	fd = socket(family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (fd < 0) return -errno;
#else
	fd = socket(family, SOCK_STREAM, 0);
	if (fd < 0) return -errno;
	int fl = fcntl(fd, F_GETFL, 0);
	if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
		int e = errno;
		close(fd);
		return -e;
	}
#endif
#if defined(SO_NOSIGPIPE)
	{
		// No MSG_NOSIGNAL on macOS: a send to a closed peer must not kill the process.
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	}
#endif
	if (family == AF_INET || family == AF_INET6) {
		transport_tune(fd, nodelay, ka_idle, ka_intvl, ka_cnt, user_timeout_ms);
	}
	if (connect(fd, (const struct sockaddr *)sa, (socklen_t)len) != 0 && errno != EINPROGRESS) {
		int e = errno;
		close(fd);
		return -e;
	}
	return fd;
}

// transport_ip_addr parses the IPv4 or IPv6 literal `ip` (NUL-terminated, no
// brackets) into a sockaddr for `port` in `out` (at least sizeof(struct
// sockaddr_in6) bytes, zeroed here): its length, or 0 if `ip` is neither.
static inline unsigned int transport_ip_addr(const char *ip, int port, void *out, int *family) {
	struct sockaddr_in *v4 = (struct sockaddr_in *)out;
	struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)out;
	memset(out, 0, sizeof(struct sockaddr_in6));
	if (inet_pton(AF_INET, ip, &v4->sin_addr) == 1) {
		v4->sin_family = AF_INET;
		v4->sin_port = htons((unsigned short)port);
		*family = AF_INET;
		return sizeof(struct sockaddr_in);
	}
	memset(out, 0, sizeof(struct sockaddr_in6));
	if (inet_pton(AF_INET6, ip, &v6->sin6_addr) == 1) {
		v6->sin6_family = AF_INET6;
		v6->sin6_port = htons((unsigned short)port);
		*family = AF_INET6;
		return sizeof(struct sockaddr_in6);
	}
	return 0;
}

// transport_socket_error reads SO_ERROR: 0 once a non-blocking connect has
// completed, else the errno it failed with (or errno if it cannot be read).
static inline int transport_socket_error(int fd) {
	int v = 0;
	socklen_t len = sizeof(v);
	if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &v, &len) != 0) return errno;
	return v;
}
#endif

#endif
