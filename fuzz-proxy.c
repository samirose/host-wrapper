#define FUZZING
#include "build/host-proxy.c"

#include <stdint.h>

static int discard(char tag, const unsigned char *data, size_t len) {
    (void)tag; (void)data; (void)len;
    return 0;
}

// The first byte sets the read size, so a frame can arrive split anywhere.
int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    if (Size < 1) return 0;
    size_t step = (size_t)(Data[0] % 16) + 1;
    FrameDecoder d;
    frame_decoder_init(&d);
    for (size_t i = 1; i < Size; i += step) {
        size_t n = Size - i < step ? Size - i : step;
        if (decode_frames(&d, Data + i, n, discard) != 0) return 0;
    }
    if (d.state == FRAME_DONE && (d.exit_status < 0 || d.exit_status > 255)) abort();
    return 0;
}
