# Contributing

## Rules

- Don't slow down performance
- Always try to keep abstraction to a minimum
- Don't complicate it

## Sending Raw HTTP Requests for Testing

You can test your server by sending raw HTTP requests directly using tools like `nc` (netcat), `telnet`, or `socat`. This is useful for debugging, learning, or end-to-end testing.

### Using netcat (nc)

```sh
printf "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" | nc localhost 3000
```

Send a POST request:

```sh
printf "POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" | nc localhost 3000
```

### Using socat

```sh
printf "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" | socat - TCP:localhost:3000
```

### Using curl (standard requests only)

```sh
curl -v http://localhost:3000/
curl -X POST -v http://localhost:3000/user
curl -X GET -v http://localhost:3000/user/1
```

### Benchmarking

## WRK

```sh
wrk  -H 'Connection: "keep-alive"' --connection 512 --threads 16 --duration 10s http://localhost:3000
```

## Telling a real change from noise

For hot-path functions, a controlled micro-benchmark beats a noisy `wrk` run.
Build the bench with `-prod`, then drive it through `bench/measure.sh`, which pins
a core, reports the environment, and reports the **minimum** across runs (see
[docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md) §10):

```sh
v -prod -gc none -o /tmp/bench bench/request_parser/request_parser_bench.v
bench/measure.sh /tmp/bench
```

### Valgrind

```sh
# Race condition check
v -prod -gc none .
valgrind --tool=helgrind ./vanilla
```
