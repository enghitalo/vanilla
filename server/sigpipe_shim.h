// sigpipe_shim.h — vanilla_ignore_default_sigpipe() for server.new_server.
// sigaction(2) with a NULL new action only reads the current disposition, so
// SIGPIPE is set to SIG_IGN only while it still has its default action, and a
// handler (or an explicit SIG_IGN) the application installed earlier is never
// replaced, not even for an instant as a signal()-then-restore would.
#ifndef VANILLA_SIGPIPE_SHIM_H
#define VANILLA_SIGPIPE_SHIM_H

#ifndef _WIN32
#include <signal.h>
#include <string.h>

// Returns 1 when it set SIGPIPE to SIG_IGN, 0 when it left it as it was.
static inline int vanilla_ignore_default_sigpipe(void) {
	struct sigaction old;
	if (sigaction(SIGPIPE, NULL, &old) != 0) {
		return 0;
	}
	if ((old.sa_flags & SA_SIGINFO) || old.sa_handler != SIG_DFL) {
		return 0;
	}
	struct sigaction ign;
	memset(&ign, 0, sizeof(ign));
	ign.sa_handler = SIG_IGN;
	sigemptyset(&ign.sa_mask);
	return sigaction(SIGPIPE, &ign, NULL) == 0;
}
#else
// Windows has no SIGPIPE.
static inline int vanilla_ignore_default_sigpipe(void) {
	return 0;
}
#endif

#endif
