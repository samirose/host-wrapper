#define _POSIX_C_SOURCE 200809L
#define FUZZING
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <libgen.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>

// host-wrapper.c without main, and without execute.c: the fuzzer runs nothing.
#include "output.c"
#include "protocol.h"
#include "request.c"
#include "audit.c"
#include "allowlist.c"
#include "wrapper.c"

static AuditLog audit = { .fd = -1, .label = "fuzz", .client = "-" };

static char uname_path[] = "/usr/bin/uname";
static AllowlistEntry uname_entry = { .path = uname_path };
static const Allowlist default_allowlist = { .entries = &uname_entry, .count = 1 };

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    audit.fd = open("/dev/null", O_WRONLY);
    if (audit.fd == -1) abort();
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    if (Size < 2) return 0;

    // The first byte is the allowlist's length, so the fuzzer controls the
    // split directly.
    size_t allowlist_size = Data[0];
    if (allowlist_size > Size - 1) {
        allowlist_size = Size - 1;
    }

    const uint8_t *allowlist_data = Data + 1;
    const uint8_t *netstring_data = Data + 1 + allowlist_size;
    size_t netstring_size = Size - 1 - allowlist_size;

    // A list main would refuse to start on still lets the request half be
    // fuzzed, against the default list.
    Allowlist loaded = { .entries = NULL, .count = 0 };
    const Allowlist *allowlist = &default_allowlist;
    FILE *allowlist_fp = allowlist_size > 0
        ? fmemopen((void *)allowlist_data, allowlist_size, "r")
        : NULL;
    if (allowlist_fp) {
        if (load_allowlist(allowlist_fp, "fuzz", "/dummy/path", &loaded) == 0) {
            allowlist = &loaded;
        }
        fclose(allowlist_fp);
    }

    ParserContext ctx = {
        .fd = -1,
        .buf = netstring_data,
        .size = netstring_size,
        .pos = 0
    };

    run_wrapper(&ctx, allowlist, &audit, "/dummy/path");

    free_allowlist(&loaded);
    return 0;
}
