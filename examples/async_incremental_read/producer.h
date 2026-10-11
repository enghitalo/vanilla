// producer.h — spawn_producer(), defined in producer.c. It is a translation
// unit of its own because <spawn.h> does not compile next to vlib's os module,
// which declares posix_spawn with opaque types in V's generated C.
#ifndef ASYNC_INCREMENTAL_READ_PRODUCER_H
#define ASYNC_INCREMENTAL_READ_PRODUCER_H

int spawn_producer(const char *sh_path, const char *script);

#endif
