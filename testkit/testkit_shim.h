// testkit_shim.h — module-local typedef alias for poll(2)'s pollfd. Other
// modules in a test binary (vtest, server/backend_poll) declare their own V
// bindings for pollfd-shaped structs; aliasing under a testkit_ name keeps
// this module clash-free without importing anything (V C-struct declarations
// are program-wide, so two modules must not bind the same C tag).
#ifndef VANILLA_TESTKIT_SHIM_H
#define VANILLA_TESTKIT_SHIM_H

#include <poll.h>

typedef struct pollfd testkit_pollfd;

#endif
