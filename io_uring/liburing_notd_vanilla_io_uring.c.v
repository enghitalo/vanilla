module io_uring

// notd twin of liburing_d_vanilla_io_uring.c.v: without the flag liburing is
// neither included nor linked, so the bindings in this module cannot compile.
// The server imports io_uring only under the flag; any other importer gets this
// message instead of C errors about liburing symbols.
$compile_error('the io_uring module requires building with `-d vanilla_io_uring` (and liburing installed)')
