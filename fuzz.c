#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>

// Forward declarations from host-wrapper.c
typedef struct {
    int fd;
    const unsigned char *buf;
    size_t size;
    size_t pos;
} ParserContext;

int run_wrapper(ParserContext *ctx, FILE *allowlist_fp, const char *allowlist_path);

// libFuzzer entry point
int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    if (Size < 2) return 0;

    // Use the first byte as the length of the allowlist data (max 255 bytes)
    // This gives the fuzzer deterministic control over the split without modulo math
    size_t allowlist_size = Data[0];
    if (allowlist_size > Size - 1) {
        allowlist_size = Size - 1;
    }

    const uint8_t *allowlist_data = Data + 1;
    const uint8_t *netstring_data = Data + 1 + allowlist_size;
    size_t netstring_size = Size - 1 - allowlist_size;

    // Create an in-memory file stream for the allowlist
    FILE *allowlist_fp = NULL;
    if (allowlist_size > 0) {
        allowlist_fp = fmemopen((void *)allowlist_data, allowlist_size, "r");
    } else {
        // Fallback valid allowlist if size is 0
        allowlist_fp = fmemopen((void *)"/usr/bin/uname\n", 15, "r");
    }
    
    if (!allowlist_fp) return 0;

    // Set up the context to read directly from the fuzzer's memory buffer
    ParserContext ctx = {
        .fd = -1,
        .buf = netstring_data,
        .size = netstring_size,
        .pos = 0
    };

    // Run the parser logic
    run_wrapper(&ctx, allowlist_fp, "/dummy/path/allowlist");

    fclose(allowlist_fp);
    return 0;
}
