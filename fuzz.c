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

int run_wrapper(ParserContext *ctx, const char *allowlist_path);

// libFuzzer entry point
int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    // Set up the context to read directly from the fuzzer's memory buffer
    ParserContext ctx = {
        .fd = -1,
        .buf = Data,
        .size = Size,
        .pos = 0
    };

    // Run the parser logic. Path is ignored during fuzzing.
    run_wrapper(&ctx, "/dummy");

    return 0;
}
