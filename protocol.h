// The first netstring of every request.
#define PROTOCOL_MAGIC "HW1"

// Shell convention: 0-124 belong to the target.
#define EXIT_INTERNAL_ERROR 125
#define EXIT_DENIED         126
#define EXIT_EXEC_FAILED    127

// A response frame's first byte. The status frame is always the last.
#define TAG_STDOUT '1'
#define TAG_STDERR '2'
#define TAG_STATUS 'x'

// The longest frame: a tag byte and a 64 KiB chunk.
#define MAX_FRAME (65536 + 1)
