#ifndef VANILLA_EPOLL_SHIM_H
#define VANILLA_EPOLL_SHIM_H

#include <sys/epoll.h>

/*
 * `struct epoll_event` carries a `union epoll_data data`. Accessing that union
 * from V makes the Boehm GC emit a keepalive routine that mislabels the union
 * as a `struct` ("wrong kind of tag"), which breaks `-prod` builds. We keep all
 * union access in C via these inline helpers, so V never models the union.
 */
static inline int v_epoll_event_get_fd(struct epoll_event *ev) {
	return ev->data.fd;
}

static inline void v_epoll_event_set_fd(struct epoll_event *ev, int fd) {
	ev->data.fd = fd;
}

#endif /* VANILLA_EPOLL_SHIM_H */
