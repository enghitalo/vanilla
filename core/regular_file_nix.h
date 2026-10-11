#ifndef VANILLA_CORE_REGULAR_FILE_H
#define VANILLA_CORE_REGULAR_FILE_H

/*
 * fstat(2) kept on the C side: the struct stat never becomes a V value. V
 * declares C.stat with a fixed-array field on macOS (st_qspare), and there a
 * stat struct, or any stack array, whose address a V function hands to
 * C.fstat is moved to the heap on every call.
 */

#include <sys/stat.h>

/* The size of the regular file open on fd, or -1 when fstat fails or fd is
 * not a regular file (a directory, a FIFO, a device). */
static inline long long vanilla_regular_file_size(int fd) {
	struct stat st;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		return -1;
	}
	return (long long)st.st_size;
}

#endif
