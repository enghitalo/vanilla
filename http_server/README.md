# HTTP Server Module

A high-performance, epoll-based HTTP server implementation for V.

## Architecture

The module is organized into focused components:

### Core Files

#### `http_server.c.v`
Main orchestration and server lifecycle management.

**Key Components:**
- `Server` struct: Main server configuration and state
- `run()`: Server initialization, thread pool setup, and accept loop
- `handle_accept_loop()`: Non-blocking connection acceptance with round-robin load balancing
- `process_events()`: Epoll event loop for client connections
- `handle_readable_fd()`: Request reading, handler invocation, and response sending

**Threading Model:**
- Main thread: Handles `accept()` via dedicated epoll instance
- Worker threads: One per CPU core, each with its own epoll instance for client I/O
- Round-robin distribution of accepted connections across worker threads

---

#### `epoll.v`
Low-level epoll abstractions for Linux I/O multiplexing.

**Exports:**
- `EpollEventCallbacks`: Callback interface for read/write events
  - `on_read fn(fd int)`: Invoked when socket is readable
  - `on_write fn(fd int)`: Invoked when socket is writable
- `create_epoll_fd() int`: Creates new epoll instance
- `add_fd_to_epoll(epoll_fd int, fd int, events u32) int`: Registers fd with events
- `remove_fd_from_epoll(epoll_fd int, fd int)`: Unregisters fd

**Event Flags:**
- `C.EPOLLIN`: Socket readable
- `C.EPOLLOUT`: Socket writable
- `C.EPOLLET`: Edge-triggered mode
- `C.EPOLLHUP | C.EPOLLERR`: Connection errors

---

#### `socket.v`
Socket creation, configuration, and lifecycle management.

**Exports:**
- `create_server_socket(port int) int`: Creates non-blocking TCP server socket
  - Enables `SO_REUSEPORT` for multi-threaded accept
  - Binds to `INADDR_ANY`
  - Sets listen backlog to `max_connection_size`
- `close_socket(fd int)`: Closes socket descriptor
- `set_blocking(fd int, blocking bool)`: Configures socket blocking mode (internal)

**Constants:**
- `max_connection_size = 1024`: Listen queue size

---

#### `request.v`
HTTP request reading from client sockets.

**Exports:**
- `read_request(client_fd int) ![]u8`: Reads complete HTTP request
  - Returns error if recv fails or client closes connection
  - Handles partial reads in non-blocking mode
  - 140-byte buffer chunks for efficient memory usage

**Error Cases:**
- `recv failed`: System error during read
- `client closed connection`: EOF received
- `empty request`: No data read

---

#### `response.v`
HTTP response transmission utilities.

**Exports:**
- `send_response(fd int, buffer_ptr &u8, buffer_len int) !`: Sends response buffer
  - Uses `MSG_NOSIGNAL | MSG_ZEROCOPY` for performance
  - Returns error on send failure
- `send_bad_request_response(fd int)`: Sends HTTP 400 response
- `send_status_444_response(fd int)`: Sends HTTP 444 (No Response)

**Constants:**
- `tiny_bad_request_response`: Minimal 400 response bytes
- `status_444_response`: Nginx-style connection close signal

---

## Usage Example

```v
import http_server

fn my_handler(request []u8, client_fd int) ![]u8 {
    // Parse request, generate response
    return 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!'.bytes()
}

mut server := http_server.Server{
    port: 8080
    request_handler: my_handler
}

server.run() // Blocks until shutdown
```

## Performance Characteristics

- **Connection Handling**: O(1) epoll operations per event
- **Memory**: 140-byte buffers per active read operation
- **Concurrency**: N worker threads (N = CPU cores)
- **Load Balancing**: Round-robin accept distribution

## Platform Support

- **Linux**: Full support via epoll
- **Windows**: Not supported (use WSL)
- **macOS**: Not supported (epoll unavailable)

## Thread Safety

- Each worker thread has isolated epoll instance
- No shared mutable state between workers
- Request handler must be thread-safe (receives immutable request slice)

## Error Handling

Connection errors trigger automatic cleanup:
1. Remove fd from epoll
2. Close socket
3. Continue processing remaining events

Request/response errors are logged but don't crash the server.
