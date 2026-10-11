// producer.c — spawn_producer() for examples/async_incremental_read: start a
// shell command with its stdout on a pipe, as popen(3) does, but hand back
// only the pipe's read end. There is no FILE to pclose and no pid to wait
// for, so nothing is left behind when the runtime closes the fd itself (a
// client that disconnects mid-stream): main() has the kernel reap the child.

// For pipe2 and environ (<unistd.h>). V compiles with -D_GNU_SOURCE already;
// the guard keeps this file building on its own as well.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "producer.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>

// spawn_producer runs `sh -c script`, with the shell at sh_path and this
// process's environment (its PATH finds the commands the script runs), and
// returns the read end of the pipe that is the child's stdout: non-blocking,
// while the child's stdout stays blocking. It returns -1, with nothing left
// open, when the pipe or the spawn fails.
//
// The child starts with SIGPIPE and SIGCHLD at their default actions: an
// ignored signal stays ignored across exec, and this process ignores both
// (new_server ignores SIGPIPE, main() SIGCHLD). With SIGPIPE at its default,
// a producer whose reader is gone dies on its next write; with SIGCHLD at its
// default, the shell waits for its own children (`sleep`) as usual.
//
// Not free: per call, glibc allocates the file actions' list (freed by
// posix_spawn_file_actions_destroy) and maps a stack for the child, and
// posix_spawn returns only once the child has exec'd the shell.
int spawn_producer(const char *sh_path, const char *script) {
	int fds[2];
	// Close-on-exec on both ends: no child, neither this one nor one another
	// worker spawns at the same moment, keeps a copy across exec. So the
	// reader's close leaves the pipe with no reader, and the producer's exit
	// brings EOF. The child's stdout is a dup2 copy, which does not inherit
	// the flag.
	if (pipe2(fds, O_CLOEXEC) != 0) {
		return -1;
	}
	// O_NONBLOCK belongs to the open file description, which fds[1] shares
	// with the child's stdout: set it on the read end only.
	if (fcntl(fds[0], F_SETFL, O_NONBLOCK) != 0) {
		close(fds[0]);
		close(fds[1]);
		return -1;
	}
	sigset_t to_default;
	sigemptyset(&to_default);
	sigaddset(&to_default, SIGPIPE);
	sigaddset(&to_default, SIGCHLD);
	char *const argv[] = {(char *)"sh", (char *)"-c", (char *)script, NULL};
	posix_spawn_file_actions_t actions;
	posix_spawnattr_t attr;
	int err = -1;
	if (posix_spawn_file_actions_init(&actions) == 0) {
		if (posix_spawnattr_init(&attr) == 0) {
			if (posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO) == 0
				&& posix_spawnattr_setsigdefault(&attr, &to_default) == 0
				&& posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF) == 0) {
				err = posix_spawn(NULL, sh_path, &actions, &attr, argv, environ);
			}
			posix_spawnattr_destroy(&attr);
		}
		posix_spawn_file_actions_destroy(&actions);
	}
	close(fds[1]); // the child has its own copy, as its stdout
	if (err != 0) {
		close(fds[0]);
		return -1;
	}
	return fds[0];
}
