// transport_shim.h — module-local typedef aliases for the sockaddr shapes
// transport/ dials with. The socket/ module already declares V bindings for
// `struct sockaddr_in`/`sockaddr_un` under their real C names; aliasing here
// keeps transport/ free of any vanilla import (dependency rule,
// docs/ARCHITECTURE.md) without redeclaring the same C type name twice.
#ifndef VANILLA_TRANSPORT_SHIM_H
#define VANILLA_TRANSPORT_SHIM_H

#ifdef _WIN32
#include <winsock2.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
#else
#include <netinet/in.h>
#include <sys/un.h>

typedef struct in_addr transport_in_addr;
typedef struct sockaddr_in transport_sockaddr_in;
typedef struct sockaddr_un transport_sockaddr_un;
#endif

#endif
