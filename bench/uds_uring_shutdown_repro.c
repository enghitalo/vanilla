/* uds_uring_shutdown_repro.c — kernel-behavior probe backing docs/LOCAL_IPC.md §5.
 *
 * Question: does shutdown(SHUT_RDWR) on a LISTENING socket produce a terminal
 * CQE for an armed io_uring multishot accept?
 *
 *   AF_INET listener:  yes — CQE res=-EINVAL, F_MORE=0, within milliseconds.
 *                      This is what Server.shutdown relies on today to stop
 *                      every worker ring's armed accept.
 *   AF_UNIX listener:  NO — shutdown() returns 0 and no CQE ever arrives; the
 *                      armed accept stays parked forever (epoll_wait on the
 *                      same shut-down listener DOES wake with EPOLLIN|EPOLLHUP,
 *                      so the gap is specific to io_uring's armed accept).
 *
 * Consequence: a UDS listener needs its own shutdown path — per-ring
 * io_uring_prep_cancel_fd(listener, IORING_ASYNC_CANCEL_FD|_ALL) issued from
 * each ring's own thread (SINGLE_ISSUER), or a dummy connect() per worker
 * after setting the draining flag. See docs/LOCAL_IPC.md §5 item 3.
 *
 * Observed on Linux 6.8.0-124 (liburing 2.x); plain rings and
 * SINGLE_ISSUER|DEFER_TASKRUN rings behave the same.
 *
 * Build: cc -O2 -o uds_uring_shutdown_repro uds_uring_shutdown_repro.c -luring
 * Run:   ./uds_uring_shutdown_repro [workdir]   (default workdir: /tmp)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <liburing.h>

static int lfd;

static void *ring_thread(void *arg) {
	(void)arg;
	struct io_uring ring;
	if (io_uring_queue_init(64, &ring, 0) < 0) { perror("ring"); exit(1); }
	struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
	io_uring_prep_multishot_accept(sqe, lfd, NULL, NULL, 0);
	io_uring_submit(&ring);
	printf("  [ring] armed, waiting up to 5s for a CQE after shutdown...\n");
	struct io_uring_cqe *cqe;
	struct __kernel_timespec ts = { .tv_sec = 5, .tv_nsec = 0 };
	int r = io_uring_wait_cqe_timeout(&ring, &cqe, &ts);
	if (r == -ETIME)
		printf("  [ring] NO CQE within 5s of shutdown -> accept NOT cancelled\n");
	else if (r == 0) {
		printf("  [ring] CQE arrived: res=%d (%s) F_MORE=%d -> accept %s\n",
		       cqe->res, cqe->res < 0 ? strerror(-cqe->res) : "fd",
		       !!(cqe->flags & IORING_CQE_F_MORE),
		       cqe->res < 0 ? "cancelled/terminated" : "completed with a connection?!");
		io_uring_cqe_seen(&ring, cqe);
	} else
		printf("  [ring] wait error: %s\n", strerror(-r));
	io_uring_queue_exit(&ring);
	return NULL;
}

static void run(const char *label, int family) {
	printf("== %s listener ==\n", label);
	if (family == AF_UNIX) {
		unlink("shut.sock");
		lfd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
		struct sockaddr_un a; memset(&a, 0, sizeof a);
		a.sun_family = AF_UNIX; strcpy(a.sun_path, "shut.sock");
		if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); exit(1); }
	} else {
		lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
		int one = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
		struct sockaddr_in a = {0};
		a.sin_family = AF_INET; a.sin_port = htons(39118);
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); exit(1); }
	}
	listen(lfd, 64);
	pthread_t t; pthread_create(&t, NULL, ring_thread, NULL);
	usleep(300 * 1000); /* let the ring arm before shooting */
	int r = shutdown(lfd, SHUT_RDWR);
	printf("  shutdown(SHUT_RDWR) -> ret=%d%s%s\n", r, r ? " errno=" : "",
	       r ? strerror(errno) : "");
	pthread_join(t, NULL);
	close(lfd);
	if (family == AF_UNIX) unlink("shut.sock");
}

int main(int argc, char **argv) {
	if (chdir(argc > 1 ? argv[1] : "/tmp") < 0) { perror("chdir"); return 1; }
	run("AF_INET (TCP loopback)", AF_INET);
	run("AF_UNIX", AF_UNIX);
	return 0;
}
