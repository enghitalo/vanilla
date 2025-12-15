@[translated]
module main

// iouring.c â Per-core io_uring HTTP server (2025)
// gcc -O3 -march=native -flto -pthread iouring.c -luring -o iouring
// Run with: ./iouring
// Access with: curl -v http://localhost:8080/
// wrk -c 512 -t 16 -d 15s http://localhost:8080/
// Note: Requires Linux 5.10+ with io_uring and liburing installed.
// ==================== Configuration ====================
// user_data encoding: [63:48]=op type, [47:0]=pointer value (assumes pointer fits 48 bits)
@[export: 'RESP']
const RESP = c'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'


@[export: 'RESP_LEN']
const RESP_LEN = sizeof(RESP) - 1


// ==================== Global State ====================
// static volatile sig_atomic_t g_running = 1;
fn handle_sig(sig int) {
	void(sig)
// g_running = 0;
	
}

fn tune_socket(fd int) {
	flags := fcntl(fd, 3, 0)
	fcntl(fd, 4, flags | 2048)
	one := 1
	setsockopt(fd, ipproto_tcp, 1, &one, sizeof(one))
// Larger send buffer allows kernel to batch better
	sndbuf := 524288
// 512KB
	setsockopt(fd, 1, 7, &sndbuf, sizeof(sndbuf))
// Larger recv buffer for incoming requests
	rcvbuf := 262144
// 256KB
	setsockopt(fd, 1, 8, &rcvbuf, sizeof(rcvbuf))
}

// ==================== Connection ====================
type Worker_t = Worker
struct Connection_t { 
	fd int
	buf [4096]i8
	owner &Worker_t
}
// ==================== Worker ====================
struct Worker { 
	ring Io_uring
	cpu_id int
	tid Pthread_t
	listen_fd int
	conns [32768]Connection_t
	free_stack [32768]int
	free_top int
}
fn pool_init(w &Worker_t) {
	w.free_top = 0
	for i := 0 ; i < (16384 * 2) ; i ++ {
		w.free_stack [w.free_top ++]  = i
	}
}

fn pool_acquire(w &Worker_t, fd int) &Connection_t {
	if w.free_top == 0 {
	return (voidptr(0))
	}
	idx := w.free_stack [w.free_top --$] 
	c := &w.conns [idx] 
	c.fd = fd
	c.owner = w
	return c
}

fn pool_release(c &Connection_t) {
	if !c {
	return 
	}
	w := c.owner
	C.close(c.fd)
	idx := int((c - w.conns))
	w.free_stack [w.free_top ++]  = idx
}

fn prep_accept(ring &Io_uring, listen_fd int) {
	sqe := io_uring_get_sqe(ring)
	if !sqe {
	return 
	}
	io_uring_prep_multishot_accept(sqe, listen_fd, (voidptr(0)), (voidptr(0)), sock_nonblock)
	io_uring_sqe_set_data64(sqe, (((u64((1))) << 48) | u64(C.uintptr_t(((voidptr(0)))))))
}

fn prep_read(ring &Io_uring, c &Connection_t) {
	sqe := io_uring_get_sqe(ring)
	if !sqe {
	return 
	}
	io_uring_prep_recv(sqe, c.fd, c.buf, 4096, 0)
	io_uring_sqe_set_data64(sqe, (((u64((2))) << 48) | u64(C.uintptr_t((c)))))
}

fn prep_write(ring &Io_uring, c &Connection_t) {
	sqe := io_uring_get_sqe(ring)
	if !sqe {
	return 
	}
	io_uring_prep_send(sqe, c.fd, RESP, RESP_LEN, 0)
	io_uring_sqe_set_data64(sqe, (((u64((3))) << 48) | u64(C.uintptr_t((c)))))
}

fn worker_main(arg voidptr) voidptr {
	w := arg
	set := Cpu_set_t{}
	for {
	__builtin_memset
	&set
	`\0`
	sizeof(Cpu_set_t)
	// while()
	if ! (0 ) { break }
	}
	()
	pthread_setaffinity_np(pthread_self(), sizeof(set), &set)
	ring := Io_uring{}
	p := Io_uring_params {
	//FAILED TO FIND STRUCT Io_uring_params
	0, }
	
	p.flags = (1 << 8) | (1 << 12) | (1 << 13)
	if io_uring_queue_init_params(16384, &ring, &p) < 0 {
		C.perror(c'io_uring_queue_init_params')
		return (voidptr(0))
	}
	w.ring = ring
	pool_init(w)
// Create per-worker listener with SO_REUSEPORT for zero contention
	lfd := socket(2, sock_stream | sock_cloexec | sock_nonblock, 0)
	if lfd < 0 {
		C.perror(c'socket')
		return (voidptr(0))
	}
	opt := 1
	setsockopt(lfd, 1, 2, &opt, sizeof(opt))
	setsockopt(lfd, 1, 15, &opt, sizeof(opt))
	setsockopt(lfd, ipproto_tcp, 9, &opt, sizeof(opt))
	addr := Sockaddr_in {
	//FAILED TO FIND STRUCT Sockaddr_in
	2, htons(8080), In_addr {
	//FAILED TO FIND STRUCT In_addr
	(In_addr_t(0))}
	, }
	
	if bind(lfd, __CONST_SOCKADDR_ARG {
	//FAILED TO FIND STRUCT __CONST_SOCKADDR_ARG
	&Sockaddr(&addr)}
	, sizeof(addr)) < 0 {
		C.perror(c'bind')
		C.close(lfd)
		return (voidptr(0))
	}
	if listen(lfd, 65535) < 0 {
		C.perror(c'listen')
		C.close(lfd)
		return (voidptr(0))
	}
	w.listen_fd = lfd
	prep_accept(&w.ring, w.listen_fd)
	io_uring_submit(&w.ring)
// while (g_running)
// {
//     struct io_uring_cqe *cqe;
//     int ret = io_uring_wait_cqe(&w->ring, &cqe);
//     if (ret == -EINTR)
//         continue;
//     if (ret < 0)
//         break;
//     unsigned head;
//     unsigned count = 0;
//     io_uring_for_each_cqe(&w->ring, head, cqe)
//     {
//         count++;
//         uint64_t data = io_uring_cqe_get_data64(cqe);
//         int op = UNPACK_OP(data);
//         connection_t *c = UNPACK_PTR(data);
//         int res = cqe->res;
//         switch (op)
//         {
//         case OP_ACCEPT:
//         {
//             if (res >= 0)
//             {
//                 int fd = res;
//                 tune_socket(fd);
//                 connection_t *nc = pool_acquire(w, fd);
//                 if (nc)
//                 {
//                     prep_read(&w->ring, nc);
//                 }
//                 else
//                 {
//                     close(fd);
//                 }
//             }
//             if (!(cqe->flags & IORING_CQE_F_MORE))
//             {
//                 prep_accept(&w->ring, w->listen_fd);
//             }
//             break;
//         }
//         case OP_READ:
//         {
//             if (res <= 0)
//             {
//                 pool_release(c);
//             }
//             else
//             {
//                 prep_write(&w->ring, c);
//             }
//             break;
//         }
//         case OP_WRITE:
//         {
//             if (res >= 0)
//             {
//                 prep_read(&w->ring, c);
//             }
//             else
//             {
//                 pool_release(c);
//             }
//             break;
//         }
//         default:
//             break;
//         }
//     }
//     if (count)
//         io_uring_cq_advance(&w->ring, count);
//     io_uring_submit(&w->ring);
// }
// Drain and cleanup
	cqe := &Io_uring_cqe(0)
	for !io_uring_peek_cqe(&w.ring, &cqe) {
		data := io_uring_cqe_get_data64(cqe)
		c := (voidptr(C.uintptr_t(((data) & 281474976710655))))
		op := (int(((data) >> 48)))
		if op == 2 || op == 3 {
		pool_release(c)
		}
		io_uring_cqe_seen(&w.ring, cqe)
	}
	io_uring_queue_exit(&w.ring)
	C.close(w.listen_fd)
	return (voidptr(0))
}

@[c:'__builtin_memset']
fn builtin_memset(arg0 voidptr, arg1 int, arg2 u32) voidptr

// ==================== Setup ====================
fn make_listener() int {
	fd := socket(2, sock_stream | sock_cloexec, 0)
	if fd < 0 {
	return -1
	}
	opt := 1
	setsockopt(fd, 1, 2, &opt, sizeof(opt))
	setsockopt(fd, 1, 15, &opt, sizeof(opt))
	setsockopt(fd, ipproto_tcp, 9, &opt, sizeof(opt))
	setsockopt(fd, ipproto_tcp, 23, &opt, sizeof(opt))
	zero := 0
	setsockopt(fd, ipproto_tcp, 12, &zero, sizeof(zero))
	addr := Sockaddr_in {
	//FAILED TO FIND STRUCT Sockaddr_in
	2, htons(8080), In_addr {
	//FAILED TO FIND STRUCT In_addr
	(In_addr_t(0))}
	, }
	
	if bind(fd, __CONST_SOCKADDR_ARG {
	//FAILED TO FIND STRUCT __CONST_SOCKADDR_ARG
	&Sockaddr(&addr)}
	, sizeof(addr)) < 0 {
	unsafe { goto fail }
	}
	if listen(fd, 65535) < 0 {
	unsafe { goto fail }
	}
	flags := fcntl(fd, 3, 0)
	fcntl(fd, 4, flags | 2048)
	return fd
	fail: 
	C.close(fd)
	return -1
}

fn main() {
	signal(2, handle_sig)
	signal(15, handle_sig)
	C.printf(c'io_uring HTTP server on :%d with %d workers (per-worker SO_REUSEPORT)\n', 8080, (int(sysconf(_sc_nprocessors_onln))))
	workers := C.calloc((int(sysconf(_sc_nprocessors_onln))), sizeof(Worker_t))
	if !workers {
	return 
	}
	for i := 0 ; i < (int(sysconf(_sc_nprocessors_onln))) ; i ++ {
		workers [i] .cpu_id = i
		pthread_create(&workers [i] .tid, (voidptr(0)), worker_main, &workers [i] )
	}
	for i := 0 ; i < (int(sysconf(_sc_nprocessors_onln))) ; i ++ {
		pthread_join(workers [i] .tid, (voidptr(0)))
	}
	C.free(workers)
	C.puts(c'Server stopped.')
	return 
}

