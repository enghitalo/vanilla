module io_uring

// The ONLY place liburing enters a build (issue #189): headers at compile time,
// liburing.so.2 at run time. Compiled only with `-d vanilla_io_uring` (Linux),
// so an epoll-only binary neither needs liburing-dev to build nor liburing.so.2
// to start.
#include <liburing.h>
#flag -luring
