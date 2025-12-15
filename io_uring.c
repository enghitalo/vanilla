// iouring.c — Per-core io_uring HTTP server (2025)
// gcc -O3 -march=native -flto -pthread iouring.c -luring -o iouring
// Run with: ./iouring
// Access with: curl -v http://localhost:8080/
// wrk -c 512 -t 16 -d 15s http://localhost:8080/
// Note: Requires Linux 5.10+ with io_uring and liburing installed.

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sched.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <netinet/tcp.h>
#include <liburing.h>

// ==================== Configuration ====================

#define PORT 8080
#define BACKLOG 65535
#define RING_ENTRIES 16384
#define BUFFER_SIZE 4096
#define NUM_WORKERS ((int)sysconf(_SC_NPROCESSORS_ONLN))
#define MAX_CONN_PER_WORKER (RING_ENTRIES * 2)

// user_data encoding: [63:48]=op type, [47:0]=pointer value (assumes pointer fits 48 bits)
#define OP_ACCEPT 1
#define OP_READ 2
#define OP_WRITE 3
#define PACK(op, ptr) ((((uint64_t)(op)) << 48) | (uint64_t)(uintptr_t)(ptr))
#define UNPACK_OP(x) ((int)((x) >> 48))
#define UNPACK_PTR(x) ((void *)(uintptr_t)((x) & 0x0000FFFFFFFFFFFFULL))

static const char RESP[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 2\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
    "OK";
static const size_t RESP_LEN = sizeof(RESP) - 1;

// ==================== Global State ====================

static volatile sig_atomic_t g_running = 1;

static void handle_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

static inline void tune_socket(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // Larger send buffer allows kernel to batch better
    int sndbuf = 524288; // 512KB
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    // Larger recv buffer for incoming requests
    int rcvbuf = 262144; // 256KB
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
}

// ==================== Connection ====================

typedef struct worker worker_t;

typedef struct connection
{
    int fd;
    char buf[BUFFER_SIZE];
    worker_t *owner;
} connection_t;

// ==================== Worker ====================

struct worker
{
    struct io_uring ring;
    int cpu_id;
    pthread_t tid;
    int listen_fd;
    connection_t conns[MAX_CONN_PER_WORKER];
    int free_stack[MAX_CONN_PER_WORKER];
    int free_top;
};

static inline void pool_init(worker_t *w)
{
    w->free_top = 0;
    for (int i = 0; i < MAX_CONN_PER_WORKER; i++)
    {
        w->free_stack[w->free_top++] = i;
    }
}

static inline connection_t *pool_acquire(worker_t *w, int fd)
{
    if (w->free_top == 0)
        return NULL;
    int idx = w->free_stack[--w->free_top];
    connection_t *c = &w->conns[idx];
    c->fd = fd;
    c->owner = w;
    return c;
}

static inline void pool_release(connection_t *c)
{
    if (!c)
        return;
    worker_t *w = c->owner;
    close(c->fd);
    int idx = (int)(c - w->conns);
    w->free_stack[w->free_top++] = idx;
}

static void prep_accept(struct io_uring *ring, int listen_fd)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
    if (!sqe)
        return;
    io_uring_prep_multishot_accept(sqe, listen_fd, NULL, NULL, SOCK_NONBLOCK);
    io_uring_sqe_set_data64(sqe, PACK(OP_ACCEPT, NULL));
}

static void prep_read(struct io_uring *ring, connection_t *c)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
    if (!sqe)
        return;
    io_uring_prep_recv(sqe, c->fd, c->buf, BUFFER_SIZE, 0);
    io_uring_sqe_set_data64(sqe, PACK(OP_READ, c));
}

static void prep_write(struct io_uring *ring, connection_t *c)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
    if (!sqe)
        return;
    io_uring_prep_send(sqe, c->fd, RESP, RESP_LEN, 0);
    io_uring_sqe_set_data64(sqe, PACK(OP_WRITE, c));
}

static void *worker_main(void *arg)
{
    worker_t *w = arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->cpu_id, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(set), &set);

    struct io_uring ring;
    struct io_uring_params p = {0};
    p.flags = IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    if (io_uring_queue_init_params(RING_ENTRIES, &ring, &p) < 0)
    {
        perror("io_uring_queue_init_params");
        return NULL;
    }
    w->ring = ring;

    pool_init(w);

    // Create per-worker listener with SO_REUSEPORT for zero contention
    int lfd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (lfd < 0)
    {
        perror("socket");
        return NULL;
    }
    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    setsockopt(lfd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PORT),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
        perror("bind");
        close(lfd);
        return NULL;
    }
    if (listen(lfd, BACKLOG) < 0)
    {
        perror("listen");
        close(lfd);
        return NULL;
    }
    w->listen_fd = lfd;

    prep_accept(&w->ring, w->listen_fd);
    io_uring_submit(&w->ring);

    while (g_running)
    {
        struct io_uring_cqe *cqe;
        int ret = io_uring_wait_cqe(&w->ring, &cqe);
        if (ret == -EINTR)
            continue;
        if (ret < 0)
            break;

        unsigned head;
        unsigned count = 0;
        io_uring_for_each_cqe(&w->ring, head, cqe)
        {
            count++;
            uint64_t data = io_uring_cqe_get_data64(cqe);
            int op = UNPACK_OP(data);
            connection_t *c = UNPACK_PTR(data);
            int res = cqe->res;

            switch (op)
            {
            case OP_ACCEPT:
            {
                if (res >= 0)
                {
                    int fd = res;
                    tune_socket(fd);
                    connection_t *nc = pool_acquire(w, fd);
                    if (nc)
                    {
                        prep_read(&w->ring, nc);
                    }
                    else
                    {
                        close(fd);
                    }
                }
                if (!(cqe->flags & IORING_CQE_F_MORE))
                {
                    prep_accept(&w->ring, w->listen_fd);
                }
                break;
            }
            case OP_READ:
            {
                if (res <= 0)
                {
                    pool_release(c);
                }
                else
                {
                    prep_write(&w->ring, c);
                }
                break;
            }
            case OP_WRITE:
            {
                if (res >= 0)
                {
                    prep_read(&w->ring, c);
                }
                else
                {
                    pool_release(c);
                }
                break;
            }
            default:
                break;
            }
        }
        if (count)
            io_uring_cq_advance(&w->ring, count);

        io_uring_submit(&w->ring);
    }

    // Drain and cleanup
    struct io_uring_cqe *cqe;
    while (!io_uring_peek_cqe(&w->ring, &cqe))
    {
        uint64_t data = io_uring_cqe_get_data64(cqe);
        connection_t *c = UNPACK_PTR(data);
        int op = UNPACK_OP(data);
        if (op == OP_READ || op == OP_WRITE)
            pool_release(c);
        io_uring_cqe_seen(&w->ring, cqe);
    }

    io_uring_queue_exit(&w->ring);
    close(w->listen_fd);
    return NULL;
}

// ==================== Setup ====================

static int make_listener(void)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &opt, sizeof(opt));
    setsockopt(fd, IPPROTO_TCP, TCP_FASTOPEN, &opt, sizeof(opt));
    int zero = 0;
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &zero, sizeof(zero));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PORT),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        goto fail;
    if (listen(fd, BACKLOG) < 0)
        goto fail;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    return fd;
fail:
    close(fd);
    return -1;
}

int main(void)
{
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);

    printf("io_uring HTTP server on :%d with %d workers (per-worker SO_REUSEPORT)\n", PORT, NUM_WORKERS);

    worker_t *workers = calloc(NUM_WORKERS, sizeof(worker_t));
    if (!workers)
        return 1;

    for (int i = 0; i < NUM_WORKERS; i++)
    {
        workers[i].cpu_id = i;
        pthread_create(&workers[i].tid, NULL, worker_main, &workers[i]);
    }

    for (int i = 0; i < NUM_WORKERS; i++)
    {
        pthread_join(workers[i].tid, NULL);
    }

    free(workers);
    puts("Server stopped.");
    return 0;
}
