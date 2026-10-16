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

// host-wrapper.c without main, and without pty.c: the fuzzer runs nothing.
#include "output.c"
#include "protocol.c"
#include "audit.c"
#include "allowlist.c"
#include "wrapper.c"

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

    FILE *allowlist_fp = NULL;
    if (allowlist_size > 0) {
        allowlist_fp = fmemopen((void *)allowlist_data, allowlist_size, "r");
    } else {
        allowlist_fp = fmemopen((void *)"/usr/bin/uname\n", 15, "r");
    }

    if (!allowlist_fp) return 0;

    ParserContext ctx = {
        .fd = -1,
        .buf = netstring_data,
        .size = netstring_size,
        .pos = 0
    };

    run_wrapper(&ctx, allowlist_fp, NULL, "/dummy/path");

    fclose(allowlist_fp);
    return 0;
}
