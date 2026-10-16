// The first netstring of every request; host-proxy.c writes the same string.
#define PROTOCOL_MAGIC "HW1"

// Shell convention: 0-124 belong to the target.
#define EXIT_WRAPPER_ERROR 125
#define EXIT_DENIED        126
#define EXIT_EXEC_FAILED   127
