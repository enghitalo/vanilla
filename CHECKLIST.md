# Vanilla HTTP Server - Improvement Checklist

> Comprehensive roadmap of improvements, features, and implementations
>
> **Last Updated:** 2026-02-10
> **Project:** Vanilla HTTP Server v0.0.1

---

## 📋 Table of Contents

1. [Critical Bugs](#-critical-bugs-must-fix)
2. [Foundation Improvements](#-foundation-improvements-enables-everything)
3. [HTTP Protocol Features](#-http-protocol-features)
4. [TLS/HTTPS Support](#-tlshttps-support)
5. [Backend Improvements](#-backend-improvements)
6. [Code Quality & Safety](#-code-quality--safety)
7. [Performance Optimizations](#-performance-optimizations)
8. [Example Applications](#-example-applications-priority)
9. [Testing & Validation](#-testing--validation)
10. [Documentation](#-documentation)

---

## 🔴 Critical Bugs (MUST FIX)

### 1. Undefined Function `vmemcmp`
- **File:** `http_server/http1_1/request_parser/request_parser.v:203`
- **Issue:** Function `vmemcmp` is not defined, should be `C.memcmp`
- **Impact:** Header parsing will fail at runtime
- **Priority:** 🔴 CRITICAL
- **Effort:** 5 minutes
- **Strategy:**
  ```v
  // REPLACE:
  if unsafe { vmemcmp(&req.buffer[pos], name.str, name.len) } != 0

  // WITH:
  if unsafe { C.memcmp(&req.buffer[pos], name.str, name.len) } != 0
  ```
- **Testing:** Run existing request parser tests after fix

### 2. ✅ Incomplete Dynamic Route Matching [COMPLETED]
- **File:** `examples/veb_like/main.v:108-109`
- **Issue:** Dynamic route parsing has TODO, never extracts parameters
- **Impact:** Path parameters like `:id` don't work
- **Priority:** 🔴 HIGH
- **Effort:** 1-2 hours
- **Status:** ✅ **COMPLETED** (2026-02-10)
- **Implementation:**
  - ✅ Implemented `match_route_and_extract_params()` function
  - ✅ Segment-by-segment matching with parameter extraction
  - ✅ Zero-copy parameter storage using Slice structs
  - ✅ Query string handling (excluded from matching)
  - ✅ Method validation
  - ✅ Comprehensive test suite (6 tests, 14 assertions)
- **Testing:** All tests pass ✅
  - Static routes: `GET /users`, `POST /users`
  - Single parameter: `/users/:id/get`
  - Multiple parameters: `/users/:id/posts/:post_id`
  - 404 handling, query strings, method validation

### 3. Windows IOCP Overlapped Structure
- **File:** `http_server/http_server_windows.c.v`
- **Issue:** `h_event` in OVERLAPPED structure never initialized
- **Impact:** Undefined behavior on Windows async operations
- **Priority:** 🟡 MEDIUM (Windows only)
- **Effort:** 30 minutes
- **Strategy:**
  ```v
  // Create event handle properly:
  overlapped := C.OVERLAPPED{
      h_event: C.CreateEventA(0, 0, 0, 0)
  }
  // Clean up event on connection close:
  C.CloseHandle(overlapped.h_event)
  ```
- **Testing:** Test on Windows with multiple concurrent connections

### 4. Empty Kqueue Write Callback
- **File:** `http_server/kqueue/kqueue_darwin.c.v:114`
- **Issue:** Write callback is empty `fn (_ int) {}`
- **Impact:** Write events registered but never handled
- **Priority:** 🟡 MEDIUM (macOS only)
- **Effort:** 1 hour
- **Strategy:**
  1. Implement write handling similar to epoll
  2. Handle partial sends
  3. Remove kevent filter when write complete
  ```v
  callbacks.on_write: fn [request_handler] (fd int) {
      // Send pending response data
      // Remove EV_WRITE filter when done
  }
  ```
- **Testing:** Test large responses on macOS

---

## 🏗️ Foundation Improvements (ENABLES EVERYTHING)

### 5. Implement Query String Parsing
- **File:** `http_server/http1_1/request_parser/request_parser.v:234-237`
- **Issue:** `get_query()` returns empty Slice
- **Impact:** Cannot parse URL query parameters
- **Priority:** 🔴 HIGH
- **Effort:** 2 hours
- **Strategy:**
  ```v
  pub fn (req HttpRequest) get_query(key string) ?Slice {
      // 1. Find '?' in path
      path_start := &req.buffer[req.path.start]
      question_mark_pos := find_byte(path_start, req.path.len, question_mark_u8) or {
          return none
      }

      // 2. Parse query string after '?'
      query_start := req.path.start + question_mark_pos + 1
      query_len := req.path.len - question_mark_pos - 1

      // 3. Split by '&' and find key=value pairs
      // 4. Return Slice for the value

      // Handle cases: key=value, key=, key (no value)
  }
  ```
- **Dependencies:** None
- **Testing:** Test with `?foo=bar&baz=qux`, `?empty=`, `?novalue`

### 6. Add Standard HTTP Status Codes
- **File:** `http_server/http1_1/response/response.c.v`
- **Issue:** Only 400 and 444 status codes exist
- **Impact:** Cannot send proper status responses
- **Priority:** 🔴 HIGH
- **Effort:** 15 minutes
- **Strategy:**
  ```v
  // Add constants for all common status codes
  pub const http_200_ok = 'HTTP/1.1 200 OK\r\n'
  pub const http_201_created = 'HTTP/1.1 201 Created\r\n'
  pub const http_204_no_content = 'HTTP/1.1 204 No Content\r\n'
  pub const http_301_moved = 'HTTP/1.1 301 Moved Permanently\r\n'
  pub const http_302_found = 'HTTP/1.1 302 Found\r\n'
  pub const http_304_not_modified = 'HTTP/1.1 304 Not Modified\r\n'
  pub const http_400_bad_request = 'HTTP/1.1 400 Bad Request\r\n'
  pub const http_401_unauthorized = 'HTTP/1.1 401 Unauthorized\r\n'
  pub const http_403_forbidden = 'HTTP/1.1 403 Forbidden\r\n'
  pub const http_404_not_found = 'HTTP/1.1 404 Not Found\r\n'
  pub const http_405_method_not_allowed = 'HTTP/1.1 405 Method Not Allowed\r\n'
  pub const http_429_too_many_requests = 'HTTP/1.1 429 Too Many Requests\r\n'
  pub const http_500_internal_error = 'HTTP/1.1 500 Internal Server Error\r\n'
  pub const http_503_service_unavailable = 'HTTP/1.1 503 Service Unavailable\r\n'
  ```
- **Dependencies:** None
- **Testing:** Use in examples and verify with curl -v

### 7. Build Response Helper Function
- **File:** `http_server/http1_1/response/response.c.v`
- **Issue:** No standardized way to build responses
- **Impact:** Each example builds responses differently
- **Priority:** 🔴 HIGH
- **Effort:** 30 minutes
- **Strategy:**
  ```v
  pub fn build_response(status string, content_type string, body []u8) []u8 {
      date := time.now().http_header_string()
      headers := '${status}Date: ${date}\r\nServer: Vanilla/0.0.1\r\nContent-Type: ${content_type}\r\nContent-Length: ${body.len}\r\n\r\n'
      return headers.bytes() + body
  }

  // Optional: Builder pattern for complex responses
  pub struct ResponseBuilder {
  mut:
      status string
      headers map[string]string
      body []u8
  }

  pub fn (mut rb ResponseBuilder) add_header(key string, value string) &ResponseBuilder {
      rb.headers[key] = value
      return rb
  }

  pub fn (rb ResponseBuilder) build() []u8 {
      // Construct response with all headers
  }
  ```
- **Dependencies:** #6 (status codes)
- **Testing:** Build various response types

### 8. Header Injection Utility
- **File:** `http_server/http1_1/response/response.c.v`
- **Issue:** No way to add headers to existing responses (needed for middleware)
- **Impact:** Cannot implement middleware that adds headers
- **Priority:** 🔴 HIGH
- **Effort:** 45 minutes
- **Strategy:**
  ```v
  pub fn inject_headers(response []u8, additional_headers []u8) []u8 {
      // Find end of status line (first \r\n)
      status_end := find_sequence(&response[0], response.len, crlf.data, 2) or {
          return response // Malformed response, return as-is
      }

      // Insert headers after status line
      mut result := []u8{cap: response.len + additional_headers.len}
      result << response[..status_end + 2]
      result << additional_headers
      result << response[status_end + 2..]
      return result
  }

  // Alternative: inject before final \r\n\r\n
  pub fn inject_headers_before_body(response []u8, headers []u8) []u8 {
      // Find \r\n\r\n
      // Insert before it
  }
  ```
- **Dependencies:** None
- **Testing:** Test with existing response, verify headers are inserted correctly

---

## 🌐 HTTP Protocol Features

### 9. HTTP Method Validation
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** Any method string is accepted
- **Impact:** Server accepts invalid methods
- **Priority:** 🟡 MEDIUM
- **Effort:** 30 minutes
- **Strategy:**
  ```v
  const valid_methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS', 'TRACE', 'CONNECT']

  pub fn validate_method(method_slice Slice, buffer []u8) !string {
      method_str := method_slice.to_string(buffer)
      if method_str !in valid_methods {
          return error('Invalid HTTP method: ${method_str}')
      }
      return method_str
  }
  ```
- **Dependencies:** None
- **Testing:** Test with valid and invalid methods

### 10. HTTP/1.1 Host Header Requirement
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** Host header not validated (required by RFC 9112 for HTTP/1.1)
- **Impact:** Non-compliant with HTTP/1.1 spec
- **Priority:** 🟡 MEDIUM
- **Effort:** 20 minutes
- **Strategy:**
  ```v
  pub fn validate_http11_request(req HttpRequest) ! {
      // Check if HTTP/1.1
      version := req.version.to_string(req.buffer)
      if version == 'HTTP/1.1' {
          // Require Host header
          host := req.get_header_value_slice('Host') or {
              return error('HTTP/1.1 requests must include Host header')
          }
      }
  }
  ```
- **Dependencies:** None
- **Testing:** Test with and without Host header

### 11. Case-Insensitive Header Names
- **File:** `http_server/http1_1/request_parser/request_parser.v:189-232`
- **Issue:** Header matching is case-sensitive
- **Impact:** Headers like "content-type" vs "Content-Type" fail to match
- **Priority:** 🟡 MEDIUM
- **Effort:** 1 hour
- **Strategy:**
  ```v
  // Option 1: Convert to lowercase during comparison
  pub fn (req HttpRequest) get_header_value_slice(name string) ?Slice {
      name_lower := name.to_lower()
      // Compare with lowercase
  }

  // Option 2: Use case-insensitive memcmp
  fn C.strncasecmp(s1 &char, s2 &char, n usize) int

  // Replace C.memcmp with C.strncasecmp
  ```
- **Dependencies:** None
- **Testing:** Test with various case combinations

### 12. Content-Length Validation
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** No validation that body matches Content-Length
- **Impact:** Can accept malformed requests
- **Priority:** 🟡 MEDIUM
- **Effort:** 45 minutes
- **Strategy:**
  ```v
  pub fn validate_content_length(req HttpRequest) ! {
      if content_len_slice := req.get_header_value_slice('Content-Length') {
          declared_len := content_len_slice.to_string(req.buffer).int()
          actual_len := req.body.len

          if declared_len != actual_len {
              return error('Content-Length (${declared_len}) does not match body size (${actual_len})')
          }
      }
  }
  ```
- **Dependencies:** None
- **Testing:** Test with matching and mismatched Content-Length

### 13. Cookie Parsing
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** No helper to parse Cookie header
- **Impact:** Cannot easily access cookies
- **Priority:** 🟢 LOW
- **Effort:** 1 hour
- **Strategy:**
  ```v
  pub fn (req HttpRequest) get_cookie(name string) ?string {
      cookie_header := req.get_header_value_slice('Cookie') or { return none }
      cookie_str := cookie_header.to_string(req.buffer)

      // Parse: "name1=value1; name2=value2"
      pairs := cookie_str.split('; ')
      for pair in pairs {
          parts := pair.split('=')
          if parts.len == 2 && parts[0] == name {
              return parts[1]
          }
      }
      return none
  }
  ```
- **Dependencies:** None
- **Testing:** Test with multiple cookies

### 14. Transfer-Encoding: chunked Support
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** Chunked encoding not supported
- **Impact:** Cannot handle chunked request bodies
- **Priority:** 🟢 LOW
- **Effort:** 3-4 hours
- **Strategy:**
  ```v
  // Detect chunked encoding
  if te_header := req.get_header_value_slice('Transfer-Encoding') {
      if te_header.to_string(req.buffer) == 'chunked' {
          // Parse chunks: size\r\ndata\r\n...0\r\n\r\n
          // Reassemble body
      }
  }
  ```
- **Dependencies:** None
- **Testing:** Test with chunked POST requests

---

## 🔒 TLS/HTTPS Support

### 15. Complete V TLS Bindings
- **File:** `http_server/tls/tls.v`
- **Issue:** Only C includes, no implementation
- **Impact:** Cannot use HTTPS
- **Priority:** 🔴 HIGH (for HTTPS example)
- **Effort:** 3-4 hours
- **Strategy:**
  1. **Define C structs and functions** (from `TLS/server.c`):
     ```v
     struct C.mbedtls_ssl_context {}
     struct C.mbedtls_ssl_config {}
     struct C.mbedtls_x509_crt {}
     struct C.mbedtls_pk_context {}
     struct C.mbedtls_net_context {}
     struct C.psa_key_attributes_t {}

     fn C.psa_crypto_init() int
     fn C.psa_generate_key(&C.psa_key_attributes_t, &u64) int
     fn C.mbedtls_ssl_init(&C.mbedtls_ssl_context)
     fn C.mbedtls_ssl_setup(&C.mbedtls_ssl_context, &C.mbedtls_ssl_config) int
     fn C.mbedtls_ssl_config_defaults(&C.mbedtls_ssl_config, int, int, int) int
     fn C.mbedtls_ssl_conf_own_cert(&C.mbedtls_ssl_config, &C.mbedtls_x509_crt, &C.mbedtls_pk_context) int
     fn C.mbedtls_ssl_handshake(&C.mbedtls_ssl_context) int
     fn C.mbedtls_ssl_read(&C.mbedtls_ssl_context, &u8, usize) int
     fn C.mbedtls_ssl_write(&C.mbedtls_ssl_context, &u8, usize) int
     fn C.mbedtls_ssl_close_notify(&C.mbedtls_ssl_context) int
     fn C.mbedtls_ssl_free(&C.mbedtls_ssl_context)
     fn C.mbedtls_x509_crt_init(&C.mbedtls_x509_crt)
     fn C.mbedtls_x509_crt_parse(&C.mbedtls_x509_crt, &u8, usize) int
     fn C.mbedtls_pk_init(&C.mbedtls_pk_context)
     fn C.mbedtls_pk_parse_key(&C.mbedtls_pk_context, &u8, usize, &u8, usize) int
     ```

  2. **Create V wrapper struct**:
     ```v
     pub struct TLSContext {
     mut:
         ssl_ctx C.mbedtls_ssl_context
         config  C.mbedtls_ssl_config
         cert    C.mbedtls_x509_crt
         pkey    C.mbedtls_pk_context
         key_id  u64
     }
     ```

  3. **Implement initialization**:
     ```v
     pub fn init_tls() ! {
         ret := C.psa_crypto_init()
         if ret != 0 {
             return error('Failed to initialize PSA crypto: ${ret}')
         }
     }
     ```

  4. **Implement server setup**:
     ```v
     pub fn (mut ctx TLSContext) setup_server(cert_pem []u8, key_pem []u8) ! {
         C.mbedtls_ssl_config_init(&ctx.config)
         C.mbedtls_x509_crt_init(&ctx.cert)
         C.mbedtls_pk_init(&ctx.pkey)

         // Parse certificate
         ret := C.mbedtls_x509_crt_parse(&ctx.cert, cert_pem.data, cert_pem.len)
         if ret != 0 { return error('Failed to parse cert: ${ret}') }

         // Parse private key
         ret2 := C.mbedtls_pk_parse_key(&ctx.pkey, key_pem.data, key_pem.len, 0, 0)
         if ret2 != 0 { return error('Failed to parse key: ${ret2}') }

         // Configure SSL
         C.mbedtls_ssl_config_defaults(&ctx.config,
             C.MBEDTLS_SSL_IS_SERVER,
             C.MBEDTLS_SSL_TRANSPORT_STREAM,
             C.MBEDTLS_SSL_PRESET_DEFAULT)

         C.mbedtls_ssl_conf_own_cert(&ctx.config, &ctx.cert, &ctx.pkey)
     }
     ```

  5. **Implement per-connection TLS**:
     ```v
     pub fn (mut ctx TLSContext) accept_tls(client_fd int) ! {
         C.mbedtls_ssl_init(&ctx.ssl_ctx)
         C.mbedtls_ssl_setup(&ctx.ssl_ctx, &ctx.config)
         C.mbedtls_ssl_set_bio(&ctx.ssl_ctx, client_fd, C.mbedtls_net_send, C.mbedtls_net_recv, 0)

         // Perform handshake
         for {
             ret := C.mbedtls_ssl_handshake(&ctx.ssl_ctx)
             if ret == 0 { break }
             if ret != C.MBEDTLS_ERR_SSL_WANT_READ && ret != C.MBEDTLS_ERR_SSL_WANT_WRITE {
                 return error('TLS handshake failed: ${ret}')
             }
         }
     }
     ```

  6. **Implement read/write**:
     ```v
     pub fn (mut ctx TLSContext) read_tls(buf &u8, len int) !int {
         ret := C.mbedtls_ssl_read(&ctx.ssl_ctx, buf, len)
         if ret < 0 && ret != C.MBEDTLS_ERR_SSL_WANT_READ {
             return error('TLS read failed: ${ret}')
         }
         return ret
     }

     pub fn (mut ctx TLSContext) write_tls(buf &u8, len int) !int {
         ret := C.mbedtls_ssl_write(&ctx.ssl_ctx, buf, len)
         if ret < 0 && ret != C.MBEDTLS_ERR_SSL_WANT_WRITE {
             return error('TLS write failed: ${ret}')
         }
         return ret
     }
     ```

- **Dependencies:** mbedtls installed (already done)
- **Testing:** Create simple HTTPS server, test with curl --cacert

### 16. Integrate TLS into Request/Response Handlers
- **Files:** `http_server/http1_1/request/request.c.v`, `http_server/http1_1/response/response.c.v`
- **Issue:** No TLS-aware read/write functions
- **Impact:** Cannot use TLS with existing infrastructure
- **Priority:** 🔴 HIGH
- **Effort:** 1 hour
- **Strategy:**
  ```v
  // In request.c.v
  pub fn read_request_tls(mut tls_ctx tls.TLSContext, client_fd int) ![]u8 {
      mut request_buffer := []u8{}
      mut temp_buffer := [4096]u8{}

      for {
          bytes_read := tls_ctx.read_tls(&temp_buffer[0], temp_buffer.len) or { break }
          if bytes_read <= 0 { break }
          unsafe { request_buffer.push_many(&temp_buffer[0], bytes_read) }
          if bytes_read < temp_buffer.len { break }
      }
      return request_buffer
  }

  // In response.c.v
  pub fn send_response_tls(mut tls_ctx tls.TLSContext, buffer_ptr &u8, buffer_len int) ! {
      mut sent := 0
      for sent < buffer_len {
          n := tls_ctx.write_tls(buffer_ptr + sent, buffer_len - sent)!
          sent += n
      }
  }
  ```
- **Dependencies:** #15 (TLS bindings)
- **Testing:** Test with HTTPS requests

### 17. Self-Signed Certificate Generation
- **File:** `http_server/tls/tls_cert/tls_cert.v`
- **Issue:** No certificate generation in V
- **Impact:** Must manually create certificates for testing
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  - Translate certificate generation from `TLS/server.c:78-181`
  - Use PSA crypto API for key generation
  - Generate X.509v3 certificate with CN=localhost
  - Save as PEM file
- **Dependencies:** #15 (TLS bindings)
- **Testing:** Generate cert, verify with openssl x509 -in cert.pem -text

---

## ⚙️ Backend Improvements

### 18. Implement Keep-Alive in Epoll Backend
- **File:** `http_server/http_server_epoll_linux.c.v`
- **Issue:** Closes connection after each request
- **Impact:** High overhead for multiple requests
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  1. Parse Connection header
  2. If "keep-alive" or HTTP/1.1 default:
     - Don't close socket after response
     - Re-register EPOLLIN for next request
     - Track connection state
  3. If "close" or timeout:
     - Close socket and cleanup
  ```v
  // After send response:
  if should_keep_alive(req) && !timeout_exceeded(conn) {
      // Re-register for reading
      C.epoll_ctl(epoll_fd, C.EPOLL_CTL_MOD, client_fd, &event)
  } else {
      C.close(client_fd)
  }
  ```
- **Dependencies:** None
- **Testing:** Send multiple requests on same connection

### 19. Implement Keep-Alive in Kqueue Backend
- **File:** `http_server/http_server_darwin.c.v`
- **Issue:** Closes connection after each request
- **Impact:** High overhead on macOS
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  - Same as epoll, but use kqueue API
  - Keep EVFILT_READ registered
  - Track connection state
- **Dependencies:** #4 (fix write callback)
- **Testing:** Test on macOS with persistent connections

### 20. Complete IOCP Keep-Alive Implementation
- **File:** `http_server/http_server_windows.c.v`
- **Issue:** Partial keep-alive implementation
- **Impact:** Windows performance degraded
- **Priority:** 🟡 MEDIUM
- **Effort:** 3 hours
- **Strategy:**
  - Track connection state in IOCP context
  - Re-post WSARecv after response
  - Handle connection timeouts
  - Proper cleanup of OVERLAPPED structures
- **Dependencies:** #3 (fix overlapped)
- **Testing:** Test on Windows with concurrent persistent connections

### 21. Add Timeout Support to Event Loops
- **Files:** All backend files
- **Issue:** Infinite waits in epoll_wait/kevent/etc
- **Impact:** Connections can hang forever
- **Priority:** 🟡 MEDIUM
- **Effort:** 1 hour
- **Strategy:**
  ```v
  // Epoll: Replace -1 with timeout
  num_events := C.epoll_wait(epoll_fd, &events[0], max_events, 5000) // 5 second timeout

  // Kqueue: Set timeout struct
  timeout := C.timespec{
      tv_sec: 5
      tv_nsec: 0
  }
  num_events := C.kevent(kq, 0, 0, &events[0], max_events, &timeout)

  // Check for stale connections on timeout
  cleanup_stale_connections()
  ```
- **Dependencies:** None
- **Testing:** Test connection timeout behavior

### 22. Validate File Descriptors Before Operations
- **Files:** All backend files
- **Issue:** No validation that fd > 0 before socket operations
- **Impact:** Can crash on invalid fd
- **Priority:** 🟡 MEDIUM
- **Effort:** 30 minutes
- **Strategy:**
  ```v
  @[inline]
  fn validate_fd(fd int) ! {
      if fd < 0 {
          return error('Invalid file descriptor: ${fd}')
      }
  }

  // Use before every socket operation
  validate_fd(client_fd)!
  C.send(client_fd, ...)
  ```
- **Dependencies:** None
- **Testing:** Test with closed fd, invalid fd

### 23. Handle Partial Send/Recv
- **Files:** All backend files
- **Issue:** Assumes full send/recv in single call
- **Impact:** Can lose data or hang
- **Priority:** 🟡 MEDIUM
- **Effort:** 1 hour per backend
- **Strategy:**
  ```v
  // For send:
  fn send_all(fd int, buf &u8, len int) ! {
      mut total_sent := 0
      for total_sent < len {
          sent := C.send(fd, buf + total_sent, len - total_sent, 0)
          if sent < 0 {
              if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
                  continue // Non-blocking, try again
              }
              return error('send failed: ${C.errno}')
          }
          if sent == 0 {
              return error('connection closed')
          }
          total_sent += sent
      }
  }

  // For recv: similar approach
  ```
- **Dependencies:** None
- **Testing:** Test with large responses

---

## 🛡️ Code Quality & Safety

### 24. Reduce Unsafe Blocks
- **Files:** Multiple files (94 unsafe blocks total)
- **Issue:** Heavy use of unsafe pointer arithmetic
- **Impact:** Memory safety concerns
- **Priority:** 🟢 LOW (refactoring)
- **Effort:** 4-6 hours
- **Strategy:**
  1. **Replace pointer arithmetic with V arrays**:
     ```v
     // BEFORE:
     unsafe { buf + offset }

     // AFTER:
     buf[offset..]
     ```

  2. **Use V string methods instead of C functions**:
     ```v
     // BEFORE:
     unsafe { C.memcmp(a, b, len) }

     // AFTER:
     a[..len] == b[..len]
     ```

  3. **Use bounds-checked slicing**:
     ```v
     // BEFORE:
     unsafe { buffer[start..end] }

     // AFTER:
     if start < buffer.len && end <= buffer.len {
         buffer[start..end]
     }
     ```

- **Dependencies:** None
- **Testing:** Run all tests after each refactoring

### 25. Add Bounds Checking in Parsers
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** Some loops lack bounds checks
- **Impact:** Buffer overflow risk
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  ```v
  // Before accessing buffer[pos]:
  if pos >= buffer.len {
      return error('buffer overflow')
  }

  // For loops:
  for pos < buffer.len {
      // Safe access to buffer[pos]
  }
  ```
- **Dependencies:** None
- **Testing:** Test with malformed/truncated requests

### 26. Consistent Error Handling
- **Files:** Multiple files
- **Issue:** Mix of error strings, error(), return codes
- **Impact:** Hard to debug and handle errors
- **Priority:** 🟢 LOW
- **Effort:** 3 hours
- **Strategy:**
  1. Always use `!` for functions that can fail
  2. Always return detailed error messages with context
  3. Use `or { }` blocks consistently
  ```v
  // Consistent pattern:
  fn operation() ! {
      result := some_call() or {
          return error('operation failed at step X: ${err}')
      }
  }
  ```
- **Dependencies:** None
- **Testing:** Check error messages are helpful

### 27. Replace Magic Numbers with Constants
- **Files:** Multiple files
- **Issue:** Hardcoded values like 4096, 140, 1024
- **Impact:** Hard to maintain and tune
- **Priority:** 🟢 LOW
- **Effort:** 1 hour
- **Strategy:**
  ```v
  // In a config or constants file:
  pub const default_buffer_size = 4096
  pub const max_header_size = 8192
  pub const max_request_size = 1024 * 1024
  pub const socket_timeout_ms = 5000
  pub const max_connections = 1024

  // Use throughout codebase
  mut buffer := [default_buffer_size]u8{}
  ```
- **Dependencies:** None
- **Testing:** Ensure behavior unchanged

### 28. Remove Dead Code
- **Files:** `examples/veb_like/main.v:40-70`, others
- **Issue:** Large commented-out blocks
- **Impact:** Code clutter
- **Priority:** 🟢 LOW
- **Effort:** 30 minutes
- **Strategy:**
  - Remove all commented-out code
  - Use git history if needed to recover
  - Keep only relevant comments
- **Dependencies:** None
- **Testing:** Ensure nothing breaks

---

## ⚡ Performance Optimizations

### 29. Pre-allocate Response Buffers
- **Files:** Response building code
- **Issue:** Dynamic allocation per response
- **Impact:** Allocation overhead
- **Priority:** 🟢 LOW
- **Effort:** 2 hours
- **Strategy:**
  ```v
  // Buffer pool per thread
  struct ResponseBufferPool {
  mut:
      buffers [][]u8
      in_use  []bool
  }

  fn (mut pool ResponseBufferPool) acquire() []u8 {
      for i, used in pool.in_use {
          if !used {
              pool.in_use[i] = true
              return pool.buffers[i]
          }
      }
      // All in use, allocate new
      new_buf := []u8{cap: 8192}
      pool.buffers << new_buf
      pool.in_use << true
      return new_buf
  }
  ```
- **Dependencies:** None
- **Testing:** Benchmark before/after

### 30. Optimize Header Parsing with Lookup Table
- **File:** `http_server/http1_1/request_parser/request_parser.v`
- **Issue:** Linear search for headers
- **Impact:** Slow for common headers
- **Priority:** 🟢 LOW
- **Effort:** 2 hours
- **Strategy:**
  ```v
  // Build hash map of common headers during parsing
  struct FastHeaderMap {
  mut:
      content_length ?Slice
      content_type   ?Slice
      host           ?Slice
      user_agent     ?Slice
      // ... common headers
      other map[string]Slice
  }

  // O(1) access for common headers
  fn (req HttpRequest) get_content_length() ?Slice {
      return req.fast_headers.content_length
  }
  ```
- **Dependencies:** None
- **Testing:** Benchmark header access

### 31. Add Fast Path for Common Routes
- **Files:** Example handlers
- **Issue:** Every request goes through full routing
- **Impact:** Overhead for simple routes
- **Priority:** 🟢 LOW
- **Effort:** 1 hour
- **Strategy:**
  ```v
  fn handle_request_optimized(req []u8, fd int) ![]u8 {
      parsed := request_parser.decode_http_request(req)!
      path := parsed.path.to_string(parsed.buffer)

      // Fast path for exact matches
      match path {
          '/' { return home_handler() }
          '/health' { return health_handler() }
          '/metrics' { return metrics_handler() }
          else {
              // Fall back to full routing
              return full_router(parsed, fd)
          }
      }
  }
  ```
- **Dependencies:** None
- **Testing:** Benchmark common vs uncommon routes

### 32. Response Caching
- **Files:** New caching module
- **Issue:** No caching for static responses
- **Impact:** Regenerate same responses repeatedly
- **Priority:** 🟢 LOW
- **Effort:** 2 hours
- **Strategy:**
  ```v
  struct ResponseCache {
  mut:
      cache map[string]CachedResponse
      mutex sync.Mutex
  }

  struct CachedResponse {
      data []u8
      created_at i64
      ttl_seconds int
  }

  fn (mut rc ResponseCache) get(key string) ?[]u8 {
      rc.mutex.@lock()
      defer { rc.mutex.unlock() }

      if cached := rc.cache[key] {
          if time.now().unix() - cached.created_at < cached.ttl_seconds {
              return cached.data
          }
      }
      return none
  }
  ```
- **Dependencies:** None
- **Testing:** Test cache hits/misses, TTL expiration

---

## 📚 Example Applications (PRIORITY)

### 33. Static File Server Example
- **Directory:** `examples/static_files/`
- **Features:**
  - Serve files from public directory
  - MIME type detection
  - ETag support with 304 responses
  - Range requests (206 Partial Content)
  - Path traversal protection
  - Index.html serving
- **Priority:** 🔴 HIGH
- **Effort:** 3-4 hours
- **Strategy:**
  1. **Create directory structure**:
     ```
     examples/static_files/
     ├── public/
     │   ├── index.html
     │   ├── style.css
     │   ├── app.js
     │   └── images/
     │       └── logo.png
     ├── src/
     │   ├── main.v
     │   ├── file_server.v
     │   └── mime_types.v
     └── README.md
     ```

  2. **Implement MIME type detection** (`mime_types.v`):
     ```v
     pub const mime_types = {
         'html': 'text/html; charset=utf-8'
         'css': 'text/css'
         'js': 'application/javascript'
         'json': 'application/json'
         'png': 'image/png'
         'jpg': 'image/jpeg'
         'jpeg': 'image/jpeg'
         'gif': 'image/gif'
         'svg': 'image/svg+xml'
         'webp': 'image/webp'
         'ico': 'image/x-icon'
         'woff': 'font/woff'
         'woff2': 'font/woff2'
         'ttf': 'font/ttf'
         'pdf': 'application/pdf'
         'zip': 'application/zip'
         'txt': 'text/plain'
     }

     pub fn get_content_type(file_path string) string {
         ext := file_path.split('.').last()
         return mime_types[ext] or { 'application/octet-stream' }
     }
     ```

  3. **Implement path security** (`file_server.v`):
     ```v
     pub fn is_safe_path(requested_path string, root_dir string) bool {
         // Prevent directory traversal
         if requested_path.contains('..') || requested_path.contains('~') {
             return false
         }

         // Ensure path is within root
         real_path := os.real_path(os.join_path(root_dir, requested_path)) or { return false }
         real_root := os.real_path(root_dir) or { return false }

         return real_path.starts_with(real_root)
     }
     ```

  4. **Implement file serving** (`file_server.v`):
     ```v
     pub fn serve_file(requested_path string, root_dir string, req request_parser.HttpRequest) ![]u8 {
         // Security check
         if !is_safe_path(requested_path, root_dir) {
             return response.build_response(response.http_403_forbidden, 'text/plain', 'Forbidden'.bytes())
         }

         mut file_path := os.join_path(root_dir, requested_path)

         // Serve index.html for directories
         if os.is_dir(file_path) {
             file_path = os.join_path(file_path, 'index.html')
         }

         // Check if file exists
         if !os.exists(file_path) {
             return response.build_response(response.http_404_not_found, 'text/html', '<h1>404 Not Found</h1>'.bytes())
         }

         // Read file
         content := os.read_bytes(file_path)!

         // Generate ETag
         etag := generate_etag(content)

         // Check If-None-Match
         if client_etag_slice := req.get_header_value_slice('If-None-Match') {
             client_etag := client_etag_slice.to_string(req.buffer).trim_space()
             if client_etag == etag {
                 return response.build_response(response.http_304_not_modified, '', []u8{})
             }
         }

         // Build response
         content_type := get_content_type(file_path)
         mut resp := response.build_response(response.http_200_ok, content_type, content)

         // Add ETag header
         etag_header := 'ETag: "${etag}"\r\n'.bytes()
         resp = response.inject_headers(resp, etag_header)

         // Add Cache-Control
         cache_header := 'Cache-Control: public, max-age=3600\r\n'.bytes()
         resp = response.inject_headers(resp, cache_header)

         return resp
     }

     fn generate_etag(content []u8) string {
         // Use MD5 or FNV hash
         return crypto.md5.hexhash(content.bytestr())
     }
     ```

  5. **Create main handler** (`main.v`):
     ```v
     import http_server
     import http_server.http1_1.request_parser

     const public_dir = './public'

     fn handle_request(req_buffer []u8, client_fd int) ![]u8 {
         req := request_parser.decode_http_request(req_buffer)!

         method := req.method.to_string(req.buffer)
         path := req.path.to_string(req.buffer)

         // Only allow GET/HEAD
         if method !in ['GET', 'HEAD'] {
             return response.build_response(response.http_405_method_not_allowed, 'text/plain', 'Method Not Allowed'.bytes())
         }

         return serve_file(path, public_dir, req)
     }

     fn main() {
         println('Static file server running on http://localhost:3000')
         println('Serving files from: ${public_dir}')

         mut server := http_server.new_server(http_server.ServerConfig{
             port: 3000
             request_handler: handle_request
             io_multiplexing: $if linux { .epoll } $else $if darwin { .kqueue } $else { .iocp }
         })!

         server.run()
     }
     ```

- **Dependencies:** #6, #7, #8 (foundation helpers)
- **Testing:**
  ```bash
  # Create test files
  mkdir -p examples/static_files/public
  echo "<h1>Test</h1>" > examples/static_files/public/index.html

  # Run server
  v run examples/static_files

  # Test
  curl http://localhost:3000/
  curl -I http://localhost:3000/  # Check ETag
  curl -H "If-None-Match: <etag>" http://localhost:3000/  # Should get 304
  curl http://localhost:3000/../../../etc/passwd  # Should get 403
  ```

### 34. HTTPS Example
- **Directory:** `examples/https/`
- **Features:**
  - TLS 1.3 server
  - Self-signed certificate generation
  - Secure connection handling
- **Priority:** 🔴 HIGH
- **Effort:** 2-3 hours
- **Strategy:**
  1. **Create structure**:
     ```
     examples/https/
     ├── certs/
     │   ├── .gitkeep
     │   └── generate_certs.sh
     ├── src/
     │   └── main.v
     └── README.md
     ```

  2. **Create cert generation script** (`generate_certs.sh`):
     ```bash
     #!/bin/bash
     # Generate self-signed certificate for testing
     openssl req -x509 -newkey rsa:2048 -nodes \
       -keyout certs/server.key \
       -out certs/server.crt \
       -days 365 \
       -subj "/CN=localhost"
     ```

  3. **Implement HTTPS server** (`main.v`):
     ```v
     import http_server
     import http_server.tls
     import http_server.http1_1.request_parser
     import http_server.http1_1.response
     import os

     fn main() {
         // Initialize TLS
         tls.init_tls()!
         println('TLS initialized')

         // Load certificates
         cert_pem := os.read_bytes('certs/server.crt') or {
             eprintln('Failed to load certificate. Run: ./certs/generate_certs.sh')
             exit(1)
         }
         key_pem := os.read_bytes('certs/server.key') or {
             eprintln('Failed to load private key. Run: ./certs/generate_certs.sh')
             exit(1)
         }

         // Setup TLS context
         mut tls_ctx := tls.TLSContext{}
         tls_ctx.setup_server(cert_pem, key_pem)!
         println('TLS context configured')

         // Create server with TLS handler
         mut server := http_server.new_server(http_server.ServerConfig{
             port: 8443
             request_handler: fn [mut tls_ctx] (req_buffer []u8, client_fd int) ![]u8 {
                 return handle_https_request(req_buffer, client_fd, mut tls_ctx)
             }
         })!

         println('✅ HTTPS server running on https://localhost:8443')
         println('Test with: curl --cacert certs/server.crt https://localhost:8443')

         server.run()
     }

     fn handle_https_request(req_buffer []u8, client_fd int, mut tls_ctx tls.TLSContext) ![]u8 {
         // Perform TLS handshake
         tls_ctx.accept_tls(client_fd)!

         // Read encrypted request
         encrypted_req := tls.read_request_tls(mut tls_ctx, client_fd)!

         // Parse request
         req := request_parser.decode_http_request(encrypted_req)!

         // Build response
         body := '<html><body><h1>🔒 Secure Connection!</h1><p>This is served over TLS 1.3</p></body></html>'.bytes()
         resp := response.build_response(response.http_200_ok, 'text/html', body)

         // Send encrypted response
         tls.send_response_tls(mut tls_ctx, resp.data, resp.len)!

         return resp
     }
     ```

- **Dependencies:** #15, #16 (TLS implementation)
- **Testing:**
  ```bash
  cd examples/https
  ./certs/generate_certs.sh
  v run .
  curl --cacert certs/server.crt https://localhost:8443
  ```

### 35. Middleware Example
- **Directory:** `examples/middlewares/`
- **Features:**
  - Logging middleware
  - CORS middleware
  - Auth middleware (Bearer token)
  - Rate limiting middleware
  - Security headers middleware
  - Compression middleware
  - Request ID middleware
- **Priority:** 🔴 HIGH
- **Effort:** 4-5 hours
- **Strategy:**
  1. **Create structure**:
     ```
     examples/middlewares/
     ├── src/
     │   ├── main.v
     │   ├── logging_middleware.v
     │   ├── cors_middleware.v
     │   ├── auth_middleware.v
     │   ├── rate_limit_middleware.v
     │   ├── security_headers_middleware.v
     │   └── compression_middleware.v
     └── README.md
     ```

  2. **Define middleware type** (`main.v`):
     ```v
     type Handler = fn ([]u8, int) ![]u8
     type Middleware = fn (Handler) Handler

     // Chain middlewares
     fn chain_middlewares(handler Handler, middlewares ...Middleware) Handler {
         mut h := handler
         for middleware in middlewares {
             h = middleware(h)
         }
         return h
     }
     ```

  3. **Implement each middleware** (see individual files in strategy)

  4. **Usage example** (`main.v`):
     ```v
     fn main() {
         // Create middleware chain
         handler := chain_middlewares(
             app_handler,
             logging_middleware(),
             cors_middleware('*'),
             security_headers_middleware(),
             rate_limit_middleware(100, 60),
             auth_middleware(validate_token)
         )

         mut server := http_server.new_server(http_server.ServerConfig{
             port: 3000
             request_handler: handler
         })!

         server.run()
     }
     ```

- **Dependencies:** #8 (header injection)
- **Testing:** Test each middleware individually and combined

### 36. Logging Example
- **Directory:** `examples/logging/`
- **Features:**
  - File logging (rotating logs)
  - Structured logging (JSON)
  - Cloud logging (HTTP POST to external service)
  - Request/response logging
  - Performance metrics logging
- **Priority:** 🔴 HIGH
- **Effort:** 3-4 hours
- **Strategy:**
  1. **Implement file logger** (`file_logger.v`)
  2. **Implement cloud logger** (`cloud_logger.v`)
  3. **Implement structured logger** (`structured_logger.v`)
  4. **Create logging middleware**
  5. **Add log rotation**

- **Dependencies:** None
- **Testing:** Verify logs are written, test rotation

### 37. Security/Attack Protection Example
- **Directory:** `examples/security/`
- **Features:**
  - Request size limits
  - Slowloris protection (timeouts)
  - Path traversal protection
  - Header injection protection
  - SQL injection protection helpers
  - XSS protection headers
  - Rate limiting by IP
  - CSRF token validation
  - Input validation
- **Priority:** 🔴 HIGH
- **Effort:** 4-5 hours
- **Strategy:**
  1. **Implement security middleware** (`security_middleware.v`)
  2. **Implement validators** (`validators.v`)
  3. **Implement rate limiter** (`rate_limiter.v`)
  4. **Create attack tests** (`attack_test.v`)
  5. **Document best practices**

- **Dependencies:** #8 (header injection), #21 (timeouts)
- **Testing:** Test with malicious inputs, slowloris simulation

---

## 🧪 Testing & Validation

### 38. Request Parser Edge Case Tests
- **File:** `http_server/http1_1/request_parser/request_parser_test.v`
- **Issue:** Limited test coverage
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  ```v
  fn test_malformed_requests() {
      // Missing method
      assert decode_http_request('/ HTTP/1.1\r\n\r\n'.bytes()) or { return }

      // Missing path
      assert decode_http_request('GET HTTP/1.1\r\n\r\n'.bytes()) or { return }

      // Missing version
      assert decode_http_request('GET /\r\n\r\n'.bytes()) or { return }

      // Truncated request
      assert decode_http_request('GET / HT'.bytes()) or { return }

      // Empty request
      assert decode_http_request(''.bytes()) or { return }
  }

  fn test_http09_requests() {
      // HTTP/0.9 style
      req := decode_http_request('GET /\r\n'.bytes())!
      assert req.version.len == 0
  }

  fn test_large_headers() {
      // Headers larger than buffer
      big_header := 'X-Large: ' + 'a'.repeat(10000) + '\r\n'
      req := 'GET / HTTP/1.1\r\n${big_header}\r\n'.bytes()
      // Should handle or error gracefully
  }
  ```

### 39. Backend Stress Tests
- **Files:** New test files per backend
- **Issue:** No stress testing
- **Priority:** 🟡 MEDIUM
- **Effort:** 3 hours
- **Strategy:**
  ```v
  fn test_concurrent_connections() {
      // Spawn 1000 concurrent clients
      // Send requests simultaneously
      // Verify all get responses
  }

  fn test_keep_alive_many_requests() {
      // Single connection
      // Send 1000 requests sequentially
      // Verify connection stays open
  }

  fn test_connection_timeout() {
      // Connect but don't send data
      // Verify timeout and cleanup
  }
  ```

### 40. E2E Integration Tests
- **Directory:** `tests/integration/`
- **Issue:** No full integration tests
- **Priority:** 🟡 MEDIUM
- **Effort:** 4 hours
- **Strategy:**
  - Test full request/response cycle
  - Test all examples
  - Test TLS connections
  - Test error scenarios
  - Test graceful shutdown

### 41. Performance Benchmarks
- **Directory:** `bench/`
- **Issue:** Only etag_hash benchmark exists
- **Priority:** 🟢 LOW
- **Effort:** 3 hours
- **Strategy:**
  ```v
  // Add benchmarks for:
  // - Request parsing speed
  // - Response building speed
  // - Header lookup speed
  // - Route matching speed
  // - Full request/response cycle

  fn bench_request_parsing() {
      mut b := benchmark.new_benchmark()
      b.measure('parse simple GET') {
          for _ in 0..10000 {
              decode_http_request('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes())
          }
      }
  }
  ```

---

## 📖 Documentation

### 42. Complete API Documentation
- **Files:** All public modules
- **Issue:** Minimal documentation on functions
- **Priority:** 🟡 MEDIUM
- **Effort:** 4 hours
- **Strategy:**
  ```v
  // Add doc comments to all public functions:

  // parse_http1_request_line parses the HTTP/1.1 request line according to RFC 9112.
  // Returns the byte offset immediately after the request line's \r\n.
  //
  // The request line format is:
  //   method SP request-target SP HTTP-version CRLF
  //
  // Example:
  //   GET /path HTTP/1.1\r\n
  //
  // Errors:
  //   - 'request line too short' if buffer is less than 12 bytes
  //   - 'Missing space after method' if no SP found
  //   - 'empty method' if method is zero-length
  pub fn parse_http1_request_line(mut req HttpRequest) !int {
  ```

### 43. Architecture Documentation
- **File:** `ARCHITECTURE.md`
- **Issue:** No high-level architecture doc
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  - Document system architecture
  - Explain backend selection
  - Document threading model
  - Document memory model
  - Add diagrams

### 44. Security Best Practices Guide
- **File:** `SECURITY.md`
- **Issue:** No security documentation
- **Priority:** 🟡 MEDIUM
- **Effort:** 2 hours
- **Strategy:**
  - Document security considerations
  - List common vulnerabilities
  - Provide mitigation strategies
  - Document TLS configuration
  - Document rate limiting

### 45. Performance Tuning Guide
- **File:** `PERFORMANCE.md`
- **Issue:** No performance guidance
- **Priority:** 🟢 LOW
- **Effort:** 2 hours
- **Strategy:**
  - Document performance characteristics
  - Explain buffer sizing
  - Explain worker thread count
  - Document kernel parameters (SO_REUSEPORT, etc)
  - Provide benchmarking methodology

### 46. Example Walkthroughs
- **Files:** README in each example directory
- **Issue:** Some examples lack detailed README
- **Priority:** 🟡 MEDIUM
- **Effort:** 3 hours
- **Strategy:**
  - Write detailed README for each example
  - Include code explanations
  - Add architecture diagrams
  - Include testing instructions
  - Add troubleshooting section

---

## 📊 Priority Matrix

| Priority | Count | Items |
|----------|-------|-------|
| 🔴 CRITICAL | 11 | #1, #2, #5, #6, #7, #8, #15, #16, #33, #34, #35, #36, #37 |
| 🟡 MEDIUM | 19 | #3, #4, #9, #10, #11, #12, #18, #19, #20, #21, #22, #23, #25, #26, #38, #39, #40, #42, #43, #44, #46 |
| 🟢 LOW | 16 | #13, #14, #17, #24, #27, #28, #29, #30, #31, #32, #41, #45 |

---

## 🎯 Implementation Roadmap

### Phase 1: Foundation (Week 1)
**Goal:** Fix critical bugs and add essential helpers

- [x] #1 - Fix vmemcmp bug (5 min)
- [ ] #2 - Complete dynamic routing (2 hours)
- [ ] #5 - Query string parsing (2 hours)
- [ ] #6 - HTTP status codes (15 min)
- [ ] #7 - Response builder (30 min)
- [ ] #8 - Header injection (45 min)

**Total:** ~6 hours

### Phase 2: TLS/HTTPS (Week 2)
**Goal:** Enable HTTPS support

- [ ] #15 - Complete TLS bindings (4 hours)
- [ ] #16 - Integrate TLS (1 hour)
- [ ] #34 - HTTPS example (3 hours)

**Total:** ~8 hours

### Phase 3: Core Examples (Week 3-4)
**Goal:** Create priority examples

- [ ] #33 - Static file server (4 hours)
- [ ] #35 - Middleware example (5 hours)
- [ ] #36 - Logging example (4 hours)
- [ ] #37 - Security example (5 hours)

**Total:** ~18 hours

### Phase 4: Protocol & Backend (Week 5)
**Goal:** Improve HTTP support and backends

- [ ] #9 - Method validation (30 min)
- [ ] #10 - Host header validation (20 min)
- [ ] #11 - Case-insensitive headers (1 hour)
- [ ] #18 - Epoll keep-alive (2 hours)
- [ ] #21 - Timeouts (1 hour)
- [ ] #22 - FD validation (30 min)

**Total:** ~5 hours

### Phase 5: Quality & Testing (Week 6)
**Goal:** Improve code quality and testing

- [ ] #25 - Bounds checking (2 hours)
- [ ] #38 - Parser tests (2 hours)
- [ ] #39 - Backend stress tests (3 hours)
- [ ] #40 - Integration tests (4 hours)

**Total:** ~11 hours

### Phase 6: Documentation (Week 7)
**Goal:** Complete documentation

- [ ] #42 - API docs (4 hours)
- [ ] #43 - Architecture doc (2 hours)
- [ ] #44 - Security guide (2 hours)
- [ ] #46 - Example READMEs (3 hours)

**Total:** ~11 hours

---

## 📈 Progress Tracking

### Completed: 1/46 (2.2%)
- ✅ #2 - Complete dynamic routing (2026-02-10)

### In Progress: 0/46 (0%)

### Not Started: 45/46 (97.8%)

---

## 🔗 Dependencies Graph

```
Foundation Layer:
  #1 (vmemcmp) → Blocks all header parsing
  #6 (status codes) → Required by #7, #33, #34, #35, #36, #37
  #7 (response builder) → Required by #33, #34, #35, #36, #37
  #8 (header injection) → Required by #35, #37

TLS Layer:
  #15 (TLS bindings) → Required by #16, #34
  #16 (TLS integration) → Required by #34

Examples Layer:
  #33, #34, #35, #36, #37 → Require foundation layer

Backend Layer:
  #3 → Required by #20
  #4 → Required by #19
  #21 → Required by #37 (security)

Quality Layer:
  Independent of others
```

---

## 💡 Quick Wins (< 1 hour each)

1. #1 - Fix vmemcmp (5 min)
2. #6 - Add status codes (15 min)
3. #9 - Method validation (30 min)
4. #10 - Host header validation (20 min)
5. #22 - FD validation (30 min)
6. #27 - Replace magic numbers (1 hour)
7. #28 - Remove dead code (30 min)

**Total Quick Wins:** ~3 hours for 7 improvements

---

## 🎓 Learning Opportunities

For contributors wanting to learn:

- **Beginner:** #1, #6, #27, #28
- **Intermediate:** #2, #5, #9, #11, #38
- **Advanced:** #15, #18, #23, #29

---

## 🤝 Contributing

To work on an item:

1. Check dependencies are complete
2. Read the strategy section
3. Implement with tests
4. Update this checklist
5. Submit PR

---

## 📞 Support

For questions about implementation strategies:
- Open an issue on GitHub
- Reference the item number (#N)
- Include your proposed approach

---

**Last Updated:** 2026-02-10
**Maintainer:** @enghitalo
**Version:** 0.0.1
