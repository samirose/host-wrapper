/**
 * Resolves a command to the absolute path of the file to run: either named
 * absolutely, or relative to the allowlist directory, which is where the
 * target runs.
 *
 * Returns a malloc'd path, or NULL with *why set to the reason, or with *why
 * NULL when out of memory.
 */
static char* resolve_command(const char *path, const char *workspace, const char **why) {
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

/**
 * Reduces one allowlist line, in place, to the command it names, and reports
 * the options set on it. Returns NULL for a blank or comment-only line.
 *
 * *bad_option is the first token that is not an option this wrapper knows, and
 * points into line.
 */
static char* allowlist_entry(char *line, int *has_stdin, const char **bad_option) {
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

typedef struct {
    char *path;
    int has_stdin;
} AllowlistEntry;

typedef struct {
    AllowlistEntry *entries;
    size_t count;
} Allowlist;

static void free_allowlist(Allowlist *list) {
    for (size_t i = 0; i < list->count; i++) free(list->entries[i].path);
    free(list->entries);
    list->entries = NULL;
    list->count = 0;
}

/**
 * Reads the allowlist from fp into list, each entry's command resolved.
 *
 * Returns 0, or -1 with list empty, having reported every entry the wrapper
 * cannot enforce as written, or having run out of memory.
 */
static int load_allowlist(FILE *fp, const char *path, const char *workspace,
                          Allowlist *list) {
    char *line = NULL;
    size_t linecap = 0;
    size_t capacity = 0;
    int lineno = 0;
    int bad = 0;

    list->entries = NULL;
    list->count = 0;

    while (getline(&line, &linecap, fp) > 0) {
        int has_stdin;
        const char *bad_option;
        lineno++;
        char *cmd_token = allowlist_entry(line, &has_stdin, &bad_option);
        if (!cmd_token) continue;

        if (bad_option) {
            log_error("Error: %s:%d: unknown option '%s'\n", path, lineno,
                      bad_option);
            bad = 1;
        }

        const char *why;
        char *resolved = resolve_command(cmd_token, workspace, &why);
        if (!resolved) {
            log_error("Error: %s:%d: '%s' %s\n", path, lineno, cmd_token,
                      why ? why : "cannot be resolved");
            bad = 1;
            continue;
        }
        if (bad) {
            free(resolved);
            continue;
        }

        if (list->count == capacity) {
            size_t grown = capacity ? capacity * 2 : 16;
            AllowlistEntry *entries = realloc(list->entries,
                                              grown * sizeof(*entries));
            if (!entries) {
                log_error("realloc: %s\n", strerror(errno));
                free(resolved);
                bad = 1;
                break;
            }
            list->entries = entries;
            capacity = grown;
        }
        list->entries[list->count++] =
            (AllowlistEntry){ .path = resolved, .has_stdin = has_stdin };
    }

    free(line);
    if (bad) {
        free_allowlist(list);
        return -1;
    }
    return 0;
}

/**
 * Returns the first entry naming cmd, a resolved path, or NULL.
 */
static const AllowlistEntry* find_entry(const Allowlist *list, const char *cmd) {
    for (size_t i = 0; i < list->count; i++) {
        if (strcmp(list->entries[i].path, cmd) == 0) return &list->entries[i];
    }
    return NULL;
}

/**
 * Returns the directory holding the allowlist, canonical and malloc'd, or NULL
 * having reported why. Canonical, so that how the forced command spells the
 * allowlist path does not change what a relative entry resolves to.
 */
static char* workspace_dir(const char *allowlist_path) {
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
