/**
 * Creates the directories leading to path, each mode 0700. Returns 0, or -1
 * having reported why.
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
 * Writes the default audit log path, under XDG_STATE_HOME or else
 * ~/.local/state, into buf. Returns 0, or -1 having reported why.
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
 * Opens path for appending, creating it and its directories. Returns the
 * descriptor, or -1 having reported why.
 */
int audit_open(const char *path) {
    if (make_parent_dirs(path) == -1) return -1;

    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd == -1) log_error("audit log %s: %s\n", path, strerror(errno));
    return fd;
}

/**
 * Writes the client address and port, the first two fields of SSH_CONNECTION,
 * into buf, or "-" when it is unset.
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
 * and which peer asked.
 */
typedef struct AuditLog {
    int fd;
    const char *label;
    const char *client;
} AuditLog;

/**
 * Writes arg with control bytes as \xNN and backslash doubled, so that no
 * argument can forge an entry.
 */
static void audit_write_arg(FILE *out, const char *arg) {
    for (const unsigned char *p = (const unsigned char *)arg; *p; p++) {
        if (*p == '\\') {
            fputs("\\\\", out);
        } else if (*p < 0x20 || *p == 0x7f) {
            fprintf(out, "\\x%02x", *p);
        } else {
            fputc(*p, out);
        }
    }
}

/**
 * Appends one entry to the audit trail. Returns 0, or -1 on failure.
 */
int audit_log(const AuditLog *log, const char *status, int argc, char **argv) {
    if (!log || log->fd == -1) return -1;

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
    if (!mem) {
        log_error("audit log: %s\n", strerror(errno));
        return -1;
    }

    fprintf(mem, "[%s] [%s] [%s] [%s]", ts, status, log->label, log->client);
    for (int i = 0; i < argc; i++) {
        fputc(' ', mem);
        audit_write_arg(mem, argv[i]);
    }
    fprintf(mem, "\n");

    // One write to an O_APPEND descriptor: two wrappers logging at the same
    // moment interleave entries, never the bytes of one.
    int written = (fclose(mem) == 0) ? write_all(log->fd, entry, len) : -1;
    if (written == -1) log_error("audit log: %s\n", strerror(errno));
    free(entry);
    return written;
}
