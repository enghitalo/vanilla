# Video streaming (file + webcam)

Two streaming models that look similar in a browser but are opposite on the
wire — one server demonstrates both, on top of the frozen
`fn ([]u8, int, mut []u8) !` handler contract.

| Route | Model | Wire format | Who drives it |
|-------|-------|-------------|---------------|
| `GET /video` | **pull / seekable** | byte ranges, `206 Partial Content` | the client (asks for ranges) |
| `GET /webcam` | **push / live** | `multipart/x-mixed-replace` (MJPEG) | the server (pushes frames) |
| `GET /` | — | a page with `<video src=/video>` + `<img src=/webcam>` | — |

```sh
v -prod run examples/video_stream/src
# open http://localhost:3000/
```

The server synthesizes a short `sample.mp4` on first run (via ffmpeg) so it works
out of the box. Drop in your own `sample.mp4` to stream a real file.

## `/video` — file stream (pull / Range)

This is how a `<video>` element plays and **seeks**: it sends
`Range: bytes=START-END` and the server replies `206 Partial Content` with a
`Content-Range`. Dragging the scrubber just issues a new range.

Key property: we read **only the requested range** from disk
(`read_bytes_at`) and **cap each chunk** (`video_chunk_max`, 2 MiB), so a
multi-gigabyte file is never pulled into a `[]u8`. An open-ended
`bytes=0-` is answered with a capped 206; the player asks for the next range.

```sh
curl -i -H 'Range: bytes=0-99' http://localhost:3000/video
# HTTP/1.1 206 Partial Content
# Content-Range: bytes 0-99/52229
# Content-Length: 100
```

## `/webcam` — live stream (push / MJPEG)

`multipart/x-mixed-replace` streams a sequence of JPEG frames over one
never-ending response; `<img src="/webcam">` renders it as live video.

The design mirrors the SSE example: **no thread per viewer**. A viewer is just an
fd already in the server's epoll set. ONE capture thread (started lazily on the
first viewer) reads frames from the camera and fans each one out to every viewer
fd. Cost per viewer: one fd + one map entry.

### Frame source: native V4L2, not a shell-out

Shelling out to ffmpeg is the *portable* way, not the *efficient* way: even a
passthrough subprocess costs a process, a pipe, and extra copies, and a transcode
re-encodes frames the camera already produced.

This example captures **in-process via V4L2** (`vcam.c` / `capture_v4l2_linux.c.v`):
open `/dev/video0`, request `V4L2_PIX_FMT_MJPEG`, `mmap` the kernel's capture
buffers, and loop `VIDIOC_DQBUF`/`VIDIOC_QBUF`. Each dequeued buffer is a ready
JPEG in a DMA buffer; we copy it once into a `[]u8` and hand the buffer straight
back to the driver. No subprocess, no pipe, no transcode, nothing to parse.

Measured on this box (640×480), serving the MJPEG stream — why native is worth it:

| Frame source | CPU | Extra RAM | Subprocess |
|--------------|-----|-----------|------------|
| ffmpeg transcode (decode→raw→re-encode) | ~17% (720p) | ~65 MB (ffmpeg) | yes |
| ffmpeg passthrough (`-c:v copy`) | ~9% (720p) | ~65 MB (ffmpeg) | yes |
| **V4L2 in-process (what we do)** | **~0.6%** | **0** | **none** |

**Requirements / scope.** V4L2 *is* the Linux camera API, so this path is
Linux-only and needs a camera that offers MJPEG (virtually all USB webcams do —
this is what UVC exposes). If there's no such camera, `/webcam` simply doesn't
stream; the `/video` file stream is independent and still works. We deliberately
*don't* carry an ffmpeg fallback for the stream — it would re-introduce the
subprocess/pipe/transcode this example exists to avoid. (ffmpeg is still used, but
only as a one-time convenience to synthesize `sample.mp4` for the file demo; drop
in your own file and ffmpeg isn't needed at all.)

```sh
curl -s http://localhost:3000/webcam | head -c 80
# --vanillaframe
# Content-Type: image/jpeg
# Content-Length: 13512
# ...JPEG...
```

## Deliberate trade-offs

- **Slow viewers are dropped.** Live video favors fresh frames over a backlog; a
  viewer that can't drain ~50 ms of frames is dropped so it can't stall the
  single capture thread for everyone.
- **No `write_timeout_ms`.** The webcam response is intentionally long-lived; a
  write deadline would reap healthy viewers. The file path is short-lived and
  unaffected.
- **fd ownership** follows the SSE pattern: the worker only reads (it closes the
  fd on disconnect); the broadcaster only writes and drops fds that fail. The
  small close/reuse race is the accepted cost of not parking a thread per viewer.

## Core support

Zero-copy `sendfile(2)` for the file path **now exists** in the epoll core: a
handler hands a file off via `core.queue_file(fd, off, len)` and the worker
streams it straight to the socket (EPOLLOUT-driven, no userspace bounce). The
`static_assets` module uses it for large files — see
`examples/spa_static_assets`. Serving a recorded clip can adopt it the same way; the
handler contract here is unchanged.

For the **live** path, dropping a viewer that can't keep up is intentional and
correct: live video favors fresh frames over a backlog, so `send_all` tolerates a
brief stall (~50 ms) and then drops, rather than buffering stale frames and adding
latency. That is the right policy here and is **not** a deficiency.

Reliable server push — where data must *not* be lost or truncated for a slow
consumer (SSE, WebSocket) — needs the opposite: a bounded per-connection outbound
queue drained on `EPOLLOUT`. That is a separate core facility, tracked in
[#23](https://github.com/enghitalo/vanilla/issues/23); live media there would opt
into a keep-latest policy rather than buffering.
