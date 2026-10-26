// vanilla_send, vanilla_recv and vanilla_sendto are send(2), recv(2) and sendto(2) under names of
// vanilla's own. V checks that every declaration of one C function has the same signature, and
// vlib's net module declares these three with V's size type, which changes between V versions
// (usize before vlang/v#31113, uint after). A program that compiles net beside vanilla (a test, an
// example) would clash with any declaration vanilla writes; under these names it never does, and
// vanilla declares them with u64 on every V.
#ifndef VANILLA_SOCK_SHIM_H
#define VANILLA_SOCK_SHIM_H
#define vanilla_send send
#define vanilla_recv recv
#define vanilla_sendto sendto
#endif
