// probe.c: what this kernel's io_uring offers the vanilla backend.
//
//   gcc -o probe examples/io_uring_demo/probe.c -luring && ./probe
//
// (liburing 2.0 or newer.)
// 1. io_uring_setup works at all (not blocked by kernel.io_uring_disabled or a
//    seccomp policy);
// 2. IORING_OP_ACCEPT is in the probe's op table;
// 3. multishot accept works. The probe has no bit for it: IO_URING_OP_SUPPORTED
//    only says the accept opcode exists (since 5.5), not its multishot form
//    (5.19). So this connects to a loopback listener, then arms one multishot
//    accept on it and reads the completion: a kernel without it rejects the
//    request with -EINVAL, one with it accepts and keeps the request armed
//    (IORING_CQE_F_MORE). The backend itself decides by kernel release.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <liburing.h>

// Older liburing headers predate multishot accept; the values are kernel ABI.
#ifndef IORING_ACCEPT_MULTISHOT
#define IORING_ACCEPT_MULTISHOT (1U << 0)
#endif
#ifndef IORING_CQE_F_MORE
#define IORING_CQE_F_MORE (1U << 1)
#endif

// multishot_accept_works returns 1 if a multishot accept completes with a
// connection and stays armed, 0 if the kernel refuses it, -1 on a local error.
static int multishot_accept_works(struct io_uring *ring) {
    int works = -1;
    int cfd = -1;
    int ret;
    struct io_uring_sqe *sqe;
    struct io_uring_cqe *cqe;
    struct sockaddr_in addr;
    socklen_t len = sizeof addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0 || bind(lfd, (struct sockaddr *)&addr, sizeof addr) || listen(lfd, 8) ||
        getsockname(lfd, (struct sockaddr *)&addr, &len)) {
        perror("loopback listener");
        goto out;
    }
    // Connect first: the connection waits in the backlog, so the accept below
    // completes at once.
    cfd = socket(AF_INET, SOCK_STREAM, 0);
    if (cfd < 0 || connect(cfd, (struct sockaddr *)&addr, sizeof addr)) {
        perror("loopback connect");
        goto out;
    }
    // io_uring_prep_multishot_accept needs liburing 2.2: set the flag by hand.
    sqe = io_uring_get_sqe(ring);
    if (!sqe) {
        fputs("no free SQE\n", stderr);
        goto out;
    }
    io_uring_prep_rw(IORING_OP_ACCEPT, sqe, lfd, NULL, 0, 0);
    sqe->ioprio |= IORING_ACCEPT_MULTISHOT;
    ret = io_uring_submit(ring);
    if (ret != 1) {
        fprintf(stderr, "io_uring_submit: %s\n", ret < 0 ? strerror(-ret) : "nothing submitted");
        goto out;
    }
    ret = io_uring_wait_cqe(ring, &cqe);
    if (ret < 0) {
        fprintf(stderr, "io_uring_wait_cqe: %s\n", strerror(-ret));
        goto out;
    }
    if (cqe->res >= 0) {
        works = (cqe->flags & IORING_CQE_F_MORE) ? 1 : 0;
        close(cqe->res);
    } else if (cqe->res == -EINVAL) {
        works = 0;
    } else {
        fprintf(stderr, "multishot accept: %s\n", strerror(-cqe->res));
    }
    io_uring_cqe_seen(ring, cqe);
out:
    if (cfd >= 0)
        close(cfd);
    if (lfd >= 0)
        close(lfd);
    return works;
}

int main(void) {
    struct io_uring ring;
    int ret = io_uring_queue_init(8, &ring, 0);
    if (ret < 0) {
        fprintf(stderr, "io_uring_setup: %s (disabled, blocked by seccomp, or no memlock left)\n",
                strerror(-ret));
        return 1;
    }
    puts("io_uring: available");

    struct io_uring_probe *p = io_uring_get_probe_ring(&ring);
    if (!p) {
        puts("probe: unavailable (kernel older than 5.6)");
    } else {
        printf("IORING_OP_ACCEPT: %s\n",
               io_uring_opcode_supported(p, IORING_OP_ACCEPT) ? "supported" : "NOT supported");
        io_uring_free_probe(p);
    }

    switch (multishot_accept_works(&ring)) {
    case 1:
        puts("multishot accept: works");
        break;
    case 0:
        puts("multishot accept: NOT supported (kernel older than 5.19)");
        break;
    default:
        puts("multishot accept: could not be checked");
    }
    io_uring_queue_exit(&ring);
    return 0;
}
