// poll_shim.h — typedef alias so the poll/ module binds struct pollfd under
// its own name. vtest (and any consumer's test code) may declare `C.pollfd`
// itself with different field visibility; aliasing sidesteps the collision
// the same way transport/transport_shim.h does for the sockaddr shapes.
#ifndef VANILLA_POLL_SHIM_H
#define VANILLA_POLL_SHIM_H

#include <poll.h>

typedef struct pollfd vanilla_pollfd;

#endif
