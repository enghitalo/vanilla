// vanilla_* are libc's functions under names of vanilla's own. V checks that every declaration of
// one C function has the same signature, and vlib (builtin, net) and vanilla's consumers declare
// these with V's size type, which changed with vlang/v#31113 (usize before; uint, platform-width,
// after; and before it there was no uint at all). A declaration vanilla wrote under the libc name
// would clash with one of them on one V or the other; under these names it never does, and vanilla
// declares them with u64 and i64, which hold on every V (#385).
#ifndef VANILLA_LIBC_SHIM_H
#define VANILLA_LIBC_SHIM_H
#define vanilla_send send
#define vanilla_recv recv
#define vanilla_sendto sendto
#define vanilla_read read
#define vanilla_write write
#define vanilla_pread pread
#define vanilla_sendfile sendfile
#define vanilla_memset memset
#define vanilla_memcpy memcpy
#define vanilla_memmove memmove
#define vanilla_memchr memchr
#endif
