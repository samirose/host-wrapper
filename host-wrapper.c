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
#define _DARWIN_C_SOURCE
// glibc and musl hide cfmakeraw and openpty behind this once _POSIX_C_SOURCE
// is set; both are BSD extensions rather than POSIX.
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <libgen.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
#include <util.h>
#else
#include <pty.h>
#endif
#include <poll.h>
#include <fcntl.h>
#include <limits.h>

#include <stdarg.h>

#define MAX_ARGS 1024
#define MAX_ARG_LEN 65536

// Shell convention: 0-124 belong to the target.
#define EXIT_WRAPPER_ERROR 125
#define EXIT_DENIED        126
#define EXIT_EXEC_FAILED   127

/**
 * Logs an error to stderr. If FUZZING is defined, this is a no-op 
 * to ensure the fuzzer runs at maximum speed without I/O blocking.
 */
/**
 * Writes all of buf, retrying a partial write and EINTR. Returns 0, or -1 with
 * some of the data unwritten.
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
    (void)format; // Suppress unused parameter warning
#endif
}

/**
 * Creates the directories leading to path, each private to the user. The log
 * is placed rather than asked to follow a directory somebody prepared, so a
 * host that has never run the wrapper needs nothing set up by hand.
 */
int make_parent_dirs(const char *path) {
    char dir[PATH_MAX];
    if (snprintf(dir, sizeof(dir), "%s", path) >= (int)sizeof(dir)) {
        log_error("audit log %s: path too long\n", path);
        return -1;
    }

    char *last = strrchr(dir, '/');
    if (!last || last == dir) return 0; // The root, or the current directory.
    *last = '\0';

    // From the second byte, so that an absolute path does not begin with an
    // mkdir of the empty string.
    for (char *p = dir + 1; ; p++) {
        if (*p != '/' && *p != '\0') continue;
        char sep = *p;
        *p = '\0';
        if (mkdir(dir, 0700) == -1 && errno != EEXIST) {
            log_error("audit log directory %s: %s\n", dir, strerror(errno));
            return -1;
        }
        *p = sep;
        if (sep == '\0') return 0;
    }
}

/**
 * Where the trail goes when the forced command does not name a path: the
 * user's state directory, which is outside every workspace the wrapper can be
 * pointed at. Returns -1, having said why, when there is no such directory.
 */
int default_audit_path(char *buf, size_t size) {
    const char *state = getenv("XDG_STATE_HOME");
    int n;

    if (state && *state) {
        n = snprintf(buf, size, "%s/host-wrapper/audit.log", state);
    } else {
        const char *home = getenv("HOME");
        if (!home || !*home) {
            log_error("audit log: neither XDG_STATE_HOME nor HOME is set;"
                      " name one with -l\n");
            return -1;
        }
        n = snprintf(buf, size, "%s/.local/state/host-wrapper/audit.log", home);
    }

    if (n < 0 || (size_t)n >= size) {
        log_error("audit log: the default path is too long;"
                  " name one with -l\n");
        return -1;
    }
    return 0;
}

/**
 * Opens the audit trail for appending. Held open for the run, so that every
 * entry goes to the file this resolved, whatever happens to the path
 * afterwards. Returns -1, having said why, when the trail cannot be kept.
 */
int audit_open(const char *path) {
    if (make_parent_dirs(path) == -1) return -1;

    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd == -1) log_error("audit log %s: %s\n", path, strerror(errno));
    return fd;
}

/**
 * Who is on the other end, as sshd reports it: SSH_CONNECTION's first two
 * fields are the client address and port, and the rest describes this host.
 * Writes "-" when nothing started the wrapper over SSH.
 */
void audit_client(char *buf, size_t size) {
    const char *conn = getenv("SSH_CONNECTION");
    size_t n = 0;
    int spaces = 0;

    if (conn) {
        while (conn[n] && n + 1 < size) {
            if (conn[n] == ' ' && ++spaces == 2) break;
            n++;
        }
    }

    if (n == 0) {
        snprintf(buf, size, "-");
        return;
    }
    memcpy(buf, conn, n);
    buf[n] = '\0';
}

/**
 * What the trail records besides the request: which key the host is serving,
 * and which peer asked. Both are settled before a request is read.
 */
typedef struct AuditLog {
    int fd;
    const char *label;
    const char *client;
} AuditLog;

/**
 * Appends one execution event to the audit trail.
 */
void audit_log(const AuditLog *log, const char *status, int argc, char **argv) {
#ifndef FUZZING
    if (!log || log->fd == -1) return;

    char ts[64];
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    if (!t || strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", t) == 0) {
        snprintf(ts, sizeof(ts), "unknown time");
    }

    // An entry is as long as the argv it reports, so it is built in memory
    // rather than in a buffer sized for the longest one allowed.
    char *entry = NULL;
    size_t len = 0;
    FILE *mem = open_memstream(&entry, &len);
    if (!mem) return;

    fprintf(mem, "[%s] [%s] [%s] [%s]", ts, status, log->label, log->client);
    for (int i = 0; i < argc; i++) {
        fprintf(mem, " %s", argv[i]);
    }
    fprintf(mem, "\n");

    // One write to an O_APPEND descriptor: two wrappers logging at the same
    // moment interleave entries, never the bytes of one.
    if (fclose(mem) == 0) write_all(log->fd, entry, len);
    free(entry);
#else
    (void)log; (void)status; (void)argc; (void)argv;
#endif
}

/**
 * Parser context to allow reading from either a file descriptor or memory buffer.
 */
typedef struct {
    int fd;
    const unsigned char *buf;
    size_t size;
    size_t pos;
} ParserContext;

typedef struct {
    int cols;
    int rows;
} TerminalSize;

/**
 * Reads a single byte from the context source.
 */
int get_next_byte(ParserContext *ctx) {
    if (ctx->buf) {
        if (ctx->pos < ctx->size) {
            return (int)ctx->buf[ctx->pos++];
        }
        return EOF;
    }

    unsigned char c;
    while (1) {
        ssize_t n = read(ctx->fd, &c, 1);
        if (n == 1) return (int)c;
        if (n == 0) return EOF;
        if (errno == EINTR) continue;
        return -2; // Error
    }
}

/**
 * Parses a single netstring from the context.
 * Format: [length]:[data],
 */
char* parse_netstring(ParserContext *ctx, size_t *out_len) {
    char len_buf[16];
    int i = 0;
    int c;

    // Read length digits
    while ((c = get_next_byte(ctx)) >= 0 && isdigit(c)) {
        if (i < (int)sizeof(len_buf) - 1) {
            len_buf[i++] = (char)c;
        } else {
            log_error("Error: Netstring length too long\n");
            return NULL;
        }
    }
    len_buf[i] = '\0';

    if (c != ':') {
        log_error("Error: Malformed netstring (expected ':')\n");
        return NULL;
    }

    char *endptr;
    errno = 0;
    unsigned long long parsed_len = strtoull(len_buf, &endptr, 10);
    
    // Check for overflow or no digits parsed
    if (errno == ERANGE || endptr == len_buf || *endptr != '\0') {
        log_error("Error: Invalid netstring length format\n");
        return NULL;
    }

    size_t len = (size_t)parsed_len;
    if (len > MAX_ARG_LEN) {
        log_error("Error: Argument too long (%zu bytes)\n", len);
        return NULL;
    }

    char *data = malloc(len + 1);
    if (!data) {
        log_error("malloc: %s\n", strerror(errno));
        return NULL;
    }

    // Read exact number of data bytes
    for (size_t j = 0; j < len; j++) {
        c = get_next_byte(ctx);
        if (c < 0) {
            log_error("Error: Unexpected EOF or error in netstring data\n");
            free(data);
            return NULL;
        }
        data[j] = (char)c;
    }
    data[len] = '\0';

    // Final trailing comma
    if (get_next_byte(ctx) != ',') {
        log_error("Error: Malformed netstring (expected ',')\n");
        free(data);
        return NULL;
    }

    if (out_len) *out_len = len;
    return data;
}

/**
 * Resolves a command to the absolute path of the file to run: either named
 * absolutely, or relative to the allowlist directory, which is where the
 * target runs. Allowlist entries and requests go through this, so the string
 * compared is the file executed, and nothing is searched for on PATH.
 *
 * Returns a malloc'd path, or NULL with *why set to the reason it names no
 * single file.
 */
char* resolve_command(const char *path, const char *workspace, const char **why) {
    *why = NULL;
    if (!path || !*path) {
        *why = "is empty";
        return NULL;
    }

    // A ".." component makes the text and the file two different things again,
    // whichever side of the comparison it appears on.
    //
    // The conjunct order is important: each index is reached only once the
    // byte before it has tested non-NUL, so the furthest read is the
    // terminator. Reordering these tests would read past the string.
    for (const char *p = path; *p; p++) {
        if ((p == path || p[-1] == '/') && p[0] == '.' && p[1] == '.' &&
            (p[2] == '/' || p[2] == '\0')) {
            *why = "contains a '..' component";
            return NULL;
        }
    }

    if (path[0] == '/') return strdup(path);

    if (!strchr(path, '/')) {
        *why = "has no directory; write it absolutely,"
               " or prefix ./ for the allowlist directory";
        return NULL;
    }

    while (path[0] == '.' && path[1] == '/') path += 2;
    if (!*path) {
        *why = "names a directory, not a command";
        return NULL;
    }

    size_t len = strlen(workspace) + 1 + strlen(path) + 1;
    char *resolved = malloc(len);
    if (!resolved) return NULL;
    snprintf(resolved, len, "%s/%s", workspace, path);
    return resolved;
}

/**
 * Checks if the given command is present and enabled in the allowlist file.
 * The allowlist supports comments (#) and empty lines.
 */
typedef struct {
    int allowed;
    int has_stdin;
} AllowlistResult;

/**
 * Checks if the given command is present and enabled in the allowlist file.
 * The allowlist supports comments (#) and empty lines.
 */
/**
 * Reduces one allowlist line, in place, to the command it names, and reports
 * the options set on it. Returns NULL for a blank or comment-only line.
 */
char* allowlist_entry(char *line, int *has_stdin) {
    *has_stdin = 0;

    // Strip newline
    line[strcspn(line, "\r\n")] = 0;

    char *p = line;
    // Skip leading whitespace
    while (isspace(*p)) p++;

    // Handle inline comments: find the first '#' and truncate the string there
    char *comment = strchr(p, '#');
    if (comment) {
        *comment = '\0';
    }

    // If the line is empty after stripping comments/whitespace, skip it
    if (*p == '\0') return NULL;

    // Strip trailing whitespace
    char *end = p + strlen(p) - 1;
    while (end > p && isspace(*end)) {
        *end = '\0';
        end--;
    }

    char *saveptr;
    char *cmd_token = strtok_r(p, " \t\r\n", &saveptr);
    if (!cmd_token) return NULL;

    char *token;
    while ((token = strtok_r(NULL, " \t\r\n", &saveptr)) != NULL) {
        if (strcmp(token, "+stdin") == 0) {
            *has_stdin = 1;
        }
    }
    return cmd_token;
}

/**
 * cmd is the request already resolved, so both sides of the comparison have
 * been through resolve_command.
 */
AllowlistResult check_allowed(const char *cmd, FILE *fp, const char *workspace) {
    AllowlistResult res = { .allowed = 0, .has_stdin = 0 };
    if (!fp) return res;

    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;

    while ((linelen = getline(&line, &linecap, fp)) > 0) {
        int line_has_stdin;
        char *cmd_token = allowlist_entry(line, &line_has_stdin);
        if (!cmd_token) continue;

        // Resolved here rather than taken on trust from the startup pass: an
        // entry that does not resolve cannot match, whatever that pass saw.
        const char *why;
        char *resolved = resolve_command(cmd_token, workspace, &why);
        if (!resolved) continue;

        int match = strcmp(cmd, resolved) == 0;
        free(resolved);

        if (match) {
            res.allowed = 1;
            res.has_stdin = line_has_stdin;
            break;
        }
    }

    free(line);
    return res;
}

/**
 * Reports every allowlist entry that names no single file, so the wrapper can
 * refuse to serve a request against a list it cannot enforce. Leaves the
 * stream rewound for the lookup. Returns 0 when every entry is usable.
 *
 * Reading the list twice is not a check-then-use window. The lookup reads the
 * same open stream, so the file cannot be swapped underneath it, and it
 * resolves every entry itself rather than trusting what this pass saw. That
 * makes this a startup diagnostic: it fails the whole list loudly, where the
 * lookup would only ever skip the offending line.
 */
int validate_allowlist(FILE *fp, const char *path, const char *workspace) {
    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;
    int lineno = 0;
    int bad = 0;

    while ((linelen = getline(&line, &linecap, fp)) > 0) {
        int line_has_stdin;
        lineno++;
        char *cmd_token = allowlist_entry(line, &line_has_stdin);
        if (!cmd_token) continue;

        const char *why;
        char *resolved = resolve_command(cmd_token, workspace, &why);
        if (resolved) {
            free(resolved);
            continue;
        }
        log_error("Error: %s:%d: '%s' %s\n", path, lineno, cmd_token,
                  why ? why : "cannot be resolved");
        bad = 1;
    }

    free(line);
    rewind(fp);
    return bad ? -1 : 0;
}

/**
 * Frees the reconstructed argv array and its elements.
 */
void free_target_args(char **argv, int argc) {
    if (!argv) return;
    for (int i = 0; i < argc; i++) {
        if (argv[i]) free(argv[i]);
    }
    free(argv);
}

/**
 * Parses the netstring header to reconstruct the target argc and argv.
 * Returns the argv array on success, or NULL on error.
 */
char** parse_target_args(ParserContext *ctx, int *out_argc) {
    char *argc_str = NULL;
    char **target_argv = NULL;
    int target_argc = 0;

    // 1. Parse target argc string from netstring
    size_t dummy_len;
    argc_str = parse_netstring(ctx, &dummy_len);
    if (!argc_str) return NULL;

    char *endptr;
    errno = 0;
    long target_argc_long = strtol(argc_str, &endptr, 10);
    
    if (errno == ERANGE || endptr == argc_str || *endptr != '\0') {
        log_error("Error: Invalid target argc format\n");
        goto cleanup;
    }
    
    target_argc = (int)target_argc_long;
    if (target_argc <= 0 || target_argc > MAX_ARGS) {
        log_error("Error: Invalid target argc (%d)\n", target_argc);
        goto cleanup;
    }

    // 2. Parse target argv array
    target_argv = calloc((size_t)target_argc + 1, sizeof(char *));
    if (!target_argv) {
        log_error("calloc: %s\n", strerror(errno));
        goto cleanup;
    }

    for (int i = 0; i < target_argc; i++) {
        target_argv[i] = parse_netstring(ctx, NULL);
        if (!target_argv[i]) {
            free_target_args(target_argv, i);
            target_argv = NULL;
            goto cleanup;
        }
    }
    target_argv[target_argc] = NULL;

    if (out_argc) *out_argc = target_argc;

cleanup:
    free(argc_str);
    return target_argv;
}

/**
 * The directory holding the allowlist: both where the target runs and what a
 * relative command resolves against. Canonical, so that how the forced command
 * happened to spell the allowlist path does not change which string a relative
 * entry resolves to. Returns a malloc'd path, or NULL on error.
 */
char* workspace_dir(const char *allowlist_path) {
    char *path_copy = strdup(allowlist_path);
    if (!path_copy) {
        log_error("strdup: %s\n", strerror(errno));
        return NULL;
    }

    char resolved[PATH_MAX];
    char *workspace = NULL;
    if (realpath(dirname(path_copy), resolved)) {
        workspace = strdup(resolved);
    }

    free(path_copy);
    if (!workspace) log_error("allowlist directory: %s\n", strerror(errno));
    return workspace;
}

#ifndef FUZZING

/**
 * Forwards everything readable on a PTY master to out_fd. Returns 1 once the
 * stream is finished, 0 while it may still yield more, -1 on a write failure.
 * master_fd must be O_NONBLOCK: a pass ends on EAGAIN, which a blocking read
 * would never report.
 *
 * Linux raises POLLHUP on a master as soon as the slave closes, with whatever
 * the target wrote still buffered behind it, so only a read may retire a
 * stream. A drained master reports EIO on Linux and a zero read on macOS; both
 * mean end of output.
 */
static int drain_pty(int master_fd, int out_fd, const char *name) {
    unsigned char buf[4096];

    for (;;) {
        ssize_t n = read(master_fd, buf, sizeof(buf));
        if (n > 0) {
            if (write_all(out_fd, buf, (size_t)n) == -1) {
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
 * Spawns the target process inside dual PTY streams (stdout and stderr separated)
 * and enters a poll loop to forward output. Returns the target command's exit code.
 */
int execute_command_with_pty(const char *exec_path, char **target_argv, int target_argc, TerminalSize termsize, int has_stdin) {
    int ret = EXIT_WRAPPER_ERROR;
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

    // Draining a master to EOF means reading past the point where a blocking
    // read would stall waiting for the next write.
    if (fcntl(master_out, F_SETFL, O_NONBLOCK) == -1 ||
        fcntl(master_err, F_SETFL, O_NONBLOCK) == -1) {
        log_error("fcntl O_NONBLOCK: %s\n", strerror(errno));
        goto execution_cleanup;
    }

    // Set both PTYs to raw mode
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
        // Child:
        dup2(slave_out, STDOUT_FILENO);
        dup2(slave_err, STDERR_FILENO);
        
        // Handle stdin option
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

    // Parent:
    close(slave_out); slave_out = -1;
    close(slave_err); slave_err = -1;

    // Where each master's output goes, indexed in step with fds below.
    static const struct {
        int out_fd;
        const char *name;
    } streams[] = {
        { STDOUT_FILENO, "stdout" },
        { STDERR_FILENO, "stderr" },
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

            int drained = drain_pty(fds[i].fd, streams[i].out_fd, streams[i].name);
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

#endif // #ifndef FUZZING

/**
 * Parses the terminal window size netstring from the context (format: "cols,rows").
 * Returns a TerminalSize struct, defaulting to 80x24 on error or absence.
 */
TerminalSize parse_terminal_size(ParserContext *ctx) {
    TerminalSize size = { .cols = 80, .rows = 24 };
    char *winsize_str = parse_netstring(ctx, NULL);
    if (winsize_str) {
        char *comma = strchr(winsize_str, ',');
        if (comma) {
            *comma = '\0';
            char *endptr1;
            char *endptr2;
            long parsed_cols = strtol(winsize_str, &endptr1, 10);
            long parsed_rows = strtol(comma + 1, &endptr2, 10);
            if (endptr1 != winsize_str && *endptr1 == '\0' &&
                endptr2 != (comma + 1) && *endptr2 == '\0' &&
                parsed_cols > 0 && parsed_rows > 0) {
                size.cols = (int)parsed_cols;
                size.rows = (int)parsed_rows;
            }
        }
        free(winsize_str);
    }
    return size;
}

int run_wrapper(ParserContext *ctx, FILE *allowlist_fp, const AuditLog *audit,
                const char *workspace) {
    int ret = EXIT_WRAPPER_ERROR;
    char **target_argv = NULL;
    char *exec_path = NULL;
    int target_argc = 0;

    TerminalSize termsize = parse_terminal_size(ctx);
    target_argv = parse_target_args(ctx, &target_argc);
    if (!target_argv) return EXIT_WRAPPER_ERROR;

    const char *why;
    exec_path = resolve_command(target_argv[0], workspace, &why);
    if (!exec_path) {
        log_error("Error: Command '%s' %s\n", target_argv[0],
                  why ? why : "cannot be resolved");
        audit_log(audit, "DENIED ", target_argc, target_argv);
        ret = EXIT_DENIED;
        goto cleanup;
    }

    AllowlistResult allow_res = check_allowed(exec_path, allowlist_fp, workspace);
    if (!allow_res.allowed) {
        log_error("Error: Command '%s' not in allowlist\n", target_argv[0]);
        audit_log(audit, "DENIED ", target_argc, target_argv);
        ret = EXIT_DENIED;
        goto cleanup;
    }

    audit_log(audit, "ALLOWED", target_argc, target_argv);

#ifndef FUZZING
    // The target runs in the allowlist directory, so its arguments can name
    // paths relative to it.
    if (chdir(workspace) != 0) {
        log_error("chdir to %s: %s\n", workspace, strerror(errno));
        goto cleanup;
    }

    ret = execute_command_with_pty(exec_path, target_argv, target_argc, termsize,
                                   allow_res.has_stdin);
#else
    (void)audit;
    (void)termsize;
    ret = 0; // Success in fuzzing mode
#endif

cleanup:
    free(exec_path);
    free_target_args(target_argv, target_argc);
    return ret;
}

#ifndef FUZZING
void usage(const char *program) {
    fprintf(stderr, "Usage: %s [-l audit_log_path] [-n label] <allowlist_path>\n",
            program);
}

int main(int argc, char *argv[]) {
    const char *log_path = NULL;
    const char *label = "-";
    int opt;

    // Options come from the forced command in authorized_keys, so they are the
    // host's settings for this key and never the guest's.
    while ((opt = getopt(argc, argv, "l:n:")) != -1) {
        switch (opt) {
        case 'l': log_path = optarg; break;
        case 'n': label = optarg; break;
        default:  usage(argv[0]); return EXIT_WRAPPER_ERROR;
        }
    }

    if (optind >= argc) {
        usage(argv[0]);
        return EXIT_WRAPPER_ERROR;
    }
    const char *allowlist_path = argv[optind];

    FILE *fp = fopen(allowlist_path, "r");
    if (!fp) {
        log_error("fopen allowlist: %s\n", strerror(errno));
        return EXIT_WRAPPER_ERROR;
    }

    char *workspace = workspace_dir(allowlist_path);
    if (!workspace) {
        fclose(fp);
        return EXIT_WRAPPER_ERROR;
    }

    if (validate_allowlist(fp, allowlist_path, workspace) != 0) {
        free(workspace);
        fclose(fp);
        return EXIT_WRAPPER_ERROR;
    }

    // Opened here, before the target's working directory is entered, so that
    // the trail can live somewhere the target has no way to reach.
    char default_path[PATH_MAX];
    if (!log_path) {
        if (default_audit_path(default_path, sizeof(default_path)) == -1) {
            free(workspace);
            fclose(fp);
            return EXIT_WRAPPER_ERROR;
        }
        log_path = default_path;
    }

    // A request served without a trail is a request nobody can account for.
    int audit_fd = audit_open(log_path);
    if (audit_fd == -1) {
        free(workspace);
        fclose(fp);
        return EXIT_WRAPPER_ERROR;
    }

    ParserContext ctx = { .fd = STDIN_FILENO, .buf = NULL, .size = 0, .pos = 0 };
    // Settled before a request is read: the trail says which key the host is
    // serving and which peer asked, neither of which the guest chooses.
    char client[128];
    audit_client(client, sizeof(client));
    AuditLog audit = { .fd = audit_fd, .label = label, .client = client };

    int ret = run_wrapper(&ctx, fp, &audit, workspace);
    close(audit_fd);
    free(workspace);
    fclose(fp);
    return ret;
}
#endif
