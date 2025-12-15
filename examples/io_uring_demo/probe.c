#include <stdio.h>
#include <string.h>
#include <liburing.h>

int main() {
    struct io_uring ring;
    struct io_uring_probe *p;

    if (io_uring_queue_init(2, &ring, 0)) {
        perror("io_uring_queue_init");
        return 1;
    }

    p = io_uring_get_probe_ring(&ring);
    if (!p) {
        puts("failed to get probe");
        return 1;
    }

    for (unsigned i = 0; i < p->ops_len; i++) {
        struct io_uring_probe_op *op = &p->ops[i];

        if (op->op == IORING_OP_ACCEPT) {
            /* bit 0x1 == supports multishot (kernel ABI) */
            if (op->flags & 0x1)
                puts("multishot accept supported");
            else
                puts("NO multishot accept");
        }
    }

    io_uring_free_probe(p);
    io_uring_queue_exit(&ring);
    return 0;
}
