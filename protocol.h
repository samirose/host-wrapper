// The first netstring of every request.
#define PROTOCOL_MAGIC "HW1"

// Shell convention: 0-124 belong to the target.
#define EXIT_INTERNAL_ERROR 125
#define EXIT_DENIED         126
#define EXIT_EXEC_FAILED    127

// The longest frame: a tag byte and a 64 KiB chunk.
#define MAX_FRAME (65536 + 1)
