#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <libgen.h>
#include <time.h>

#include <stdarg.h>

#define MAX_ARGS 1024
#define MAX_ARG_LEN 65536

/**
 * Logs an error to stderr. If FUZZING is defined, this is a no-op 
 * to ensure the fuzzer runs at maximum speed without I/O blocking.
 */
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
 * Logs an execution event to host-wrapper.log in the allowlist directory.
 */
void audit_log(const char *status, int argc, char **argv, const char *allowlist_path) {
#ifndef FUZZING
    char log_path[MAX_ARG_LEN];
    char *path_copy = strdup(allowlist_path);
    if (!path_copy) return;
    
    char *dir = dirname(path_copy);
    snprintf(log_path, sizeof(log_path), "%s/host-wrapper.log", dir);
    free(path_copy);

    FILE *fp = fopen(log_path, "a");
    if (!fp) return;

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char ts[64];
    if (t) {
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", t);
    } else {
        snprintf(ts, sizeof(ts), "unknown time");
    }

    fprintf(fp, "[%s] [%s]", ts, status);
    for (int i = 0; i < argc; i++) {
        fprintf(fp, " %s", argv[i]);
    }
    fprintf(fp, "\n");
    fclose(fp);
#else
    (void)status; (void)argc; (void)argv; (void)allowlist_path;
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
 * Checks if the given command is present and enabled in the allowlist file.
 * The allowlist supports comments (#) and empty lines.
 */
int is_allowed(const char *cmd, FILE *fp) {
    if (!fp) return 0;

    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;
    int allowed = 0;

    while ((linelen = getline(&line, &linecap, fp)) > 0) {
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
        if (*p == '\0') continue;

        // Strip trailing whitespace
        char *end = p + strlen(p) - 1;
        while (end > p && isspace(*end)) {
            *end = '\0';
            end--;
        }

        if (strcmp(cmd, p) == 0) {
            allowed = 1;
            break;
        }
    }

    free(line);
    return allowed;
}

int run_wrapper(ParserContext *ctx, FILE *allowlist_fp, const char *allowlist_path) {
    int ret = 1;
    char *argc_str = NULL;
    char **target_argv = NULL;
    int target_argc = 0;

    // 1. Parse target argc
    size_t dummy_len;
    argc_str = parse_netstring(ctx, &dummy_len);
    if (!argc_str) goto cleanup;

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
        if (!target_argv[i]) goto cleanup;
    }
    target_argv[target_argc] = NULL;

    // 3. Validation
    if (!is_allowed(target_argv[0], allowlist_fp)) {
        log_error("Error: Command '%s' not in allowlist\n", target_argv[0]);
        audit_log("DENIED ", target_argc, target_argv, allowlist_path);
        goto cleanup;
    }

    audit_log("ALLOWED", target_argc, target_argv, allowlist_path);

    // 4. Execution
#ifndef FUZZING
    // Change working directory to the folder containing the allowlist
    // before execution, so commands can use relative paths.
    char *path_copy = strdup(allowlist_path);
    if (!path_copy) {
        log_error("strdup: %s\n", strerror(errno));
        goto cleanup;
    }
    char *dir = dirname(path_copy);
    if (chdir(dir) != 0) {
        log_error("chdir to %s: %s\n", dir, strerror(errno));
        free(path_copy);
        goto cleanup;
    }
    free(path_copy);

    execvp(target_argv[0], target_argv);
    log_error("execvp: %s\n", strerror(errno));
#else
    (void)allowlist_path;
    ret = 0; // Success in fuzzing mode
#endif

cleanup:
    if (argc_str) free(argc_str);
    if (target_argv) {
        for (int i = 0; i < target_argc; i++) {
            if (target_argv[i]) free(target_argv[i]);
        }
        free(target_argv);
    }
    return ret;
}

#ifndef FUZZING
int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <allowlist_path>\n", argv[0]);
        return 1;
    }
    const char *allowlist_path = argv[1];

    FILE *fp = fopen(allowlist_path, "r");
    if (!fp) {
        log_error("fopen allowlist: %s\n", strerror(errno));
        return 1;
    }

    ParserContext ctx = { .fd = STDIN_FILENO, .buf = NULL, .size = 0, .pos = 0 };
    int ret = run_wrapper(&ctx, fp, allowlist_path);
    fclose(fp);
    return ret;
}
#endif
