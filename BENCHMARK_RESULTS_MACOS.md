# vanilla — macOS route tests & benchmarks

Generated: 2026-06-11 22:24:16 -03 by `scripts/macos_test_and_bench.sh`

## System

```
ProductName:		macOS
ProductVersion:		26.5.1
BuildVersion:		25F80
arch:        arm64
cpu:         Apple M4
cores:       10
memory:      24 GiB
v:           V 0.5.1 5d739b1
wrk:         wrk 4.2.0 [kqueue] Copyright (C) 2012 Will Glozer
hey:         installed
ab:          This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
ulimit -n:   65536
somaxconn:   128
```

> Backend: kqueue (darwin default). Examples were built with plain `v`;
> the benchmark target `examples/tiny/src` was built with `v -prod`.

## Route tests — all examples

Result: **97 passed**, **1 failed**, **2 skipped**

| Example | Check | Expected | Got | Result |
|---|---|---|---|---|
| tiny | GET / | 200 | 200 | ✅ |
| simple | GET / | 200 | 200 | ✅ |
| simple | GET /user/42 | 200 | 200 | ✅ |
| simple | POST /user | 201 | 201 | ✅ |
| simple | GET /nope (fallback) | 400 | 400 | ✅ |
| simple2 | GET / | 200 | 200 | ✅ |
| simple2 | GET /users | 200 | 200 | ✅ |
| simple2 | GET /user/42 | 200 | 200 | ✅ |
| simple2 | POST /user | 201 | 201 | ✅ |
| simple3 | GET / | 200 | 200 | ✅ |
| simple3 | GET /user/42 | 200 | 200 | ✅ |
| simple3 | POST /user | 201 | 201 | ✅ |
| auth | GET /token | 200 | 200 | ✅ |
| auth | GET /protected (token) | 200 | 200 | ✅ |
| auth | GET /protected (no token) | 401 | 401 | ✅ |
| auth | GET /service (good key) | 200 | 200 | ✅ |
| auth | GET /service (bad key) | 401 | 401 | ✅ |
| chunked_streaming | GET / (chunked) | 200 | 200 | ✅ |
| compression | GET / (gzip) | 200 | 200 | ✅ |
| compression | GET / (identity) | 200 | 200 | ✅ |
| cookies_sessions | GET /login (set cookie) | 200 | 200 | ✅ |
| cookies_sessions | GET /me (with sid) | 200 | 200 | ✅ |
| cookies_sessions | GET /me (no cookie) | 401 | 401 | ✅ |
| cookies_sessions | GET /logout | 200 | 200 | ✅ |
| cors | OPTIONS preflight (allowed origin) | 204 | 204 | ✅ |
| cors | OPTIONS preflight (evil origin) | 403 | 403 | ✅ |
| cors | GET / (allowed origin) | 200 | 200 | ✅ |
| cors | GET / (no origin) | 200 | 200 | ✅ |
| csrf | GET /form (sets csrf cookie) | 200 | 200 | ✅ |
| csrf | POST /submit (token ok) | 200 | 200 | ✅ |
| csrf | POST /submit (no token) | 403 | 403 | ✅ |
| csrf | GET / (safe method) | 200 | 200 | ✅ |
| database | all routes | - | skipped: no PostgreSQL at localhost:5435 | ⏭️ |
| date_header | GET / | 200 | 200 | ✅ |
| etag | GET / | 200 | 200 | ✅ |
| etag | GET /user/123 | 200 | 200 | ✅ |
| etag | GET /user/123 (If-None-Match) | 304 | 304 | ✅ |
| etag | POST /user | 201 | 201 | ✅ |
| graceful_shutdown | GET / | 200 | 200 | ✅ |
| graceful_shutdown | SIGTERM drains + exits | port freed | port freed | ✅ |
| hexagonal | BUILD | ok | compile error | ❌ |
| io_uring_demo | GET / | 200 | 200 | ✅ |
| ip_block | GET / (localhost allowed) | 200 | 200 | ✅ |
| json_api | POST /users (valid) | 201 | 201 | ✅ |
| json_api | POST /users (invalid) | 400 | 400 | ✅ |
| json_api | POST /upload (multipart) | 200 | 200 | ✅ |
| json_api | GET / (fallback=400) | 400 | 400 | ✅ |
| middleware | GET / | 200 | 200 | ✅ |
| middleware | GET /me (tok-alice) | 200 | 200 | ✅ |
| middleware | GET /me (anon) | 401 | 401 | ✅ |
| middleware | GET /admin (tok-root) | 200 | 200 | ✅ |
| middleware | GET /admin (tok-alice) | 403 | 403 | ✅ |
| middleware | GET /nope | 404 | 404 | ✅ |
| observability | GET /healthz | 200 | 200 | ✅ |
| observability | GET /readyz | 200 | 200 | ✅ |
| observability | GET /metrics | 200 | 200 | ✅ |
| observability | GET / | 200 | 200 | ✅ |
| proxy_aware | GET / (XFF) | 200 | 200 | ✅ |
| proxy_aware | GET / (no XFF) | 200 | 200 | ✅ |
| rate_limit | GET / (first) | 200 | 200 | ✅ |
| rate_limit | GET / (bucket drained) | 429 | 429 | ✅ |
| redirects | GET /old | 301 | 301 | ✅ |
| redirects | POST /login | 303 | 303 | ✅ |
| redirects | POST /login?next=/settings | 303 | 303 | ✅ |
| redirects | GET /login | 200 | 200 | ✅ |
| redirects | GET /api/v1/resource | 308 | 308 | ✅ |
| redirects | GET /anything (fallback) | 200 | 200 | ✅ |
| request_limits | GET / | 200 | 200 | ✅ |
| request_limits | POST 11MiB body (413) | 413 | 413 | ✅ |
| request_limits | 20KB header (431) | 431 | 431 | ✅ |
| security_headers | GET / | 200 | 200 | ✅ |
| security_headers | HSTS + CSP present | present | present | ✅ |
| sse | GET /events (stream) | 200 | 200 | ✅ |
| sse | POST /broadcast | 200 | 200 | ✅ |
| sse | GET / (fallback=400) | 400 | 400 | ✅ |
| static_files | GET / (index.html) | 200 | 200 | ✅ |
| static_files | GET /index.html (Range) | 206 | 206 | ✅ |
| static_files | GET /index.html (If-None-Match) | 304 | 304 | ✅ |
| static_files | POST / (405) | 405 | 405 | ✅ |
| static_files | GET /../etc/passwd (traversal) | 404 | 404 | ✅ |
| static_files | GET /missing.txt | 404 | 404 | ✅ |
| url_form | GET with query params | 200 | 200 | ✅ |
| url_form | POST urlencoded form | 200 | 200 | ✅ |
| url_form | GET / (empty) | 200 | 200 | ✅ |
| veb_like | GET /users | 200 | 200 | ✅ |
| veb_like | POST /users | 201 | 201 | ✅ |
| veb_like | GET /users/7 | 200 | 200 | ✅ |
| veb_like | PUT /users/7 | 200 | 200 | ✅ |
| veb_like | PATCH /users/7 | 200 | 200 | ✅ |
| veb_like | DELETE /users/7 | 200 | 200 | ✅ |
| veb_like | GET /users/7/profile | 200 | 200 | ✅ |
| veb_like | GET /users/7/posts/99 | 200 | 200 | ✅ |
| veb_like | GET /users/7/posts/99/comments/3 | 200 | 200 | ✅ |
| veb_like | GET /tags/a/b/c | 200 | 200 | ✅ |
| veb_like | GET /search/vlang | 200 | 200 | ✅ |
| veb_like | GET /files/css/app.css | 200 | 200 | ✅ |
| veb_like | GET /proxy/api.example.com/v1 | 200 | 200 | ✅ |
| veb_like | POST /users/7 (405) | 405 | 405 | ✅ |
| veb_like | GET /nope (404) | 404 | 404 | ✅ |
| video_stream | all routes | - | skipped: ffmpeg not installed (brew install ffmpeg) | ⏭️ |

## Benchmarks — examples/tiny/src (`v -prod`, kqueue backend)

### wrk — 8 threads, 64 connections, 10 s

```
Running 10s test @ http://127.0.0.1:3000/
  8 threads and 64 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   264.65us  108.82us   6.42ms   89.14%
    Req/Sec    26.12k     1.95k   32.62k    78.96%
  2100118 requests in 10.10s, 216.31MB read
Requests/sec: 207929.72
Transfer/sec:     21.42MB
```

### wrk — 8 threads, 256 connections, 10 s

```
Running 10s test @ http://127.0.0.1:3000/
  8 threads and 256 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.08ms  701.79us  42.62ms   96.99%
    Req/Sec    26.66k     2.27k   42.20k    78.54%
  2139082 requests in 10.10s, 220.32MB read
Requests/sec: 211691.56
Transfer/sec:     21.80MB
```

### wrk — 16 threads, 512 connections, 10 s (CONTRIBUTING.md config)

```
Running 10s test @ http://127.0.0.1:3000/
  16 threads and 512 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     2.66ms    2.61ms  43.80ms   92.13%
    Req/Sec    13.31k     1.96k   41.07k    81.75%
  2124348 requests in 10.06s, 218.80MB read
Requests/sec: 211213.84
Transfer/sec:     21.75MB
```

### hey — 128 connections, 10 s

```

Summary:
  Total:	10.0006 secs
  Slowest:	0.0408 secs
  Fastest:	0.0000 secs
  Average:	0.0013 secs
  Requests/sec:	212231.1182
  
  Total data:	27591837 bytes
  Size/request:	27 bytes

Response time histogram:
  0.000 [1]	|
  0.004 [998631]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.008 [1090]	|
  0.012 [173]	|
  0.016 [56]	|
  0.020 [16]	|
  0.024 [14]	|
  0.029 [1]	|
  0.033 [0]	|
  0.037 [10]	|
  0.041 [8]	|


Latency distribution:
  10%% in 0.0001 secs
  25%% in 0.0002 secs
  50%% in 0.0004 secs
  75%% in 0.0008 secs
  90%% in 0.0013 secs
  95%% in 0.0016 secs
  99%% in 0.0026 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0000 secs, 0.0032 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0037 secs
  resp wait:	0.0007 secs, 0.0000 secs, 0.0383 secs
  resp read:	0.0003 secs, 0.0000 secs, 0.0211 secs

Status code distribution:
  [200]	1000000 responses



```

### ab — 200 000 requests, 128 connections, keep-alive

```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking 127.0.0.1 (be patient)
Completed 20000 requests
Completed 40000 requests
Completed 60000 requests
Completed 80000 requests
Completed 100000 requests
Completed 120000 requests
Completed 140000 requests
Completed 160000 requests
Completed 180000 requests
Completed 200000 requests
Finished 200000 requests


Server Software:        
Server Hostname:        127.0.0.1
Server Port:            3000

Document Path:          /
Document Length:        13 bytes

Concurrency Level:      128
Time taken for tests:   0.714 seconds
Complete requests:      200000
Failed requests:        0
Keep-Alive requests:    200000
Total transferred:      21600000 bytes
HTML transferred:       2600000 bytes
Requests per second:    280187.00 [#/sec] (mean)
Time per request:       0.457 [ms] (mean)
Time per request:       0.004 [ms] (mean, across all concurrent requests)
Transfer rate:          29550.97 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       2
Processing:     0    0   0.1      0       2
Waiting:        0    0   0.1      0       2
Total:          0    0   0.1      0       4

Percentage of the requests served within a certain time (ms)
  50%      0
  66%      0
  75%      0
  80%      0
  90%      0
  95%      0
  98%      1
  99%      1
 100%      4 (longest request)
```

## Notes

- The darwin kqueue backend now supports HTTP keep-alive, SO_NOSIGPIPE,
  TCP_NODELAY on accepted sockets, correct EV_EOF handling, and the
  configured `Limits` (413/431) — see git log for the macOS fix set.
- macOS `kern.ipc.somaxconn` defaults to 128; for high-connection-count
  benchmarks consider `sudo sysctl -w kern.ipc.somaxconn=1024`.
- ab on macOS sometimes aborts with `apr_socket_recv`; rerun if needed.
