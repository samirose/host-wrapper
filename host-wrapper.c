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
// is set.
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
#include <poll.h>
#include <fcntl.h>
#include <limits.h>

#include <stdarg.h>

#include "output.c"
#include "protocol.h"
#include "request.c"
#include "audit.c"
#include "allowlist.c"
#include "pty.c"
#include "wrapper.c"

/**
 * Reports on an allowlist, serving nothing. Returns 0 for a list the wrapper
 * will start on, or 125 for one it will refuse.
 */
int check_allowlist(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        log_error("fopen allowlist: %s\n", strerror(errno));
        return EXIT_WRAPPER_ERROR;
    }

    char *workspace = workspace_dir(path);
    if (!workspace) {
        fclose(fp);
        return EXIT_WRAPPER_ERROR;
    }

    int entries = validate_allowlist(fp, path, workspace);
    free(workspace);
    fclose(fp);
    if (entries < 0) return EXIT_WRAPPER_ERROR;

    printf("%s: %d entr%s, no problems found\n", path, entries,
           entries == 1 ? "y" : "ies");
    return 0;
}

void usage(const char *program) {
    fprintf(stderr, "Usage: %s [-l audit_log_path] [-n label] <allowlist_path>\n"
                    "       %s --check <allowlist_path>\n",
            program, program);
}

static int serve(int argc, char *argv[]) {
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

    if (validate_allowlist(fp, allowlist_path, workspace) < 0) {
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

int main(int argc, char *argv[]) {
    // A mode rather than an option: it serves no request, so it takes none of
    // the settings serving one needs. Matched here because POSIX getopt has no
    // long options.
    if (argc > 1 && strcmp(argv[1], "--check") == 0) {
        if (argc != 3) {
            usage(argv[0]);
            return EXIT_WRAPPER_ERROR;
        }
        return check_allowlist(argv[2]);
    }

    // Every outcome, refusals included, ends in a status frame, so a response
    // without one can only be a transport that failed.
    int ret = serve(argc, argv);
    char status[16];
    int len = snprintf(status, sizeof(status), "%d", ret);
    if (write_frame('x', status, (size_t)len) == -1) return EXIT_WRAPPER_ERROR;
    return ret;
}
