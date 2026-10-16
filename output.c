/**
 * Returns 0 once all of buf is written, or -1 on error or with some of it unwritten.
 */
int write_all(int fd, const void *buf, size_t count) {
    const char *ptr = buf;
    size_t written = 0;
    while (written < count) {
        ssize_t w = write(fd, ptr + written, count - written);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) break;
        written += (size_t)w;
    }
    return (written == count) ? 0 : -1;
}

void log_error(const char *format, ...) {
#ifndef FUZZING
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
#else
    (void)format;
#endif
}
