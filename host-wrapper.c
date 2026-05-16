#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>

#define MAX_ARGS 1024
#define MAX_ARG_LEN 65536

/**
 * Reads a single byte from stdin (file descriptor 0) without buffering.
 * This is crucial because standard C buffering (like getchar or fread) 
 * would consume bytes intended for the target command.
 */
int read_byte() {
    unsigned char c;
    while (1) {
        ssize_t n = read(0, &c, 1);
        if (n == 1) return (int)c;
        if (n == 0) return EOF;
        if (errno == EINTR) continue;
        return -2; // Error
    }
}

/**
 * Parses a single netstring from stdin.
 * Format: [length]:[data],
 */
char* parse_netstring(size_t *out_len) {
    char len_buf[16];
    int i = 0;
    int c;

    // Read length digits
    while ((c = read_byte()) >= 0 && isdigit(c)) {
        if (i < (int)sizeof(len_buf) - 1) {
            len_buf[i++] = (char)c;
        } else {
            fprintf(stderr, "Error: Netstring length too long\n");
            return NULL;
        }
    }
    len_buf[i] = '\0';

    if (c != ':') {
        fprintf(stderr, "Error: Malformed netstring (expected ':')\n");
        return NULL;
    }

    char *endptr;
    errno = 0;
    unsigned long long parsed_len = strtoull(len_buf, &endptr, 10);
    
    // Check for overflow or no digits parsed
    if (errno == ERANGE || endptr == len_buf || *endptr != '\0') {
        fprintf(stderr, "Error: Invalid netstring length format\n");
        return NULL;
    }

    size_t len = (size_t)parsed_len;
    if (len > MAX_ARG_LEN) {
        fprintf(stderr, "Error: Argument too long (%zu bytes)\n", len);
        return NULL;
    }

    char *data = malloc(len + 1);
    if (!data) {
        perror("malloc");
        return NULL;
    }

    // Read exact number of data bytes
    for (size_t j = 0; j < len; j++) {
        c = read_byte();
        if (c < 0) {
            fprintf(stderr, "Error: Unexpected EOF or error in netstring data\n");
            free(data);
            return NULL;
        }
        data[j] = (char)c;
    }
    data[len] = '\0';

    // Final trailing comma
    if (read_byte() != ',') {
        fprintf(stderr, "Error: Malformed netstring (expected ',')\n");
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
int is_allowed(const char *cmd, const char *allowlist_path) {
    FILE *fp = fopen(allowlist_path, "r");
    if (!fp) {
        perror("fopen allowlist");
        return 0;
    }

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
    fclose(fp);
    return allowed;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <allowlist_path>\n", argv[0]);
        return 1;
    }
    const char *allowlist_path = argv[1];

    // 1. Parse target argc
    size_t dummy_len;
    char *argc_str = parse_netstring(&dummy_len);
    if (!argc_str) return 1;

    char *endptr;
    errno = 0;
    long target_argc_long = strtol(argc_str, &endptr, 10);
    
    if (errno == ERANGE || endptr == argc_str || *endptr != '\0') {
        fprintf(stderr, "Error: Invalid target argc format\n");
        free(argc_str);
        return 1;
    }
    
    int target_argc = (int)target_argc_long;
    free(argc_str);

    if (target_argc <= 0 || target_argc > MAX_ARGS) {
        fprintf(stderr, "Error: Invalid target argc (%d)\n", target_argc);
        return 1;
    }

    // 2. Parse target argv array
    char **target_argv = calloc((size_t)target_argc + 1, sizeof(char *));
    if (!target_argv) {
        perror("calloc");
        return 1;
    }

    for (int i = 0; i < target_argc; i++) {
        target_argv[i] = parse_netstring(NULL);
        if (!target_argv[i]) return 1;
    }
    target_argv[target_argc] = NULL;

    // 3. Validation
    if (!is_allowed(target_argv[0], allowlist_path)) {
        fprintf(stderr, "Error: Command '%s' not in allowlist\n", target_argv[0]);
        // Cleanup parsed strings before exit
        for (int i = 0; i < target_argc; i++) free(target_argv[i]);
        free(target_argv);
        return 1;
    }

    // 4. Execution
    // The kernel will replace this process image. 
    // Stdin (fd 0) is positioned exactly after the header.
    execvp(target_argv[0], target_argv);

    // If execvp returns, an error occurred
    perror("execvp");
    
    // Cleanup
    for (int i = 0; i < target_argc; i++) free(target_argv[i]);
    free(target_argv);
    return 1;
}
