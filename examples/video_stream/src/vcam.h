/*
 * vcam — minimal in-process V4L2 MJPEG capture (Linux).
 *
 * Replaces "shell out to ffmpeg": open the camera, ask for MJPEG, mmap the
 * kernel's capture buffers, and hand back each ready JPEG with zero copies on
 * this side of the boundary (the caller copies once into its own buffer before
 * requeueing). No subprocess, no pipe, no transcode.
 */
#ifndef VCAM_H
#define VCAM_H

typedef struct vcam vcam;

// Open `path`, negotiate MJPEG near width x height, set up mmap'd streaming
// buffers and start the stream. Returns NULL on any failure (no device, the
// camera has no MJPEG mode, or an ioctl error) so the caller can fall back.
vcam *vcam_open(const char *path, int width, int height);

// Block until the next frame is ready (dequeue a buffer). Returns the JPEG
// length in bytes (> 0), or < 0 on error. The bytes live in an mmap'd buffer
// reachable via vcam_ptr(); they are valid until vcam_done().
int vcam_next(vcam *c);

// Pointer to the current frame's bytes (valid between vcam_next and vcam_done).
const unsigned char *vcam_ptr(vcam *c);

// Return the current buffer to the driver so it can be filled again. Call once
// per successful vcam_next, after copying/using the frame.
void vcam_done(vcam *c);

// Stop streaming, unmap buffers, close the device.
void vcam_close(vcam *c);

#endif /* VCAM_H */
