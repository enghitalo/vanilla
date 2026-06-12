// micro.c — response-building strategy micro-benchmark
// gcc -O3 -march=native -o micro micro.c
//
// Strategies, per "request":
//   A static_memcpy : fully precomputed response -> persistent out buffer
//   B raw_write     : prefix memcpy + itoa(Content-Length) + body memcpy,
//                     written directly into persistent out buffer (no abstraction)
//   C gutter_writer : body written at gutter offset, headers formatted in stack
//                     buf, body memmoved to abut headers (zeemo-style finalize)
//   D alloc_build   : malloc response, build inside it, free (current vanilla
//                     handler contract, minus the send)
//   E alloc_copy    : malloc, build, memcpy into persistent out buffer, free
//                     (compat path: old handler API + batched-send server)
//   F reqbuf_grow   : request-side: malloc(256) + realloc-doubling to fit a
//                     512B request + memcpy chunks + free (current epoll read
//                     path) vs nothing (persistent buffer baseline)
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static inline uint64_t now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static const char PREFIX[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
#define PREFIX_LEN (sizeof(PREFIX) - 1)
#define GUTTER 256

static inline int itoa10(char *dst, int v) {
    char tmp[12]; int n = 0;
    do { tmp[n++] = '0' + v % 10; v /= 10; } while (v);
    for (int i = 0; i < n; i++) dst[i] = tmp[n - 1 - i];
    return n;
}

// volatile sink so the optimizer can't delete the work
static volatile uint64_t sink;

typedef struct { const char *body; int body_len; } req_t;

// A
static size_t bench_static(uint8_t *out, const uint8_t *resp, int resp_len, long iters) {
    size_t off = 0;
    for (long i = 0; i < iters; i++) {
        if (off + resp_len > (1 << 20)) off = 0;          // wrap the "batch buffer"
        memcpy(out + off, resp, resp_len);
        off += resp_len;
    }
    return off;
}

// B
static size_t bench_raw(uint8_t *out, const req_t *r, long iters) {
    size_t off = 0;
    for (long i = 0; i < iters; i++) {
        if (off + GUTTER + r->body_len > (1 << 20)) off = 0;
        uint8_t *p = out + off;
        memcpy(p, PREFIX, PREFIX_LEN); p += PREFIX_LEN;
        p += itoa10((char *)p, r->body_len);
        memcpy(p, "\r\n\r\n", 4); p += 4;
        memcpy(p, r->body, r->body_len); p += r->body_len;
        off = p - out;
    }
    return off;
}

// C
static size_t bench_gutter(uint8_t *out, const req_t *r, long iters) {
    size_t off = 0;
    for (long i = 0; i < iters; i++) {
        if (off + GUTTER + r->body_len + 256 > (1 << 20)) off = 0;
        uint8_t *base = out + off;
        memcpy(base + GUTTER, r->body, r->body_len);       // handler writes body
        char hdr[GUTTER]; int h = 0;                        // finalize:
        memcpy(hdr, PREFIX, PREFIX_LEN); h = PREFIX_LEN;
        h += itoa10(hdr + h, r->body_len);
        memcpy(hdr + h, "\r\n\r\n", 4); h += 4;
        memmove(base + h, base + GUTTER, r->body_len);      // slide body left
        memcpy(base, hdr, h);
        off += h + r->body_len;
    }
    return off;
}

// D
static size_t bench_alloc(const req_t *r, long iters) {
    size_t acc = 0;
    for (long i = 0; i < iters; i++) {
        uint8_t *p0 = malloc(PREFIX_LEN + 16 + r->body_len);
        uint8_t *p = p0;
        memcpy(p, PREFIX, PREFIX_LEN); p += PREFIX_LEN;
        p += itoa10((char *)p, r->body_len);
        memcpy(p, "\r\n\r\n", 4); p += 4;
        memcpy(p, r->body, r->body_len); p += r->body_len;
        acc += p0[4] + (p - p0);                            // touch + length
        free(p0);
    }
    return acc;
}

// E
static size_t bench_alloc_copy(uint8_t *out, const req_t *r, long iters) {
    size_t off = 0;
    for (long i = 0; i < iters; i++) {
        uint8_t *p0 = malloc(PREFIX_LEN + 16 + r->body_len);
        uint8_t *p = p0;
        memcpy(p, PREFIX, PREFIX_LEN); p += PREFIX_LEN;
        p += itoa10((char *)p, r->body_len);
        memcpy(p, "\r\n\r\n", 4); p += 4;
        memcpy(p, r->body, r->body_len); p += r->body_len;
        int len = p - p0;
        if (off + len > (1 << 20)) off = 0;
        memcpy(out + off, p0, len);
        off += len;
        free(p0);
    }
    return off;
}

// F — request-side read buffer: current epoll path (fresh 256B buf, grow by
// doubling while "recv"ing a 512-byte request in 256B chunks), vs persistent.
static size_t bench_reqbuf_grow(const uint8_t *wire, int req_len, long iters) {
    size_t acc = 0;
    for (long i = 0; i < iters; i++) {
        size_t cap = 256, len = 0;
        uint8_t *buf = malloc(cap);
        while ((int)len < req_len) {
            if (len == cap) { cap *= 2; buf = realloc(buf, cap); }
            size_t spare = cap - len, n = (size_t)req_len - len;
            if (n > spare) n = spare;
            memcpy(buf + len, wire + len, n);               // simulated recv
            len += n;
        }
        acc += buf[len - 1];
        free(buf);
    }
    return acc;
}

static size_t bench_reqbuf_persistent(uint8_t *conn_buf, const uint8_t *wire, int req_len, long iters) {
    size_t acc = 0;
    for (long i = 0; i < iters; i++) {
        memcpy(conn_buf, wire, req_len);                    // single recv, big buffer
        acc += conn_buf[req_len - 1];
    }
    return acc;
}

static void run(const char *name, size_t (*fn)(void), long iters) { (void)name; (void)fn; (void)iters; }

#define BENCH(label, expr)                                                  \
    do {                                                                    \
        /* warmup */                                                        \
        sink += (expr);                                                     \
        uint64_t t0 = now_ns();                                             \
        sink += (expr);                                                     \
        uint64_t dt = now_ns() - t0;                                        \
        printf("%-34s %8.2f ns/op  (%6.1f Mops/s)\n", label,                \
               (double)dt / iters, iters * 1000.0 / dt);                    \
    } while (0)

int main(void) {
    long iters = 20 * 1000 * 1000;
    uint8_t *out = aligned_alloc(64, 1 << 20);
    memset(out, 0, 1 << 20);

    static char body13[13];  memset(body13, 'x', 13);
    static char body1k[1024]; memset(body1k, 'y', 1024);
    req_t small = { body13, 13 }, big = { body1k, 1024 };

    // precomputed static response (small)
    uint8_t resp_static[256]; req_t tmp = small;
    uint8_t *p = resp_static;
    memcpy(p, PREFIX, PREFIX_LEN); p += PREFIX_LEN;
    p += itoa10((char *)p, tmp.body_len);
    memcpy(p, "\r\n\r\n", 4); p += 4;
    memcpy(p, body13, 13); p += 13;
    int resp_static_len = p - resp_static;

    uint8_t wire[512]; memset(wire, 'r', sizeof wire);
    uint8_t *conn_buf = aligned_alloc(64, 8192);

    printf("== response building, 13-byte body (%ld iters) ==\n", iters);
    BENCH("A static_memcpy (precomputed)", bench_static(out, resp_static, resp_static_len, iters));
    BENCH("B raw_write (persistent buf)", bench_raw(out, &small, iters));
    BENCH("C gutter_writer (finalize+move)", bench_gutter(out, &small, iters));
    BENCH("D alloc_build+free (current)", bench_alloc(&small, iters));
    BENCH("E alloc+copy+free (compat)", bench_alloc_copy(out, &small, iters));

    printf("\n== response building, 1 KiB body ==\n");
    BENCH("B raw_write (persistent buf)", bench_raw(out, &big, iters));
    BENCH("C gutter_writer (finalize+move)", bench_gutter(out, &big, iters));
    BENCH("D alloc_build+free (current)", bench_alloc(&big, iters));
    BENCH("E alloc+copy+free (compat)", bench_alloc_copy(out, &big, iters));

    printf("\n== request read buffer, 512-byte request ==\n");
    BENCH("F1 fresh 256B buf + grow (current)", bench_reqbuf_grow(wire, 512, iters));
    BENCH("F2 persistent 8KiB buf", bench_reqbuf_persistent(conn_buf, wire, 512, iters));

    printf("\nsink=%llu\n", (unsigned long long)sink);
    return 0;
}
