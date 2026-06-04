/* vcam — in-process V4L2 MJPEG capture. See vcam.h. */
#include "vcam.h"

#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define VCAM_NBUF 4 // a small ring of capture buffers

struct vcam {
    int    fd;
    void  *buf_start[VCAM_NBUF];
    size_t buf_len[VCAM_NBUF];
    int    n_buffers;
    int    current;  // index of the currently dequeued buffer, or -1
    int    cur_len;  // bytesused of the current frame
};

// ioctl that retries on EINTR.
static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do {
        r = ioctl(fd, req, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

void vcam_close(vcam *c) {
    if (!c) return;
    if (c->fd >= 0) {
        enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        xioctl(c->fd, VIDIOC_STREAMOFF, &t);
    }
    for (int i = 0; i < c->n_buffers; i++) {
        if (c->buf_start[i] && c->buf_start[i] != MAP_FAILED)
            munmap(c->buf_start[i], c->buf_len[i]);
    }
    if (c->fd >= 0) close(c->fd);
    free(c);
}

vcam *vcam_open(const char *path, int width, int height) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return NULL;

    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0
        || !(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)
        || !(cap.capabilities & V4L2_CAP_STREAMING)) {
        close(fd);
        return NULL;
    }

    // Ask the camera for MJPEG at the requested size.
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type                = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width       = width;
    fmt.fmt.pix.height      = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
    fmt.fmt.pix.field       = V4L2_FIELD_ANY;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        close(fd);
        return NULL;
    }
    // If the driver could not give us MJPEG, bail (caller falls back to ffmpeg).
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_MJPEG) {
        close(fd);
        return NULL;
    }

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count  = VCAM_NBUF;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
        close(fd);
        return NULL;
    }

    vcam *c = (vcam *)calloc(1, sizeof(vcam));
    if (!c) { close(fd); return NULL; }
    c->fd = fd;
    c->current = -1;
    c->n_buffers = (int)req.count;
    if (c->n_buffers > VCAM_NBUF) c->n_buffers = VCAM_NBUF;

    // Query, mmap and queue each buffer.
    for (int i = 0; i < c->n_buffers; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index  = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) { vcam_close(c); return NULL; }
        c->buf_len[i]   = b.length;
        c->buf_start[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
                               MAP_SHARED, fd, b.m.offset);
        if (c->buf_start[i] == MAP_FAILED) { vcam_close(c); return NULL; }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) { vcam_close(c); return NULL; }
    }

    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) { vcam_close(c); return NULL; }
    return c;
}

int vcam_next(vcam *c) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    if (xioctl(c->fd, VIDIOC_DQBUF, &b) < 0) return -1;
    c->current = b.index;
    c->cur_len = (int)b.bytesused;
    return c->cur_len;
}

const unsigned char *vcam_ptr(vcam *c) {
    if (c->current < 0) return NULL;
    return (const unsigned char *)c->buf_start[c->current];
}

void vcam_done(vcam *c) {
    if (c->current < 0) return;
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    b.index  = (unsigned int)c->current;
    xioctl(c->fd, VIDIOC_QBUF, &b);
    c->current = -1;
}
