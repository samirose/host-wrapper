#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>

// A copy of host-wrapper.c's ParserContext, which has to stay in step with it.
typedef struct {
    int fd;
    const unsigned char *buf;
    size_t size;
    size_t pos;
} ParserContext;

// Opaque here: the fuzzer runs without an audit trail.
typedef struct AuditLog AuditLog;

int run_wrapper(ParserContext *ctx, FILE *allowlist_fp, const AuditLog *audit,
                const char *workspace);

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
