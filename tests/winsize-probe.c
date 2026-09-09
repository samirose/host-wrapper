// Test target: prints the window size the wrapper gave this process, as
// "cols,rows". Reads fd 1 because that is the PTY slave the wrapper assigns to
// stdout; the target's stdin is /dev/null unless the allowlist says +stdin.
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(void) {
    struct winsize ws;

    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0) {
        fprintf(stderr, "TIOCGWINSZ on fd 1 failed\n");
        return 1;
    }
    printf("%d,%d\n", ws.ws_col, ws.ws_row);
    return 0;
}
