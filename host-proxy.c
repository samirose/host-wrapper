/*
 * Copyright (c) 2026 Sami Rosendahl
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
#include <limits.h>
#include <libgen.h>
#include <sys/ioctl.h>

// 0-124 belong to the target; see host-wrapper.c.
#define EXIT_PROXY_ERROR 125

// The first netstring of every request; host-wrapper.c checks the same string.
#define PROTOCOL_MAGIC "HW1"

// A tag byte and a 64 KiB chunk.
#define MAX_FRAME (65536 + 1)

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

int write_netstring(int fd, const char *data, size_t len) {
    char header[32];
    int header_len = snprintf(header, sizeof(header), "%zu:", len);
    if (write_all(fd, header, (size_t)header_len) == -1) return -1;
    if (write_all(fd, data, len) == -1) return -1;
    if (write_all(fd, ",", 1) == -1) return -1;
    return 0;
}

typedef enum {
    FRAME_LENGTH,
    FRAME_TAG,
    FRAME_DATA,
    FRAME_COMMA,
    FRAME_DONE,
} FrameState;

typedef struct {
    FrameState state;
    size_t length;
    size_t digits;
    size_t remaining;
    char tag;
    char status[4];
    size_t status_len;
    int exit_status;
} FrameDecoder;

typedef int (*FrameSink)(char tag, const unsigned char *data, size_t len);

void frame_decoder_init(FrameDecoder *d) {
    memset(d, 0, sizeof(*d));
    d->state = FRAME_LENGTH;
    d->exit_status = -1;
}

static int parse_status(const char *s, size_t len) {
    if (len == 0 || (len > 1 && s[0] == '0')) return -1;
    int n = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        n = n * 10 + (s[i] - '0');
    }
    return n <= 255 ? n : -1;
}

/**
 * Decodes len more bytes of response, passing each output chunk to sink. Returns
 * 0, -1 on a malformed response, or -2 when sink failed. d->state is FRAME_DONE
 * once the status frame has arrived, with the status in d->exit_status.
 */
int decode_frames(FrameDecoder *d, const unsigned char *buf, size_t len, FrameSink sink) {
    size_t i = 0;
    while (i < len) {
        unsigned char c = buf[i];
        switch (d->state) {
        case FRAME_LENGTH:
            if (c >= '0' && c <= '9') {
                if (d->digits == 1 && d->length == 0) return -1;
                d->length = d->length * 10 + (c - '0');
                d->digits++;
                if (d->length > MAX_FRAME) return -1;
            } else if (c == ':' && d->length > 0) {
                d->remaining = d->length - 1;
                d->state = FRAME_TAG;
            } else {
                return -1;
            }
            i++;
            break;
        case FRAME_TAG:
            if (c != '1' && c != '2' && c != 'x') return -1;
            if (c == 'x' && d->remaining > sizeof(d->status) - 1) return -1;
            d->tag = (char)c;
            d->state = d->remaining > 0 ? FRAME_DATA : FRAME_COMMA;
            i++;
            break;
        case FRAME_DATA: {
            size_t n = len - i < d->remaining ? len - i : d->remaining;
            if (d->tag == 'x') {
                memcpy(d->status + d->status_len, buf + i, n);
                d->status_len += n;
            } else if (sink(d->tag, buf + i, n) == -1) {
                return -2;
            }
            d->remaining -= n;
            i += n;
            if (d->remaining == 0) d->state = FRAME_COMMA;
            break;
        }
        case FRAME_COMMA:
            if (c != ',') return -1;
            i++;
            if (d->tag == 'x') {
                d->exit_status = parse_status(d->status, d->status_len);
                if (d->exit_status == -1) return -1;
                d->state = FRAME_DONE;
            } else {
                d->length = 0;
                d->digits = 0;
                d->state = FRAME_LENGTH;
            }
            break;
        case FRAME_DONE:
            return -1;
        }
    }
    return 0;
}

#ifndef FUZZING
static int write_chunk(char tag, const unsigned char *data, size_t len) {
    return write_all(tag == '1' ? STDOUT_FILENO : STDERR_FILENO, data, len);
}

static int read_response(int fd) {
    FrameDecoder d;
    frame_decoder_init(&d);
    unsigned char buf[4096];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
            perror("read response");
            return EXIT_PROXY_ERROR;
        }
        if (n == 0) break;
        int decoded = decode_frames(&d, buf, (size_t)n, write_chunk);
        if (decoded == -2) {
            // As a process writing into a closed pipe would end by default.
            if (errno == EPIPE) return 128 + SIGPIPE;
            perror("write");
            return EXIT_PROXY_ERROR;
        }
        if (decoded == -1) {
            fprintf(stderr, "Error: malformed response from host-wrapper\n");
            return EXIT_PROXY_ERROR;
        }
    }
    if (d.state != FRAME_DONE) {
        fprintf(stderr, "Error: transport failed before the command reported status\n");
        return EXIT_PROXY_ERROR;
    }
    return d.exit_status;
}

/**
 * Runs the connection script, HOST_PROXY_SSH_SCRIPT or else host-proxy-ssh.sh
 * in proxy_dir, reading request_fd and writing response_fd. Never returns:
 * exits 125 having reported why when the script cannot be run.
 */
void execute_ssh_child(int request_fd, int response_fd, const char *proxy_dir) {
    if (dup2(request_fd, STDIN_FILENO) == -1 || dup2(response_fd, STDOUT_FILENO) == -1) {
        perror("dup2");
        exit(EXIT_PROXY_ERROR);
    }
    close(request_fd);
    close(response_fd);

    char script_path[PATH_MAX];
    const char *env_script = getenv("HOST_PROXY_SSH_SCRIPT");
    if (env_script && env_script[0] != '\0') {
        strncpy(script_path, env_script, sizeof(script_path) - 1);
        script_path[sizeof(script_path) - 1] = '\0';
    } else {
        snprintf(script_path, sizeof(script_path), "%s/host-proxy-ssh.sh", proxy_dir);
    }

    char *script_argv[] = {
        script_path, NULL
    };

    execvp(script_argv[0], script_argv);
    fprintf(stderr, "execvp failed for %s: %s\n", script_path, strerror(errno));
    exit(EXIT_PROXY_ERROR);
}

/**
 * Copies stdin to pipe_write_fd. Never returns: exits 0 once stdin ends or
 * fails, or the pipe can no longer be written.
 */
void execute_stdin_pump(int pipe_write_fd) {
    unsigned char buffer[4096];
    ssize_t n;
    while ((n = read(0, buffer, sizeof(buffer))) > 0) {
        if (write_all(pipe_write_fd, buffer, (size_t)n) == -1) {
            close(pipe_write_fd);
            exit(0);
        }
    }
    close(pipe_write_fd);
    exit(0);
}

static int send_request(int fd, int argc, char *argv[]) {
    // Input piped into a command leaves the terminal on stdout, so all three
    // descriptors are tried.
    struct winsize ws;
    int cols = 80;
    int rows = 24;
    int probe[] = { STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO };
    for (size_t i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
        if (ioctl(probe[i], TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
            cols = ws.ws_col;
            rows = ws.ws_row;
            break;
        }
    }
    char cols_opt[32];
    char rows_opt[32];
    snprintf(cols_opt, sizeof(cols_opt), "cols=%d", cols);
    snprintf(rows_opt, sizeof(rows_opt), "rows=%d", rows);
    // The magic, the options, and the empty netstring that ends them.
    const char *header[] = { PROTOCOL_MAGIC, cols_opt, rows_opt, "" };
    for (size_t i = 0; i < sizeof(header) / sizeof(header[0]); i++) {
        if (write_netstring(fd, header[i], strlen(header[i])) == -1) return -1;
    }

    char argc_str[16];
    snprintf(argc_str, sizeof(argc_str), "%d", argc - 1);
    if (write_netstring(fd, argc_str, strlen(argc_str)) == -1) return -1;
    for (int i = 1; i < argc; i++) {
        if (write_netstring(fd, argv[i], strlen(argv[i])) == -1) return -1;
    }
    return 0;
}

/**
 * Sends the request, pumps stdin behind it and relays the response. Returns the
 * status host-wrapper reported, 141 when stdout closed, or 125 having reported
 * why.
 */
int execute_proxy_parent(int request_fd, int response_fd, pid_t child_pid,
                         int argc, char *argv[]) {
    // A closed pipe surfaces as EPIPE: on the request, so that the response is
    // still read; on stdout, to exit 141 once the children are reaped.
    signal(SIGPIPE, SIG_IGN);

    // A wrapper that refuses a request may stop reading it part way, and its
    // status frame is still the answer, so a failed send goes on to the
    // response.
    pid_t pump_pid = -1;
    if (send_request(request_fd, argc, argv) == 0) {
        pump_pid = fork();
        if (pump_pid == -1) perror("fork pump");
        if (pump_pid == 0) {
            close(response_fd);
            execute_stdin_pump(request_fd);
        }
    }
    // The pump holds the only write end left, so its exit is the connector's EOF.
    close(request_fd);

    int result = read_response(response_fd);
    close(response_fd);

    // The pump may still be blocked reading a terminal.
    if (pump_pid > 0) {
        kill(pump_pid, SIGTERM);
        waitpid(pump_pid, NULL, 0);
    }

    pid_t waited;
    while ((waited = waitpid(child_pid, NULL, 0)) == -1 && errno == EINTR) {}
    if (waited == -1) {
        perror("waitpid");
        return EXIT_PROXY_ERROR;
    }
    return result;
}

int main(int argc, char *argv[]) {
    char *proxy_dir = NULL;
    char *argv0_copy = NULL;
    int result = EXIT_PROXY_ERROR;

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return EXIT_PROXY_ERROR;
    }

    argv0_copy = strdup(argv[0]);
    if (!argv0_copy) {
        perror("strdup");
        goto cleanup;
    }
    proxy_dir = strdup(dirname(argv0_copy));
    if (!proxy_dir) {
        perror("strdup proxy_dir");
        goto cleanup;
    }

    int request_fds[2];
    int response_fds[2];
    if (pipe(request_fds) == -1 || pipe(response_fds) == -1) {
        perror("pipe");
        goto cleanup;
    }

    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        goto cleanup;
    }

    if (pid == 0) {
        close(request_fds[1]);
        close(response_fds[0]);
        execute_ssh_child(request_fds[0], response_fds[1], proxy_dir);
    } else {
        close(request_fds[0]);
        close(response_fds[1]);
        result = execute_proxy_parent(request_fds[1], response_fds[0], pid, argc, argv);
    }

cleanup:
    free(argv0_copy);
    free(proxy_dir);
    return result;
}
#endif
