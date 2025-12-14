# HTTP Server Modules

Complete module organization for the vanilla HTTP server implementation.

## Module Structure

```
http_server/
├── http_server.c.v    # Main orchestration & server lifecycle
├── epoll.v            # Epoll I/O multiplexing abstractions
├── socket.v           # Socket creation & configuration
├── request.v          # HTTP request reading
├── response.v         # HTTP response sending
└── README.md          # Module documentation
```

---

## Module: `epoll.v`

**Purpose**: Linux epoll I/O multiplexing interface

### Exports

#### Types
```v
pub struct EpollEventCallbacks {
    on_read  fn(fd int)
    on_write fn(fd int)
}
```

#### Functions
```v
pub fn create_epoll_fd() int
pub fn add_fd_to_epoll(epoll_fd int, fd int, events u32) int
pub fn remove_fd_from_epoll(epoll_fd int, fd int)
```

### C Declarations
```v
fn C.epoll_create1(__flags int) int
fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int
fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int
fn C.perror(s &u8)
fn C.close(fd int)

union C.epoll_data { ptr, fd, u32, u64 }
struct C.epoll_event { events, data }
```

### Usage
```v
import http_server

epoll_fd := http_server.create_epoll_fd()
http_server.add_fd_to_epoll(epoll_fd, socket_fd, u32(C.EPOLLIN | C.EPOLLET))
http_server.remove_fd_from_epoll(epoll_fd, socket_fd) // closes fd automatically
```

---

## Module: `socket.v`

**Purpose**: TCP socket creation, configuration, and lifecycle

### Constants
```v
const max_connection_size = 1024
```

### Exports

#### Functions
```v
pub fn create_server_socket(port int) int
pub fn close_socket(fd int)
pub fn set_blocking(fd int, blocking bool)
```

### C Declarations
```v
fn C.socket(socket_family int, socket_type int, protocol int) int
fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int
fn C.setsockopt(__fd int, __level int, __optname int, __optval voidptr, __optlen u32) int
fn C.listen(__fd int, __n int) int
fn C.perror(s &u8)
fn C.close(fd int) int
fn C.accept(sockfd int, address &C.sockaddr_in, addrlen &u32) int
fn C.htons(__hostshort u16) u16
fn C.fcntl(fd int, cmd int, arg int) int

struct C.in_addr { s_addr }
struct C.sockaddr_in { sin_family, sin_port, sin_addr, sin_zero }
```

### Usage
```v
import http_server

socket_fd := http_server.create_server_socket(8080)
http_server.set_blocking(client_fd, false)
http_server.close_socket(socket_fd)
```

### Features
- Automatic SO_REUSEPORT configuration
- Non-blocking mode by default
- Binds to INADDR_ANY
- Configurable listen backlog

---

## Module: `request.v`

**Purpose**: HTTP request reading from client sockets

### Exports

#### Functions
```v
pub fn read_request(client_fd int) ![]u8
```

### C Declarations
```v
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
```

### Behavior
- Reads in 140-byte chunks
- Handles non-blocking partial reads
- Returns error on connection close or recv failure
- Caller must free returned buffer

### Error Cases
- `recv failed`: System error during read
- `client closed connection`: EOF received (0 bytes)
- `empty request`: No data read after loop

### Usage
```v
import http_server

request_buffer := http_server.read_request(client_fd) or {
    eprintln('Read error: ${err}')
    return
}
defer { unsafe { request_buffer.free() } }
```

---

## Module: `response.v`

**Purpose**: HTTP response transmission

### Constants
```v
pub const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\n...'.bytes()
const status_444_response = 'HTTP/1.1 444 No Response\r\n...'.bytes()
```

### Exports

#### Functions
```v
pub fn send_response(fd int, buffer_ptr &u8, buffer_len int) !
pub fn send_bad_request_response(fd int)
pub fn send_status_444_response(fd int)
```

### C Declarations
```v
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
```

### Features
- Zero-copy sending via MSG_ZEROCOPY
- Suppresses SIGPIPE via MSG_NOSIGNAL
- Returns error on send failure (except EAGAIN/EWOULDBLOCK)

### Usage
```v
import http_server

response := 'HTTP/1.1 200 OK\r\n...'.bytes()
http_server.send_response(fd, response.data, response.len) or {
    eprintln('Send failed: ${err}')
}

// Or use pre-built responses
http_server.send_bad_request_response(fd)
http_server.send_status_444_response(fd)
```

---

## Module: `http_server.c.v`

**Purpose**: Main server orchestration and lifecycle

### Constants
```v
const max_thread_pool_size = runtime.nr_cpus()
```

### Exports

#### Types
```v
pub struct Server {
pub:
    port int = 3000
pub mut:
    socket_fd       int
    threads         []thread
    request_handler fn([]u8, int) ![]u8 @[required]
}
```

#### Methods
```v
pub fn (mut server Server) run()
```

### Internal Functions
```v
fn handle_readable_fd(request_handler fn([]u8, int) ![]u8, epoll_fd int, client_conn_fd int)
fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int)
fn process_events(event_callbacks EpollEventCallbacks, epoll_fd int)
```

### C Declarations
```v
fn C.perror(s &u8)
```

### Architecture
- **Main thread**: Accept loop with dedicated epoll instance
- **Worker threads**: N threads (N = CPUs), each with own epoll instance
- **Load balancing**: Round-robin distribution of accepted connections

### Usage
```v
import http_server

fn my_handler(request []u8, client_fd int) ![]u8 {
    return 'HTTP/1.1 200 OK\r\n\r\nHello!'.bytes()
}

mut server := http_server.Server{
    port: 8080
    request_handler: my_handler
}

server.run() // Blocks until shutdown
```

---

## Module Dependencies

```
http_server.c.v
    ├─> epoll.v (create_epoll_fd, add_fd_to_epoll, remove_fd_from_epoll)
    ├─> socket.v (create_server_socket, close_socket, set_blocking)
    ├─> request.v (read_request)
    └─> response.v (send_response, send_bad_request_response, send_status_444_response)

epoll.v (standalone)
socket.v (standalone)
request.v (standalone)
response.v (standalone)
```

All modules are independent except `http_server.c.v` which orchestrates them.

---

## Thread Safety

### Per-Thread Isolation
- Each worker has dedicated epoll instance
- No shared mutable state between workers
- Client connections pinned to single worker thread

### Shared Resources
- `request_handler` function pointer (read-only)
- Request buffers passed as immutable slices

### User Responsibility
Request handler must be thread-safe if it accesses external state.

---

## Error Handling Strategy

### Connection Errors
All connection errors trigger automatic cleanup:
1. `remove_fd_from_epoll()` - removes from epoll and closes socket
2. Continue processing remaining events
3. No server-wide impact

### Request/Response Errors
- Logged to stderr
- Send appropriate HTTP error response
- Clean up connection
- Server continues running

### Fatal Errors
- Socket creation failure
- Epoll creation failure
- Causes server exit via `exit(1)`

---

## Performance Notes

### Memory
- 140-byte chunks for request reading
- No pre-allocated connection pool
- Stack-based event arrays (1024 events max)

### Concurrency
- O(1) accept via epoll edge-triggered mode
- Worker threads never block on I/O
- Lock-free operation (no mutexes)

### Network
- MSG_ZEROCOPY for responses (kernel 4.14+)
- MSG_NOSIGNAL to avoid signal overhead
- SO_REUSEPORT for multi-threaded accept
