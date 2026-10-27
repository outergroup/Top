#include "helper.h"
_Thread_local char failure[1024];
double deadline;
void fail(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(failure, sizeof(failure), fmt, args);
    va_end(args);
}
void *allocate(size_t size) {
    void *p = calloc(1, size ? size : 1);
    if (!p) {
        fputs("Out of memory\n", stderr);
        exit(1);
    }
    return p;
}
char *format(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char *s = NULL;
    int n = vasprintf(&s, fmt, args);
    va_end(args);
    if (n < 0) {
        fputs("Out of memory\n", stderr);
        exit(1);
    }
    return s;
}
void bytes_free(Bytes *b) {
    free(b->data);
    *b = (Bytes){0};
}
bool append(Bytes *b, const void *p, size_t n, size_t max) {
    if (n > max || b->size > max - n) {
        fail("size limit exceeded");
        return false;
    }
    unsigned char *q = realloc(b->data, b->size + n + 1);
    if (!q) {
        fail("out of memory");
        return false;
    }
    b->data = q;
    if (n)
        memcpy(q + b->size, p, n);
    b->size += n;
    q[b->size] = 0;
    return true;
}
double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static bool wait_fd(int fd, short events) {
    for (;;) {
        double left = deadline ? deadline - now() : 3600;
        if (left <= 0) {
            fail("operation timed out");
            return false;
        }
        struct pollfd p = {fd, events, 0};
        int r = poll(&p, 1, (int)(left > 3600 ? 3600000 : left * 1000 + 1));
        if (r > 0)
            return true;
        if ((r < 0 && errno == EINTR) || (r == 0 && !deadline))
            continue;
        fail(r == 0 ? "operation timed out" : "poll failed: %s", strerror(errno));
        return false;
    }
}
bool write_all(int fd, const void *p, size_t n) {
    while (n) {
        if (!wait_fd(fd, POLLOUT))
            return false;
        ssize_t k = write(fd, p, n);
        if (k < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (k <= 0) {
            fail("write: %s", strerror(errno));
            return false;
        }
        p = (const char *)p + k;
        n -= (size_t)k;
    }
    return true;
}
bool read_all(int fd, void *p, size_t n, bool *eof) {
    size_t done = 0;
    *eof = false;
    while (done < n) {
        if (!wait_fd(fd, POLLIN))
            return false;
        ssize_t k = read(fd, (char *)p + done, n - done);
        if (k < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (k <= 0) {
            *eof = k == 0 && done == 0;
            fail(k == 0 ? "truncated stream" : "read: %s", strerror(errno));
            return false;
        }
        done += (size_t)k;
    }
    return true;
}
Bytes read_file(const char *path, size_t limit, bool regular) {
    Bytes b = {0};
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        fail("%s: %s", path, strerror(errno));
        return b;
    }
    struct stat st;
    if (fstat(fd, &st)) {
        int error = errno;
        close(fd);
        errno = error;
        fail("stat %s: %s", path, strerror(error));
        return b;
    }
    if (regular && !S_ISREG(st.st_mode)) {
        close(fd);
        errno = EINVAL;
        fail("not a regular file: %s", path);
        return b;
    }
    if (st.st_size > (off_t)limit) {
        close(fd);
        errno = EFBIG;
        fail("file exceeds size limit");
        return b;
    }
    unsigned char buf[8192];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0) {
            fail("read %s: %s", path, strerror(errno));
            break;
        }
        if (!n)
            break;
        if (!append(&b, buf, (size_t)n, limit))
            break;
    }
    close(fd);
    if (failure[0])
        bytes_free(&b);
    else if (!b.data)
        append(&b, "", 0, limit);
    return b;
}
