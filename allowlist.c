/**
 * Resolves a command to the absolute path of the file to run: either named
 * absolutely, or relative to the allowlist directory, which is where the
 * target runs.
 *
 * Returns a malloc'd path, or NULL with *why set to the reason, or with *why
 * NULL when out of memory.
 */
char* resolve_command(const char *path, const char *workspace, const char **why) {
    *why = NULL;
    if (!path || !*path) {
        *why = "is empty";
        return NULL;
    }

    // A ".." component would make the string compared and the file run two
    // different things. Each index is read only once the byte before it has
    // tested non-NUL, so reordering these tests would read past the string.
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

typedef struct {
    int allowed;
    int has_stdin;
} AllowlistResult;

/**
 * Reduces one allowlist line, in place, to the command it names, and reports
 * the options set on it. Returns NULL for a blank or comment-only line.
 *
 * *bad_option is the first token that is not an option this wrapper knows, and
 * points into line.
 */
char* allowlist_entry(char *line, int *has_stdin, const char **bad_option) {
    *has_stdin = 0;
    *bad_option = NULL;

    line[strcspn(line, "\r\n")] = 0;

    char *p = line;
    while (isspace(*p)) p++;

    char *comment = strchr(p, '#');
    if (comment) {
        *comment = '\0';
    }

    if (*p == '\0') return NULL;

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
        } else if (!*bad_option) {
            *bad_option = token;
        }
    }
    return cmd_token;
}

/**
 * Looks up cmd, a resolved path, in the allowlist. An entry carrying an
 * unknown option never matches.
 */
AllowlistResult check_allowed(const char *cmd, FILE *fp, const char *workspace) {
    AllowlistResult res = { .allowed = 0, .has_stdin = 0 };
    if (!fp) return res;

    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;

    while ((linelen = getline(&line, &linecap, fp)) > 0) {
        int line_has_stdin;
        const char *bad_option;
        char *cmd_token = allowlist_entry(line, &line_has_stdin, &bad_option);
        if (!cmd_token || bad_option) continue;

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
 * Reports every allowlist entry the wrapper cannot enforce as written, and
 * rewinds fp. Returns the number of entries, or -1 if any is unusable.
 *
 * This is not a check-then-use window: the lookup reads the same stream and
 * resolves every entry itself, so this pass only decides whether to start.
 */
int validate_allowlist(FILE *fp, const char *path, const char *workspace) {
    char *line = NULL;
    size_t linecap = 0;
    ssize_t linelen;
    int lineno = 0;
    int entries = 0;
    int bad = 0;

    while ((linelen = getline(&line, &linecap, fp)) > 0) {
        int line_has_stdin;
        const char *bad_option;
        lineno++;
        char *cmd_token = allowlist_entry(line, &line_has_stdin, &bad_option);
        if (!cmd_token) continue;
        entries++;

        if (bad_option) {
            log_error("Error: %s:%d: unknown option '%s'\n", path, lineno,
                      bad_option);
            bad = 1;
        }

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
    return bad ? -1 : entries;
}

/**
 * Returns the directory holding the allowlist, canonical and malloc'd, or NULL
 * having reported why. Canonical, so that how the forced command spells the
 * allowlist path does not change what a relative entry resolves to.
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
