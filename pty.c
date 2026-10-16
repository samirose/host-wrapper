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
 * Forwards everything readable on master_fd, which must be O_NONBLOCK, as
 * frames tagged tag. Returns 1 once the stream is finished, 0 while it may
 * still yield more, -1 having reported a write failure.
 *
 * Linux raises POLLHUP on a master while output is still buffered, so only a
 * read may retire a stream. A drained master reports EIO on Linux and a zero
 * read on macOS.
 */
static int drain_pty(int master_fd, char tag, const char *name) {
    unsigned char buf[4096];

    for (;;) {
        ssize_t n = read(master_fd, buf, sizeof(buf));
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
 * Runs the target with stdout and stderr on PTYs of their own, forwarding each
 * as frames. Returns its exit status, 128+n when signal n killed it, or 125
 * having reported why.
 */
static int execute_command_with_pty(const char *exec_path, char **target_argv, int target_argc, TerminalSize termsize, int has_stdin) {
    int ret = EXIT_INTERNAL_ERROR;
    int master_out = -1, slave_out = -1;
    int master_err = -1, slave_err = -1;
    int status;
    pid_t pid = -1;

    struct winsize ws;
    ws.ws_row = (unsigned short)termsize.rows;
    ws.ws_col = (unsigned short)termsize.cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    if (openpty(&master_out, &slave_out, NULL, NULL, &ws) == -1) {
        log_error("openpty stdout: %s\n", strerror(errno));
        goto execution_cleanup;
    }
    if (openpty(&master_err, &slave_err, NULL, NULL, &ws) == -1) {
        log_error("openpty stderr: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    if (fcntl(master_out, F_SETFL, O_NONBLOCK) == -1 ||
        fcntl(master_err, F_SETFL, O_NONBLOCK) == -1) {
        log_error("fcntl O_NONBLOCK: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    struct termios ios;
    if (tcgetattr(slave_out, &ios) == 0) {
        cfmakeraw(&ios);
        tcsetattr(slave_out, TCSANOW, &ios);
    }
    if (tcgetattr(slave_err, &ios) == 0) {
        cfmakeraw(&ios);
        tcsetattr(slave_err, TCSANOW, &ios);
    }

    pid = fork();
    if (pid < 0) {
        log_error("fork: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    if (pid == 0) {
        dup2(slave_out, STDOUT_FILENO);
        dup2(slave_err, STDERR_FILENO);

        if (!has_stdin) {
            int fd_null = open("/dev/null", O_RDONLY);
            if (fd_null >= 0) {
                dup2(fd_null, STDIN_FILENO);
                close(fd_null);
            } else {
                close(STDIN_FILENO);
            }
        }

        close(master_out); close(slave_out);
        close(master_err); close(slave_err);

        // The file is the resolved path; argv[0] stays as the request wrote it.
        execv(exec_path, target_argv);

        // _exit: returning would unwind the parent's frames in the child.
        log_error("execv: %s\n", strerror(errno));
        _exit(EXIT_EXEC_FAILED);
    }

    close(slave_out); slave_out = -1;
    close(slave_err); slave_err = -1;

    // The frame tag for each master's output, indexed in step with fds below.
    static const struct {
        char tag;
        const char *name;
    } streams[] = {
        { TAG_STDOUT, "stdout" },
        { TAG_STDERR, "stderr" },
    };
    enum { NSTREAMS = sizeof(streams) / sizeof(streams[0]) };

    struct pollfd fds[NSTREAMS];
    fds[0].fd = master_out;
    fds[0].events = POLLIN;
    fds[1].fd = master_err;
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

            int drained = drain_pty(fds[i].fd, streams[i].tag, streams[i].name);
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
    if (master_out != -1) close(master_out);
    if (slave_out != -1) close(slave_out);
    if (master_err != -1) close(master_err);
    if (slave_err != -1) close(slave_err);
    (void)target_argc;
    return ret;
}
