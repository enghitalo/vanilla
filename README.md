<img src="./logo.png" alt="vanilla Logo" width="100">

# HTTP Server

## Features

- **Fast**: Multi-threaded, non-blocking I/O, lock-free, copy-free, I/O multiplexing, SO_REUSEPORT (native load balancing on Linux)
- **Modular**: Easy to extend with custom controllers and handlers.
- **Memory Safety**: No race conditions.
- **No Magic**: Transparent and straightforward.
- **E2E Testing**: Allows end-to-end testing and scripting without running the server. Pass raw requests to `handle_request()`.
- **SSE Friendly**: Built-in Server-Sent Events support.
- **ETag Friendly**: Conditional GETs with ETag and `If-None-Match` headers.
- **Database Friendly**: Example with PostgreSQL connection pool.
- **Graceful Shutdown**: Automatic shutdown after test mode or on signal (W.I.P.).
- **Multiple Backends**: epoll, io_uring, kqueue (platform-dependent).

---

## Usage Examples

### 1. Simple HTTP Server

```v
import http_server

fn handle_request(req_buffer []u8, client_conn_fd int) ![]u8 {
  // ...parse request and return response...
}

fn main() {
  mut server := http_server.new_server(http_server.ServerConfig{
    port: 3000
    request_handler: handle_request
    io_multiplexing: $if linux {
			.epoll
		} $else $if darwin {
			.kqueue
		} $else {
			.iocp
		}
  })
  server.run()
}
```

### 2. End-to-End Testing

```v
fn test_simple_without_init_the_server() {
  request := 'GET / HTTP/1.1\r\n\r\n'.bytes()
  assert handle_request(request, -1)! == http_ok_response
}
```

Or use the server’s test mode:

```v
mut server := http_server.new_server(http_server.ServerConfig{ ... })
responses := server.test([request1, request2]) or { panic(err) }
```

### 3. Server-Sent Events (SSE)

**Server:**

```sh
v -prod run examples/sse
```

**Front-end:**

```html
<script>
  const eventSource = new EventSource("http://localhost:3001/sse");
  eventSource.onmessage = function (event) {
    document.body.innerHTML += `<p>${event.data}</p>`;
  };
</script>
```

**Send notification:**

```sh
curl -X POST http://localhost:3001/notification
```

### 4. ETag Support

```sh
curl -v http://localhost:3001/user/1
curl -v -H "If-None-Match: c4ca4238a0b923820dcc509a6f75849b" http://localhost:3001/user/1
```

### 5. Database Example (PostgreSQL)

**Start database:**

```sh
docker-compose -f examples/database/docker-compose.yml up -d
```

**Run server:**

```sh
v -prod run examples/database
```

**Example handler:**

```v
fn handle_request(req_buffer []u8, client_conn_fd int, mut pool ConnectionPool) ![]u8 {
  // Use pool.acquire() and pool.release() for DB access
}
```

---

## Benchmarking

- use `-d force_keep_alive` to make sure that client will not be "blocked" by having to create a new connection at each request

```sh
wrk -t16 -c512 -d30s http://localhost:3001
wrk -t16 -c512 -d30s -H "If-None-Match: c4ca4238a0b923820dcc509a6f75849b" http://localhost:3001/user/1
```

---

## More Examples

- `examples/simple/` – Basic CRUD
- `examples/etag/` – ETag and conditional requests
- `examples/sse/` – Server-Sent Events
- `examples/database/` – PostgreSQL integration
- `examples/hexagonal/` – Hexagonal architecture

---

## Test Mode

The `Server` provides a test method that accepts an array of raw HTTP requests, sends them directly to the socket, and processes each one sequentially. After receiving the response for the last request, the loop ends and the server shuts down automatically. This enables efficient end-to-end testing without running a persistent server process longer that needed.

## Installation

### From Root Directory

1. Create the required directories:

```bash
mkdir -p ~/.vmodules/enghitalo/vanilla
```

2. Copy the `vanilla` directory to the target location:

```bash
cp -r ./ ~/.vmodules/enghitalo/vanilla
```

3. Run the example:

```bash
v -prod crun examples/simple
```

This sets up the module in your `~/.vmodules` directory for use.

### From Repository

Install directly from the repository:

```bash
v install https://github.com/enghitalo/vanilla
```

## Benchmarking

- use `-d force_keep_alive` to make sure that client will not be "blocked" by having to create a new connection at each request

Run the following commands to benchmark the server:

1. Test with `curl`:

```bash
curl -v http://localhost:3001
```

2. Test with `wrk`:

```bash
wrk -H 'Connection: "keep-alive"' --connection 512 --threads 16 --duration 60s http://localhost:3001
```

Example output:

```plaintext
Running 1m test @ http://localhost:3001
  16 threads and 512 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
   Latency     1.25ms    1.46ms  35.70ms   84.67%
   Req/Sec    32.08k     2.47k   57.85k    71.47%
  30662010 requests in 1.00m, 2.68GB read
Requests/sec: 510197.97
Transfer/sec:     45.74MB
```
