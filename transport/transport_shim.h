// transport_shim.h — module-local typedef aliases for the sockaddr shapes
// transport/ dials with, and the address-family-agnostic dial helpers. The
// socket/ module already declares V bindings for `struct sockaddr_in`/
// `sockaddr_un` under their real C names; aliasing here keeps transport/ free
// of any vanilla import (dependency rule, docs/ARCHITECTURE.md) without
// redeclaring the same C type name twice.
#ifndef VANILLA_TRANSPORT_SHIM_H
#define VANILLA_TRANSPORT_SHIM_H

#ifdef _WIN32
#include <winsock2.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
#else
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
typedef struct sockaddr_un transport_sockaddr_un;

// transport_dial_addr opens a stream socket of the sockaddr's own family,
// non-blocking and close-on-exec, and starts connect(). Returns the fd (the
// connect completed or is in flight, EINPROGRESS) or -errno.
static inline int transport_dial_addr(const void *addr, unsigned int len) {
	if (len < sizeof(sa_family_t)) return -EINVAL;
	int fd = socket(((const struct sockaddr *)addr)->sa_family, SOCK_STREAM, 0);
	if (fd < 0) return -errno;
	int fl = fcntl(fd, F_GETFL, 0);
	if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0
		|| (connect(fd, (const struct sockaddr *)addr, (socklen_t)len) < 0 && errno != EINPROGRESS)) {
		int e = errno;
		close(fd);
		return -e;
	}
	return fd;
}

// transport_connect_error is the outcome of a non-blocking connect once its
// socket is writable: 0 when it connected, else the errno (SO_ERROR).
static inline int transport_connect_error(int fd) {
	int err = 0;
	socklen_t len = sizeof(err);
	if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) return errno;
	return err;
}
#endif

#endif
