#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
#include <util.h>
#else
#include <pty.h>
#endif

static int write_frame(char tag, const void *data, size_t len) {
    char head[32];
    int head_len = snprintf(head, sizeof(head), "%zu:%c", len + 1, tag);
    if (write_all(STDOUT_FILENO, head, (size_t)head_len) == -1) return -1;
    if (write_all(STDOUT_FILENO, data, len) == -1) return -1;
    return write_all(STDOUT_FILENO, ",", 1);
}

/**
 * Forwards everything readable on fd, which must be O_NONBLOCK, as frames
 * tagged tag. Returns 1 once the stream is finished, 0 while it may still yield
 * more, -1 having reported a write failure.
 *
 * Linux raises POLLHUP on a PTY master while output is still buffered, so only
 * a read may retire a stream. A drained master reports EIO on Linux and a zero
 * read on macOS.
 */
static int drain_stream(int fd, char tag, const char *name) {
    unsigned char buf[4096];

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            if (write_frame(tag, buf, (size_t)n) == -1) {
                log_error("write %s: %s\n", name, strerror(errno));
                return -1;
            }
            continue;
        }
        if (n == 0) return 1;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return 1;
    }
}

/**
 * Opens one of the target's output streams: a raw PTY of size ws, or a pipe.
 * Sets *read_fd, O_NONBLOCK, for the wrapper and *write_fd for the target.
 * Returns 0, or -1 on failure, having reported why.
 */
static int open_stream(int use_pty, struct winsize *ws, int *read_fd,
                       int *write_fd, const char *name) {
    if (use_pty) {
        if (openpty(read_fd, write_fd, NULL, NULL, ws) == -1) {
            log_error("openpty %s: %s\n", name, strerror(errno));
            return -1;
        }
        struct termios ios;
        if (tcgetattr(*write_fd, &ios) == 0) {
            cfmakeraw(&ios);
            tcsetattr(*write_fd, TCSANOW, &ios);
        }
    } else {
        int fds[2];
        if (pipe(fds) == -1) {
            log_error("pipe %s: %s\n", name, strerror(errno));
            return -1;
        }
        *read_fd = fds[0];
        *write_fd = fds[1];
    }

    if (fcntl(*read_fd, F_SETFL, O_NONBLOCK) == -1) {
        log_error("fcntl O_NONBLOCK: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

/**
 * Runs the target with stdout and stderr each on a PTY of its own when use_pty
 * is set, on a pipe otherwise, forwarding each as frames. Returns its exit
 * status, 128+n when signal n killed it, or 125 having reported why.
 */
static int execute_command(const char *exec_path, char **target_argv,
                           TerminalSize termsize, int has_stdin, int use_pty) {
    int ret = EXIT_INTERNAL_ERROR;
    int out_read = -1, out_write = -1;
    int err_read = -1, err_write = -1;
    int status;
    pid_t pid = -1;

    struct winsize ws;
    ws.ws_row = (unsigned short)termsize.rows;
    ws.ws_col = (unsigned short)termsize.cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    if (open_stream(use_pty, &ws, &out_read, &out_write, "stdout") == -1 ||
        open_stream(use_pty, &ws, &err_read, &err_write, "stderr") == -1) {
        goto execution_cleanup;
    }

    pid = fork();
    if (pid < 0) {
        log_error("fork: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    if (pid == 0) {
        dup2(out_write, STDOUT_FILENO);
        dup2(err_write, STDERR_FILENO);

        if (!has_stdin) {
            int fd_null = open("/dev/null", O_RDONLY);
            if (fd_null >= 0) {
                dup2(fd_null, STDIN_FILENO);
                close(fd_null);
            } else {
                close(STDIN_FILENO);
            }
        }

        close(out_read); close(out_write);
        close(err_read); close(err_write);

        // The file is the resolved path; argv[0] stays as the request wrote it.
        execv(exec_path, target_argv);

        // _exit: returning would unwind the parent's frames in the child.
        log_error("execv: %s\n", strerror(errno));
        _exit(EXIT_EXEC_FAILED);
    }

    close(out_write); out_write = -1;
    close(err_write); err_write = -1;

    // The frame tag for each stream's output, indexed in step with fds below.
    static const struct {
        char tag;
        const char *name;
    } streams[] = {
        { TAG_STDOUT, "stdout" },
        { TAG_STDERR, "stderr" },
    };
    enum { NSTREAMS = sizeof(streams) / sizeof(streams[0]) };

    struct pollfd fds[NSTREAMS];
    fds[0].fd = out_read;
    fds[0].events = POLLIN;
    fds[1].fd = err_read;
    fds[1].events = POLLIN;

    int open_streams = NSTREAMS;

    while (open_streams > 0) {
        if (poll(fds, NSTREAMS, -1) < 0) {
            if (errno == EINTR) continue;
            log_error("poll: %s\n", strerror(errno));
            break;
        }

        for (int i = 0; i < NSTREAMS; i++) {
            if (fds[i].fd == -1 || fds[i].revents == 0) continue;

            int drained = drain_stream(fds[i].fd, streams[i].tag, streams[i].name);
            if (drained == -1) goto forwarding_done;

            // POLLERR alone would otherwise spin: nothing to read and no EOF.
            if (drained == 1 || (fds[i].revents & POLLERR)) {
                fds[i].fd = -1;
                open_streams--;
            }
        }
    }

forwarding_done:
    while (waitpid(pid, &status, 0) == -1) {
        if (errno != EINTR) {
            log_error("waitpid: %s\n", strerror(errno));
            goto execution_cleanup;
        }
    }
    if (WIFEXITED(status)) {
        ret = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        ret = 128 + WTERMSIG(status);
    }

execution_cleanup:
    if (out_read != -1) close(out_read);
    if (out_write != -1) close(out_write);
    if (err_read != -1) close(err_read);
    if (err_write != -1) close(err_write);
    return ret;
}
