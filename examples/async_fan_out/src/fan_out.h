#ifndef VANILLA_FAN_OUT_H
#define VANILLA_FAN_OUT_H

#include <stdint.h>
#include <sys/epoll.h>

/*
 * The aggregator of examples/async_fan_out: one epoll instance per fan-out
 * request, its members the request's N operations. The member's index rides
 * in the event's data, so a wake finds which members finished without a
 * lookup. Kept in C so V never models `union epoll_data` (see
 * epoll/epoll_shim.h for why).
 */

/* fan_open creates an aggregator. Returns its fd, or -1 (errno). */
static inline int fan_open(void) {
	return epoll_create1(EPOLL_CLOEXEC);
}

/* fan_add registers member `fd` in `agg`, level-triggered for reading, with
 * its index in the event's data. Returns 0, or -1 (errno). */
static inline int fan_add(int agg, int fd, int idx) {
	struct epoll_event ev;
	ev.events = EPOLLIN;
	ev.data.u64 = 0;
	ev.data.u32 = (uint32_t)idx; /* the member read back, on any endianness */
	return epoll_ctl(agg, EPOLL_CTL_ADD, fd, &ev);
}

/* fan_ready collects the members of `agg` that are ready, without blocking:
 * their indices go to idx[0..n). max is at most 64. Returns n, 0 when none
 * is ready. */
static inline int fan_ready(int agg, int32_t *idx, int max) {
	struct epoll_event evs[64];
	if (max > 64) {
		max = 64;
	}
	int n = epoll_wait(agg, evs, max, 0);
	for (int i = 0; i < n; i++) {
		idx[i] = (int32_t)evs[i].data.u32;
	}
	return n < 0 ? 0 : n;
}

#endif /* VANILLA_FAN_OUT_H */
