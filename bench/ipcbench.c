/* ipcbench.c — TCP loopback (127.0.0.1, TCP_NODELAY) vs Unix domain socket
 * (AF_UNIX SOCK_STREAM, pathname) for same-machine request/response traffic.
 *
 * Phases per transport (server = forked child, pinned core 2; client pinned core 4):
 *   1. Ping-pong RTT: sizes 64/512/4096/16384 B; 2000 warmup + 20000 timed
 *      round trips each; per-iteration RTT recorded; p50/p99/mean reported (us).
 *   2. Throughput: client streams 64 KiB writes for ~2 s, shutdown(WR); server
 *      reads+discards until EOF, then acks total byte count; GiB/s from
 *      start-of-stream to ack (so buffered bytes are accounted for).
 *   3. Connection setup: 2000 x socket()+connect()+close(); p50 reported (us).
 *
 * All reads/writes loop until the full count is transferred (short I/O handled).
 * UDS is bound with a RELATIVE path ("u.sock") after chdir(argv[1]) to stay
 * under the 108-byte sun_path limit.
 *
 * Build: cc -O2 -o ipcbench ipcbench.c
 * Run:   ./ipcbench /path/to/benchdir
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define TCP_PORT 39471
#define UDS_PATH "u.sock" /* relative: sun_path is limited to 108 bytes */
#define WARMUP 2000
#define ITERS 20000
#define CONN_ITERS 2000
#define TP_CHUNK (64 * 1024)
#define TP_SECS 2.0
#define SERVER_CPU 2
#define CLIENT_CPU 4

static const size_t sizes[] = { 64, 512, 4096, 16384 };
#define NSIZES 4

static uint64_t now_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void pin_cpu(int cpu) {
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(cpu, &s);
	if (sched_setaffinity(0, sizeof(s), &s) != 0) {
		fprintf(stderr, "warn: sched_setaffinity(cpu %d) failed: %s\n", cpu, strerror(errno));
	}
}

static void die(const char *what) {
	perror(what);
	exit(1);
}

static void write_full(int fd, const void *buf, size_t n) {
	const char *p = buf;
	while (n > 0) {
		ssize_t r = write(fd, p, n);
		if (r < 0) {
			if (errno == EINTR) continue;
			die("write");
		}
		p += r;
		n -= (size_t)r;
	}
}

static void read_full(int fd, void *buf, size_t n) {
	char *p = buf;
	while (n > 0) {
		ssize_t r = read(fd, p, n);
		if (r < 0) {
			if (errno == EINTR) continue;
			die("read");
		}
		if (r == 0) {
			fprintf(stderr, "unexpected EOF\n");
			exit(1);
		}
		p += r;
		n -= (size_t)r;
	}
}

static void set_nodelay(int fd) {
	int one = 1;
	if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) != 0)
		die("setsockopt TCP_NODELAY");
}

static int cmp_u64(const void *a, const void *b) {
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return (x > y) - (x < y);
}

/* lat must be sorted already */
static double pct_us(const uint64_t *lat, int n, double p) {
	int idx = (int)((double)n * p);
	if (idx >= n) idx = n - 1;
	return (double)lat[idx] / 1000.0;
}

static double mean_us(const uint64_t *lat, int n) {
	double s = 0;
	for (int i = 0; i < n; i++) s += (double)lat[i];
	return s / (double)n / 1000.0;
}

/* ---------- listeners ---------- */

static int listen_tcp(void) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) die("socket tcp");
	int one = 1;
	if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0)
		die("setsockopt SO_REUSEADDR");
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(TCP_PORT);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) die("bind tcp");
	if (listen(fd, 512) != 0) die("listen tcp");
	return fd;
}

static int listen_uds(void) {
	unlink(UDS_PATH);
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) die("socket uds");
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, UDS_PATH, sizeof(a.sun_path) - 1);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) die("bind uds");
	if (listen(fd, 512) != 0) die("listen uds");
	return fd;
}

/* ---------- client connectors ---------- */

static int connect_tcp(int nodelay) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) die("socket tcp");
	if (nodelay) set_nodelay(fd);
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(TCP_PORT);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) die("connect tcp");
	return fd;
}

static int connect_uds(void) {
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) die("socket uds");
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, UDS_PATH, sizeof(a.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) die("connect uds");
	return fd;
}

/* ---------- server (child) ---------- */

static void server_loop(int lfd, int is_tcp) {
	pin_cpu(SERVER_CPU);
	char *buf = malloc(TP_CHUNK);
	if (!buf) die("malloc");

	/* phase 1: echo ping-pong */
	int c = accept(lfd, NULL, NULL);
	if (c < 0) die("accept");
	if (is_tcp) set_nodelay(c);
	for (int si = 0; si < NSIZES; si++) {
		size_t s = sizes[si];
		for (int i = 0; i < WARMUP + ITERS; i++) {
			read_full(c, buf, s);
			write_full(c, buf, s);
		}
	}
	close(c);

	/* phase 2: throughput sink — read+discard until EOF, then ack byte count */
	c = accept(lfd, NULL, NULL);
	if (c < 0) die("accept");
	uint64_t total = 0;
	for (;;) {
		ssize_t r = read(c, buf, TP_CHUNK);
		if (r < 0) {
			if (errno == EINTR) continue;
			die("read tp");
		}
		if (r == 0) break;
		total += (uint64_t)r;
	}
	write_full(c, &total, sizeof(total));
	close(c);

	/* phase 3: accept+close churn */
	for (int i = 0; i < CONN_ITERS; i++) {
		int cc = accept(lfd, NULL, NULL);
		if (cc < 0) die("accept churn");
		close(cc);
	}
	free(buf);
}

/* ---------- client (parent) ---------- */

static void client_suite(const char *name, int is_tcp) {
	pin_cpu(CLIENT_CPU);
	char *buf = malloc(TP_CHUNK);
	uint64_t *lat = malloc((size_t)ITERS * sizeof(uint64_t));
	uint64_t *clat = malloc((size_t)CONN_ITERS * sizeof(uint64_t));
	if (!buf || !lat || !clat) die("malloc");
	memset(buf, 'x', TP_CHUNK);

	/* phase 1: RTT ping-pong */
	int c = is_tcp ? connect_tcp(1) : connect_uds();
	for (int si = 0; si < NSIZES; si++) {
		size_t s = sizes[si];
		for (int i = 0; i < WARMUP; i++) {
			write_full(c, buf, s);
			read_full(c, buf, s);
		}
		for (int i = 0; i < ITERS; i++) {
			uint64_t t0 = now_ns();
			write_full(c, buf, s);
			read_full(c, buf, s);
			lat[i] = now_ns() - t0;
		}
		double mean = mean_us(lat, ITERS);
		qsort(lat, ITERS, sizeof(uint64_t), cmp_u64);
		printf("RTT %s %zu p50=%.2f p99=%.2f mean=%.2f\n", name, s,
			pct_us(lat, ITERS, 0.50), pct_us(lat, ITERS, 0.99), mean);
		fflush(stdout);
	}
	close(c);

	/* phase 2: throughput */
	c = is_tcp ? connect_tcp(1) : connect_uds();
	uint64_t t0 = now_ns();
	uint64_t deadline = t0 + (uint64_t)(TP_SECS * 1e9);
	uint64_t sent = 0;
	while (now_ns() < deadline) {
		write_full(c, buf, TP_CHUNK);
		sent += TP_CHUNK;
	}
	if (shutdown(c, SHUT_WR) != 0) die("shutdown");
	uint64_t got = 0;
	read_full(c, &got, sizeof(got));
	uint64_t t1 = now_ns();
	double secs = (double)(t1 - t0) / 1e9;
	printf("THROUGHPUT %s gib_s=%.3f bytes=%llu secs=%.3f ack_ok=%d\n", name,
		(double)sent / secs / (double)(1ull << 30),
		(unsigned long long)sent, secs, got == sent);
	fflush(stdout);
	close(c);

	/* phase 3: socket()+connect()+close() latency */
	for (int i = 0; i < CONN_ITERS; i++) {
		uint64_t s0 = now_ns();
		int fd = is_tcp ? connect_tcp(0) : connect_uds();
		close(fd);
		clat[i] = now_ns() - s0;
	}
	double cmean = mean_us(clat, CONN_ITERS);
	qsort(clat, CONN_ITERS, sizeof(uint64_t), cmp_u64);
	printf("CONNECT %s p50=%.2f p99=%.2f mean=%.2f\n", name,
		pct_us(clat, CONN_ITERS, 0.50), pct_us(clat, CONN_ITERS, 0.99), cmean);
	fflush(stdout);

	free(buf);
	free(lat);
	free(clat);
}

static void run_transport(const char *name, int is_tcp) {
	int lfd = is_tcp ? listen_tcp() : listen_uds();
	pid_t pid = fork();
	if (pid < 0) die("fork");
	if (pid == 0) {
		server_loop(lfd, is_tcp);
		_exit(0);
	}
	client_suite(name, is_tcp);
	int st = 0;
	waitpid(pid, &st, 0);
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
		fprintf(stderr, "server child failed (status %d)\n", st);
		exit(1);
	}
	close(lfd);
	if (!is_tcp) unlink(UDS_PATH);
}

int main(int argc, char **argv) {
	if (argc > 1 && chdir(argv[1]) != 0) die("chdir");
	setvbuf(stdout, NULL, _IOLBF, 0);
	run_transport("tcp", 1);
	run_transport("uds", 0);
	return 0;
}
