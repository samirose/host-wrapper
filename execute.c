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
 * Opens a raw PTY of size ws. Sets *read_fd, the master, for the wrapper and
 * *write_fd, the slave, for the target. Returns 0, or -1 having reported why.
 */
static int open_pty(struct winsize *ws, int *read_fd, int *write_fd) {
    if (openpty(read_fd, write_fd, NULL, NULL, ws) == -1) {
        log_error("openpty: %s\n", strerror(errno));
        return -1;
    }
    struct termios ios;
    if (tcgetattr(*write_fd, &ios) == 0) {
        cfmakeraw(&ios);
        tcsetattr(*write_fd, TCSANOW, &ios);
    }
    return 0;
}

/**
 * Opens a pipe for one of the target's output streams. Sets *read_fd for the
 * wrapper and *write_fd for the target. Returns 0, or -1 having reported why.
 */
static int open_pipe(int *read_fd, int *write_fd, const char *name) {
    int fds[2];
    if (pipe(fds) == -1) {
        log_error("pipe %s: %s\n", name, strerror(errno));
        return -1;
    }
    *read_fd = fds[0];
    *write_fd = fds[1];
    return 0;
}

/**
 * Runs the target with the output streams named by the TTY_ bits in on_pty
 * sharing one PTY, and each other output stream on a pipe of its own,
 * forwarding each as frames. Returns its exit status, 128+n when signal n
 * killed it, or 125 having reported why.
 */
static int execute_command(const char *exec_path, char **target_argv,
                           Terminal term, int has_stdin, int on_pty) {
    int ret = EXIT_INTERNAL_ERROR;
    int pty_read = -1, pty_write = -1;
    int out_read = -1, out_write = -1;
    int err_read = -1, err_write = -1;
    int status;
    pid_t pid = -1;

    struct winsize ws;
    ws.ws_row = (unsigned short)term.rows;
    ws.ws_col = (unsigned short)term.cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    if ((on_pty && open_pty(&ws, &pty_read, &pty_write) == -1) ||
        (!(on_pty & TTY_STDOUT) && open_pipe(&out_read, &out_write, "stdout") == -1) ||
        (!(on_pty & TTY_STDERR) && open_pipe(&err_read, &err_write, "stderr") == -1)) {
        goto execution_cleanup;
    }

    // At most two: the PTY carries at least one stream whenever it exists.
    struct {
        char tag;
        const char *name;
    } streams[2];
    struct pollfd fds[2];
    int open_streams = 0;
    if (pty_read != -1) {
        streams[open_streams].tag = on_pty & TTY_STDOUT ? TAG_STDOUT : TAG_STDERR;
        streams[open_streams].name = "terminal";
        fds[open_streams++].fd = pty_read;
    }
    if (out_read != -1) {
        streams[open_streams].tag = TAG_STDOUT;
        streams[open_streams].name = "stdout";
        fds[open_streams++].fd = out_read;
    }
    if (err_read != -1) {
        streams[open_streams].tag = TAG_STDERR;
        streams[open_streams].name = "stderr";
        fds[open_streams++].fd = err_read;
    }
    const int nstreams = open_streams;
    for (int i = 0; i < nstreams; i++) {
        fds[i].events = POLLIN;
        if (fcntl(fds[i].fd, F_SETFL, O_NONBLOCK) == -1) {
            log_error("fcntl O_NONBLOCK: %s\n", strerror(errno));
            goto execution_cleanup;
        }
    }

    pid = fork();
    if (pid < 0) {
        log_error("fork: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    if (pid == 0) {
        dup2(on_pty & TTY_STDOUT ? pty_write : out_write, STDOUT_FILENO);
        dup2(on_pty & TTY_STDERR ? pty_write : err_write, STDERR_FILENO);

        if (!has_stdin) {
            int fd_null = open("/dev/null", O_RDONLY);
            if (fd_null >= 0) {
                dup2(fd_null, STDIN_FILENO);
                close(fd_null);
            } else {
                close(STDIN_FILENO);
            }
        }

        int inherited[] = { pty_read, pty_write, out_read, out_write,
                            err_read, err_write };
        for (size_t i = 0; i < sizeof(inherited) / sizeof(inherited[0]); i++) {
            if (inherited[i] != -1) close(inherited[i]);
        }

        // The file is the resolved path; argv[0] stays as the request wrote it.
        execv(exec_path, target_argv);

        // _exit: returning would unwind the parent's frames in the child.
        log_error("execv: %s\n", strerror(errno));
        _exit(EXIT_EXEC_FAILED);
    }

    if (pty_write != -1) { close(pty_write); pty_write = -1; }
    if (out_write != -1) { close(out_write); out_write = -1; }
    if (err_write != -1) { close(err_write); err_write = -1; }

    while (open_streams > 0) {
        if (poll(fds, (nfds_t)nstreams, -1) < 0) {
            if (errno == EINTR) continue;
            log_error("poll: %s\n", strerror(errno));
            break;
        }

        for (int i = 0; i < nstreams; i++) {
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
    if (pty_read != -1) close(pty_read);
    if (pty_write != -1) close(pty_write);
    if (out_read != -1) close(out_read);
    if (out_write != -1) close(out_write);
    if (err_read != -1) close(err_read);
    if (err_write != -1) close(err_write);
    return ret;
}
