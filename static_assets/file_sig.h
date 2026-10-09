#ifndef VANILLA_SA_FILE_SIG_H
#define VANILLA_SA_FILE_SIG_H

/*
 * File signatures for static_assets' follow-the-disk mode.
 *
 * A representation is rebuilt when the signature of its file differs from the
 * one it was built from, by inequality and never by "newer mtime": a rename of
 * a new inode, a `cp -p` restore that puts an older mtime back and an in-place
 * rewrite all change at least one of (dev, ino, size, mtime_ns, ctime_ns).
 * ctime cannot be set from userspace, so a replacement that reuses an inode
 * number and restores size and mtime still differs. Nanosecond timestamps are
 * read here because V's os.Stat only has seconds.
 *
 * Only regular files are served: a stat of anything else (a FIFO, a directory,
 * a device put where the file was) fails like a missing file, so the last good
 * version keeps being served. open() is non-blocking so that a FIFO cannot
 * block the worker that opens it; O_NONBLOCK has no effect on reads (pread,
 * sendfile) of a regular file.
 *
 * A regular file with no link left (st_nlink 0) fails too: it is the outgoing
 * version of a file being replaced. rename(2) updates the ctime and link count
 * of the file it replaces before the name points at the new one, so a stat in
 * that gap sees the old file with a new signature; without this check it would
 * be republished as a duplicate snapshot of the version on its way out. The
 * two updates are not one atomic step, so such a duplicate stays possible,
 * only much rarer.
 *
 * vanilla_sa_now_ms() is the clock of the revalidate_ms window. On Linux it is
 * CLOCK_MONOTONIC_COARSE, served from the vDSO in a few nanoseconds, so a
 * request that is not due for a stat pays one clock read and one compare.
 *
 * Windows has no follow-the-disk support: every function is a stub that fails,
 * and static_assets.new() refuses follow_disk there.
 */

#include <stdint.h>

typedef struct vanilla_sa_sig {
	uint64_t dev;
	uint64_t ino;
	int64_t  size;
	int64_t  mtime_ns;
	int64_t  ctime_ns;
} vanilla_sa_sig;

#if defined(_WIN32)

static inline int vanilla_sa_open(const char* path) {
	(void)path;
	return -1;
}

static inline void vanilla_sa_close(int fd) {
	(void)fd;
}

static inline int vanilla_sa_stat(const char* path, vanilla_sa_sig* out) {
	(void)path;
	(void)out;
	return -1;
}

static inline int vanilla_sa_fstat(int fd, vanilla_sa_sig* out) {
	(void)fd;
	(void)out;
	return -1;
}

static inline uint64_t vanilla_sa_now_ms(void) {
	return 0;
}

#else

#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

static inline void vanilla_sa_fill(const struct stat* st, vanilla_sa_sig* out) {
	out->dev = (uint64_t)st->st_dev;
	out->ino = (uint64_t)st->st_ino;
	out->size = (int64_t)st->st_size;
#if defined(__APPLE__)
	out->mtime_ns = (int64_t)st->st_mtimespec.tv_sec * 1000000000LL + st->st_mtimespec.tv_nsec;
	out->ctime_ns = (int64_t)st->st_ctimespec.tv_sec * 1000000000LL + st->st_ctimespec.tv_nsec;
#else
	out->mtime_ns = (int64_t)st->st_mtim.tv_sec * 1000000000LL + st->st_mtim.tv_nsec;
	out->ctime_ns = (int64_t)st->st_ctim.tv_sec * 1000000000LL + st->st_ctim.tv_nsec;
#endif
}

// Opens a file for reading without blocking (a FIFO has no writer); the fd
// is not inherited across exec.
static inline int vanilla_sa_open(const char* path) {
	return open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
}

static inline void vanilla_sa_close(int fd) {
	close(fd);
}

// 0 and `*out` filled, or -1 (ENOENT while a file is being replaced, the old
// file in the middle of its replacement, not a regular file, ...).
static inline int vanilla_sa_stat(const char* path, vanilla_sa_sig* out) {
	struct stat st;
	if (stat(path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink == 0) {
		return -1;
	}
	vanilla_sa_fill(&st, out);
	return 0;
}

// Like vanilla_sa_stat, for an open file: -1 as well once it has been unlinked
// or replaced, so a snapshot is never built from a version already gone.
static inline int vanilla_sa_fstat(int fd, vanilla_sa_sig* out) {
	struct stat st;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink == 0) {
		return -1;
	}
	vanilla_sa_fill(&st, out);
	return 0;
}

static inline uint64_t vanilla_sa_now_ms(void) {
	struct timespec ts;
#if defined(CLOCK_MONOTONIC_COARSE)
	clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
#elif defined(CLOCK_MONOTONIC_FAST)
	clock_gettime(CLOCK_MONOTONIC_FAST, &ts);
#else
	clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
	return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

#endif // _WIN32

#endif // VANILLA_SA_FILE_SIG_H
