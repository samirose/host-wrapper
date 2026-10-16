#define MAX_ARGS 1024
#define MAX_ARG_LEN 65536

// The first netstring of every request; host-proxy.c writes the same string.
#define PROTOCOL_MAGIC "HW1"

// Shell convention: 0-124 belong to the target.
#define EXIT_WRAPPER_ERROR 125
#define EXIT_DENIED        126
#define EXIT_EXEC_FAILED   127

/**
 * Reads from buf when it is set, from fd otherwise.
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
 * Returns the next byte, EOF at the end of input, or -2 on a read error.
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
        return -2;
    }
}

/**
 * Returns the next netstring's data, malloc'd and NUL-terminated, with its
 * length in *out_len. Returns NULL having reported why.
 */
char* parse_netstring(ParserContext *ctx, size_t *out_len) {
    char len_buf[16];
    int i = 0;
    int c;

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

    if (i > 1 && len_buf[0] == '0') {
        log_error("Error: Netstring length has a leading zero\n");
        return NULL;
    }

    char *endptr;
    errno = 0;
    unsigned long long parsed_len = strtoull(len_buf, &endptr, 10);
    
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

    if (get_next_byte(ctx) != ',') {
        log_error("Error: Malformed netstring (expected ',')\n");
        free(data);
        return NULL;
    }

    if (out_len) *out_len = len;
    return data;
}

/**
 * Parses a terminal dimension: decimal digits only, 1 to USHRT_MAX, since it
 * ends up in a struct winsize. Returns the value, or -1.
 */
static int parse_dimension(const char *value) {
    long n = 0;
    if (*value == '\0') return -1;
    for (const char *p = value; *p; p++) {
        if (!isdigit((unsigned char)*p)) return -1;
        n = n * 10 + (*p - '0');
        if (n > USHRT_MAX) return -1;
    }
    return n > 0 ? (int)n : -1;
}

/**
 * Applies one key=value header option of len bytes to size. Returns 1, or 0
 * having reported why.
 */
static int apply_option(char *option, size_t len, TerminalSize *size,
                        int *seen_cols, int *seen_rows) {
    // An embedded NUL would let "cols=80\0junk" read as "cols=80".
    char *value = strchr(option, '=');
    if (strlen(option) != len || !value) {
        log_error("Error: Malformed header option\n");
        return 0;
    }
    *value++ = '\0';

    int *seen;
    int *field;
    if (strcmp(option, "cols") == 0) {
        seen = seen_cols;
        field = &size->cols;
    } else if (strcmp(option, "rows") == 0) {
        seen = seen_rows;
        field = &size->rows;
    } else {
        log_error("Error: Unknown header option '%s'\n", option);
        return 0;
    }
    if (*seen) {
        log_error("Error: Repeated header option '%s'\n", option);
        return 0;
    }
    if ((*field = parse_dimension(value)) == -1) {
        log_error("Error: Invalid header option '%s=%s'\n", option, value);
        return 0;
    }
    *seen = 1;
    return 1;
}

/**
 * Parses the header ahead of argv: the protocol magic, then key=value options
 * up to an empty netstring. A key is known or the request is refused, and none
 * may repeat, so the header cannot carry anything this wrapper would ignore.
 * Returns 0, or -1 having reported why.
 */
int parse_header(ParserContext *ctx, TerminalSize *size) {
    size->cols = 80;
    size->rows = 24;

    char *magic = parse_netstring(ctx, NULL);
    if (!magic) return -1;
    int matches = strcmp(magic, PROTOCOL_MAGIC) == 0;
    free(magic);
    if (!matches) {
        log_error("Error: protocol version mismatch: rebuild host-proxy\n");
        return -1;
    }

    int seen_cols = 0;
    int seen_rows = 0;
    for (;;) {
        size_t len;
        char *option = parse_netstring(ctx, &len);
        if (!option) return -1;
        if (len == 0) {
            free(option);
            return 0;
        }

        int ok = apply_option(option, len, size, &seen_cols, &seen_rows);
        free(option);
        if (!ok) return -1;
    }
}

void free_target_args(char **argv, int argc) {
    if (!argv) return;
    for (int i = 0; i < argc; i++) {
        if (argv[i]) free(argv[i]);
    }
    free(argv);
}

/**
 * Parses the argument count and the arguments following the header. Returns a
 * NULL-terminated argv, or NULL having reported why.
 */
char** parse_target_args(ParserContext *ctx, int *out_argc) {
    char *argc_str = NULL;
    char **target_argv = NULL;
    int target_argc = 0;

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

#ifndef FUZZING
static int write_frame(char tag, const void *data, size_t len) {
    char head[32];
    int head_len = snprintf(head, sizeof(head), "%zu:%c", len + 1, tag);
    if (write_all(STDOUT_FILENO, head, (size_t)head_len) == -1) return -1;
    if (write_all(STDOUT_FILENO, data, len) == -1) return -1;
    return write_all(STDOUT_FILENO, ",", 1);
}
#endif
