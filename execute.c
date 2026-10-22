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
 * tagged tag, or discards it when forward is 0. Returns 1 once the stream is
 * finished, 0 while it may still yield more, -1 having reported a write
 * failure.
 *
 * Linux raises POLLHUP on a PTY master while output is still buffered, so only
 * a read may retire a stream. A drained master reports EIO on Linux and a zero
 * read on macOS.
 */
static int drain_stream(int fd, char tag, const char *name, int forward) {
    unsigned char buf[4096];

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            if (forward && write_frame(tag, buf, (size_t)n) == -1) {
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

// How often the wrapper checks that the client is still there, and how long a
// target has after SIGHUP before the wrapper sends SIGKILL.
#define HANGUP_CHECK_MS 250
#define HANGUP_GRACE_MS 5000

// A caught signal's number is written here, so that poll wakes for it.
static int signal_pipe[2] = { -1, -1 };

static void on_signal(int sig) {
    int saved = errno;
    unsigned char byte = (unsigned char)sig;
    ssize_t n = write(signal_pipe[1], &byte, 1);
    (void)n;
    errno = saved;
}

/**
 * Routes SIGCHLD and the signals that end the wrapper through signal_pipe, and
 * ignores SIGPIPE so that a vanished client surfaces as EPIPE. Returns 0, or -1
 * having reported why.
 */
static int catch_signals(void) {
    if (pipe(signal_pipe) == -1) {
        log_error("pipe: %s\n", strerror(errno));
        return -1;
    }
    for (int i = 0; i < 2; i++) {
        if (fcntl(signal_pipe[i], F_SETFL, O_NONBLOCK) == -1 ||
            fcntl(signal_pipe[i], F_SETFD, FD_CLOEXEC) == -1) {
            log_error("fcntl: %s\n", strerror(errno));
            return -1;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    static const int caught[] = { SIGCHLD, SIGHUP, SIGINT, SIGTERM };
    for (size_t i = 0; i < sizeof(caught) / sizeof(caught[0]); i++) {
        if (sigaction(caught[i], &sa, NULL) == -1) {
            log_error("sigaction: %s\n", strerror(errno));
            return -1;
        }
    }
    signal(SIGPIPE, SIG_IGN);
    return 0;
}

/**
 * Returns 1 when nothing reads fd any more, 0 otherwise. Polls for POLLOUT,
 * because macOS reports POLLHUP on a write end only alongside it.
 */
static int hung_up(int fd) {
    struct pollfd p = { .fd = fd, .events = POLLOUT, .revents = 0 };
    return poll(&p, 1, 0) == 1 && (p.revents & (POLLHUP | POLLERR));
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/**
 * Runs the target with the output streams named by the TTY_ bits in on_pty
 * sharing one PTY, and each other output stream on a pipe of its own,
 * forwarding each as frames. When the client goes away, or the wrapper is
 * told to end, sends the target's process group SIGHUP and, if the target has
 * not exited HANGUP_GRACE_MS later, SIGKILL. Returns its exit status, 128+n
 * when signal n killed it, or 125 having reported why.
 */
static int execute_command(const char *exec_path, char **target_argv,
                           Terminal term, int has_stdin, int on_pty) {
    int ret = EXIT_INTERNAL_ERROR;
    int pty_read = -1, pty_write = -1;
    int out_read = -1, out_write = -1;
    int err_read = -1, err_write = -1;
    int status;
    pid_t pid = -1;
    int reaped = 0;

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
    // The signal pipe follows them.
    struct {
        char tag;
        const char *name;
    } streams[2];
    struct pollfd fds[3];
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

    if (catch_signals() == -1) goto execution_cleanup;
    fds[nstreams].fd = signal_pipe[0];
    fds[nstreams].events = POLLIN;

    pid = fork();
    if (pid < 0) {
        log_error("fork: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    if (pid == 0) {
        // Its own process group, so that a hangup reaches what it starts.
        setpgid(0, 0);
        signal(SIGPIPE, SIG_DFL);

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

    // Set from both sides, so that the group exists before either signals it.
    setpgid(pid, 0);

    if (pty_write != -1) { close(pty_write); pty_write = -1; }
    if (out_write != -1) { close(out_write); out_write = -1; }
    if (err_write != -1) { close(err_write); err_write = -1; }

    int hangup = 0;
    int hup_sent = 0;
    int killed = 0;
    long long deadline = 0;

    // After a hangup the output is read and dropped, so that a target cleaning
    // up is not killed by SIGPIPE, until the grace period ends.
    while (!reaped || (open_streams > 0 && (!hangup || now_ms() < deadline))) {
        int timeout = HANGUP_CHECK_MS;
        if (hangup && !killed) {
            long long left = deadline - now_ms();
            timeout = left < 0 ? 0 : left < HANGUP_CHECK_MS ? (int)left : HANGUP_CHECK_MS;
        }
        int ready = poll(fds, (nfds_t)(nstreams + 1), timeout);
        if (ready < 0 && errno != EINTR) {
            log_error("poll: %s\n", strerror(errno));
            break;
        }

        if (ready > 0 && fds[nstreams].revents) {
            unsigned char sig;
            while (read(signal_pipe[0], &sig, 1) == 1) {
                if (sig != SIGCHLD) hangup = 1;
            }
        }

        if (!reaped) {
            pid_t waited = waitpid(pid, &status, WNOHANG);
            if (waited == pid) {
                reaped = 1;
            } else if (waited == -1 && errno != EINTR) {
                log_error("waitpid: %s\n", strerror(errno));
                goto execution_cleanup;
            }
        }

        for (int i = 0; ready > 0 && i < nstreams; i++) {
            if (fds[i].fd == -1 || fds[i].revents == 0) continue;

            int drained = drain_stream(fds[i].fd, streams[i].tag, streams[i].name,
                                       !hangup);
            if (drained == -1) {
                hangup = 1;
                break;
            }

            // POLLERR alone would otherwise spin: nothing to read and no EOF.
            if (drained == 1 || (fds[i].revents & POLLERR)) {
                fds[i].fd = -1;
                open_streams--;
            }
        }

        if (!hangup && ready == 0 && hung_up(STDOUT_FILENO)) hangup = 1;

        if (hangup && !hup_sent) {
            kill(-pid, SIGHUP);
            hup_sent = 1;
            deadline = now_ms() + HANGUP_GRACE_MS;
        }
        if (hangup && !reaped && !killed && now_ms() >= deadline) {
            kill(-pid, SIGKILL);
            killed = 1;
        }
    }

    if (reaped) {
        if (WIFEXITED(status)) {
            ret = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            ret = 128 + WTERMSIG(status);
        }
    }

execution_cleanup:
    if (pid > 0 && !reaped) {
        kill(-pid, SIGKILL);
        while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
    }
    if (pty_read != -1) close(pty_read);
    if (pty_write != -1) close(pty_write);
    if (out_read != -1) close(out_read);
    if (out_write != -1) close(out_write);
    if (err_read != -1) close(err_read);
    if (err_write != -1) close(err_write);
    return ret;
}
