// pg_async_shim.h — the few socket calls pg_async's dialer makes beyond
// transport.dial_addr, as static inline helpers. In C because they need
// platform constants and structs (pollfd, keepalive option names,
// itimerspec) that V would otherwise bind program-wide: vtest already binds
// `struct pollfd`, and two modules must not bind the same C tag (see
// testkit_shim.h).
#ifndef VANILLA_PG_ASYNC_SHIM_H
#define VANILLA_PG_ASYNC_SHIM_H

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/timerfd.h>
#endif

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

// pg_async_tune sets the connection's TCP options (0 leaves one at the OS
// default): TCP_NODELAY, keepalive (idle seconds, probe interval, probe count)
// and TCP_USER_TIMEOUT (Linux; how long sent data may stay unacknowledged
// before the kernel drops the connection). Best effort: an option the
// platform lacks is skipped.
static inline void pg_async_tune(int fd, int nodelay, int ka_idle, int ka_intvl, int ka_cnt, int user_timeout_ms) {
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

// pg_async_gai_strerror is getaddrinfo's reason for a non-zero result.
static inline char *pg_async_gai_strerror(int rc) {
	return (char *)gai_strerror(rc);
}

// pg_async_getsockopt_int reads an int socket option (tests check the tuning).
static inline int pg_async_getsockopt_int(int fd, int level, int name) {
	int v = -1;
	socklen_t len = sizeof(v);
	if (getsockopt(fd, level, name, &v, &len) != 0) return -1;
	return v;
}

#ifdef __linux__
// pg_async_timer_new is a non-blocking, close-on-exec CLOCK_MONOTONIC timerfd.
static inline int pg_async_timer_new(void) {
	return timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
}

// pg_async_timer_arm arms a one-shot expiry `ms` milliseconds from now.
static inline int pg_async_timer_arm(int fd, int ms) {
	struct itimerspec its;
	memset(&its, 0, sizeof(its));
	if (ms < 1) ms = 1;
	its.it_value.tv_sec = ms / 1000;
	its.it_value.tv_nsec = (long)(ms % 1000) * 1000000L;
	return timerfd_settime(fd, 0, &its, NULL);
}
#endif

#endif
