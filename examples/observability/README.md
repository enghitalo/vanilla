# observability — health, readiness, metrics and an access log

A service has to answer three operational questions without a debugger: is it
alive, is it ready for traffic, and how is it behaving? This example answers
them with three routes and one handler wrapper.

```sh
v run examples/observability/src
curl -i http://localhost:3000/healthz
curl -i http://localhost:3000/readyz
curl http://localhost:3000/metrics
```

| Route | Answers | For |
|---|---|---|
| `/healthz` | `200 ok`, checks nothing | liveness: an orchestrator restarts the process when it fails |
| `/readyz` | `200 ready`, or `503` when a dependency is down | readiness: a load balancer stops sending traffic, without a restart |
| `/metrics` | Prometheus text exposition (`version=0.0.4`) | scraped every 15–60 s |
| anything else | an empty `200` | the demo's contract; a real service answers `404` |

Keep liveness and readiness apart. If a dependency blip fails liveness, every
instance restarts at once. If it fails readiness, the instances only leave the
load balancer until the dependency is back. (`/readyz`'s `503` branch is there,
but the demo's dependency check is the constant `ready := true`.)

```
http_requests_total 4
http_responses_total{class="2xx"} 3
http_responses_total{class="4xx"} 1
http_responses_total{class="5xx"} 0
```

## The wrapper

`observed(next, mut m)` wraps the app's handler. For every request it notes
where the response starts in `out`, runs the app, reads the status code back
from the three digits at that offset, counts it by class and prints one
`key=value` line:

```
level=info method=GET path=/healthz status=200 dur_us=12
```

Because the status is read back from `out`, the client, the metrics and the
log always agree on it:

- A malformed request is the client's error. The app appends the canned `400`
  and returns `.close`, and the wrapper counts and logs that `400`.
- An app that returns an error (`!`, say a database that is down) is the
  server's fault. The wrapper drops whatever partial response the app had
  appended, answers a canned `500` with `Connection: close`, logs the error to
  stderr and counts the `500`.

## Byte discipline

- Fixed responses are `const` strings appended with `core.append_str`.
- Routing compares the path in place, by offsets (`slice_eq`): no string is
  built.
- `METHOD SP PATH` is the request line's prefix, found with two `memchr`
  calls. The log line is assembled around it in a stack buffer, with the
  numbers written by `strconv.write_dec`, without parsing the headers.
- The `/metrics` response goes straight into `out`, with no body buffer: the
  counters are copied under the mutex, the `Content-Length` is the literals'
  lengths plus the counters' digit counts (`strconv.dec_digits`), and the
  body is then written from the same copy, outside the lock. A request
  allocates nothing (`test_serving_allocates_nothing`).

## Trade-offs, and where to go next

- **One `print` per request** (one `write`, newline included) is a
  synchronous write to stdout on the request path. That is fine for a demo, or when stdout is a pipe to a log
  agent. [`examples/logging`](../logging) shows the production shape: JSON
  lines in a per-worker buffer, written by the worker's timer, with rotation,
  `SIGHUP` and shipping to a collector.
- **One mutex for every worker's counters.** Under load, per-worker counters
  (`make_state`) summed at scrape time avoid that contention.
- `dur_us` runs from handler entry, not from the request's first byte.

## Tests

`src/main_test.v` sends raw requests through the whole `observed()` wrapper,
with no socket (BEST_PRACTICES §9). It covers the status read-back and its
bounds, the counts by class, the exposition format and its
`Content-Length`, that serving allocates nothing, the health routes, a malformed request (`400`, counted
`4xx`) and a failing handler (`500`, counted `5xx`).

```sh
v test examples/observability/src
```
