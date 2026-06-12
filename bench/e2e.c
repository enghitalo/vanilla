// e2e.c — end-to-end loopback HTTP benchmark of 3 response/buffer models.
// gcc -O3 -march=native -pthread -o e2e e2e.c
// ./e2e <mode> <pipeline_depth> <seconds>
//   mode 1: persistent conn buffers, response raw-written into write buf,
//           parse ALL pipelined reqs, ONE send per batch        (proposed)
//   mode 2: persistent recv buf, malloc response per request,
//           memcpy into write buf + free, ONE send per batch    (compat API)
//   mode 3: fresh 256B grow recv buf per event, malloc response,
//           one send PER response, free both                    (current vanilla)
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#define PORT 9099
#define MAXC 64
static int MODE = 1, DEPTH = 16, SECS = 5;
static volatile int stop_flag = 0;

static const char REQ[] = "GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n";
#define REQ_LEN (sizeof(REQ) - 1)
static const char PREFIX[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
#define PREFIX_LEN (sizeof(PREFIX) - 1)
static const char BODY[] = "Hello, World!";
#define BODY_LEN (sizeof(BODY) - 1)

static inline int itoa10(char *dst, int v) {
    char tmp[12]; int n = 0;
    do { tmp[n++] = '0' + v % 10; v /= 10; } while (v);
    for (int i = 0; i < n; i++) dst[i] = tmp[n - 1 - i];
    return n;
}

// "handler": builds the response. mode 1 writes straight into out; modes 2/3
// malloc, build, return (caller copies/sends + frees) — mirrors the V contract.
static inline int build_into(uint8_t *p0) {
    uint8_t *p = p0;
    memcpy(p, PREFIX, PREFIX_LEN); p += PREFIX_LEN;
    p += itoa10((char *)p, BODY_LEN);
    memcpy(p, "\r\n\r\n", 4); p += 4;
    memcpy(p, BODY, BODY_LEN); p += BODY_LEN;
    return p - p0;
}
static uint8_t *handler_alloc(int *len) {
    uint8_t *b = malloc(PREFIX_LEN + 16 + BODY_LEN);
    *len = build_into(b);
    return b;
}

typedef struct {
    uint8_t rbuf[16384]; int rlen;       // persistent recv buffer (modes 1,2)
    uint8_t wbuf[65536];                  // persistent write buffer (modes 1,2)
} conn_t;
static conn_t *conns[MAXC * 4];

static int find_req_end(const uint8_t *b, int len) { // returns consumed or -1
    for (int i = 3; i < len; i++)
        if (b[i-3]=='\r' && b[i-2]=='\n' && b[i-1]=='\r' && b[i]=='\n') return i + 1;
    return -1;
}

static void send_all(int fd, const uint8_t *b, int len) {
    int off = 0;
    while (off < len) {
        int n = send(fd, b + off, len - off, MSG_NOSIGNAL);
        if (n > 0) { off += n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue; // spin (bench)
        return;
    }
}

static void *server_main(void *arg) {
    (void)arg;
    int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT),
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    bind(lfd, (void *)&a, sizeof a);
    listen(lfd, 1024);

    int ep = epoll_create1(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = lfd };
    epoll_ctl(ep, EPOLL_CTL_ADD, lfd, &ev);
    struct epoll_event evs[512];

    while (!stop_flag) {
        int n = epoll_wait(ep, evs, 512, 100);
        for (int i = 0; i < n; i++) {
            int fd = evs[i].data.fd;
            if (fd == lfd) {
                int c;
                while ((c = accept4(lfd, NULL, NULL, SOCK_NONBLOCK)) >= 0) {
                    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    conns[c] = calloc(1, sizeof(conn_t));
                    struct epoll_event e2 = { .events = EPOLLIN | EPOLLET, .data.fd = c };
                    epoll_ctl(ep, EPOLL_CTL_ADD, c, &e2);
                }
                continue;
            }
            if (MODE == 3) {
                // current vanilla: fresh growing buffer per EPOLLIN event;
                // partial leftover saved per-fd across edges (save_read)
                conn_t *sv = conns[fd];
                size_t cap = 256, len = 0;
                uint8_t *buf = malloc(cap);
                if (sv->rlen > 0) {                 // resume saved partial
                    while ((size_t)sv->rlen > cap) { cap *= 2; }
                    buf = realloc(buf, cap);
                    memcpy(buf, sv->rbuf, sv->rlen);
                    len = sv->rlen; sv->rlen = 0;
                }
                int dead = 0;
                for (;;) {
                    if (len == cap) { cap *= 2; buf = realloc(buf, cap); }
                    int r = recv(fd, buf + len, cap - len, 0);
                    if (r > 0) { len += r; continue; }
                    if (r == 0) dead = 1;
                    break;             // EAGAIN or closed
                }
                // handler + ONE SEND per request found (vanilla's per-request
                // model; pipelined requests are answered here so the client
                // doesn't hang — vanilla itself would drop them):
                int pos = 0;
                while (!dead) {
                    int used = find_req_end(buf + pos, len - pos);
                    if (used < 0) break;
                    int rl; uint8_t *resp = handler_alloc(&rl);
                    send_all(fd, resp, rl);          // one send per response
                    free(resp);
                    pos += used;
                }
                if (!dead && (int)len > pos) {      // save partial for next edge
                    sv->rlen = len - pos;
                    memcpy(sv->rbuf, buf + pos, sv->rlen);
                }
                free(buf);
                if (dead) { close(fd); free(conns[fd]); conns[fd] = NULL; }
                continue;
            }
            // modes 1 & 2: persistent buffers + batched send
            conn_t *cs = conns[fd];
            int dead = 0;
            for (;;) {
                int r = recv(fd, cs->rbuf + cs->rlen, sizeof cs->rbuf - cs->rlen, 0);
                if (r > 0) { cs->rlen += r; continue; }
                if (r == 0) dead = 1;
                break;
            }
            int pos = 0, woff = 0;
            for (;;) {
                int used = find_req_end(cs->rbuf + pos, cs->rlen - pos);
                if (used < 0) break;
                if (MODE == 1) {
                    woff += build_into(cs->wbuf + woff);          // raw write
                } else {
                    int rl; uint8_t *resp = handler_alloc(&rl);   // compat
                    memcpy(cs->wbuf + woff, resp, rl);
                    woff += rl;
                    free(resp);
                }
                pos += used;
            }
            if (pos > 0) {
                memmove(cs->rbuf, cs->rbuf + pos, cs->rlen - pos);
                cs->rlen -= pos;
            }
            if (woff > 0) send_all(fd, cs->wbuf, woff);           // ONE send
            if (dead) { close(fd); free(conns[fd]); conns[fd] = NULL; }
        }
    }
    return NULL;
}

// client: C connections, each keeps DEPTH pipelined requests in flight
typedef struct { long done; } cstats_t;
static void *client_main(void *arg) {
    cstats_t *st = arg;
    enum { NC = 8 };
    int fds[NC];
    uint8_t reqbatch[REQ_LEN * 64];
    for (int i = 0; i < DEPTH; i++) memcpy(reqbatch + i * REQ_LEN, REQ, REQ_LEN);
    int batch_len = REQ_LEN * DEPTH;
    const int resp_len = PREFIX_LEN + 2 + 4 + BODY_LEN; // CL "13" = 2 digits

    for (int i = 0; i < NC; i++) {
        fds[i] = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT),
                                 .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        while (connect(fds[i], (void *)&a, sizeof a) < 0) usleep(1000);
        int one = 1; setsockopt(fds[i], IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };  // safety net
        setsockopt(fds[i], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    }
    uint8_t rbuf[1 << 16];
    while (!stop_flag) {
        for (int i = 0; i < NC && !stop_flag; i++) {
            if (send(fds[i], reqbatch, batch_len, MSG_NOSIGNAL) != batch_len) continue;
            int want = resp_len * DEPTH, got = 0;
            while (got < want) {
                int r = recv(fds[i], rbuf, sizeof rbuf, 0);
                if (r <= 0) break;
                got += r;
            }
            st->done += DEPTH;
        }
    }
    for (int i = 0; i < NC; i++) close(fds[i]);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) MODE = atoi(argv[1]);
    if (argc > 2) DEPTH = atoi(argv[2]);
    if (argc > 3) SECS = atoi(argv[3]);

    pthread_t sv, cl1, cl2;
    cstats_t s1 = {0}, s2 = {0};
    pthread_create(&sv, NULL, server_main, NULL);
    usleep(100 * 1000);
    pthread_create(&cl1, NULL, client_main, &s1);
    pthread_create(&cl2, NULL, client_main, &s2);

    sleep(SECS);
    stop_flag = 1;
    pthread_join(cl1, NULL); pthread_join(cl2, NULL);
    pthread_join(sv, NULL);

    long total = s1.done + s2.done;
    printf("mode=%d depth=%d  %.0f req/s\n", MODE, DEPTH, (double)total / SECS);
    return 0;
}
