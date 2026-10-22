// Runs a command with stdout and stderr on a PTY of the given size and relays
// its output, so a shell suite can give host-proxy a terminal on chosen
// streams. stdin passes through untouched. Exits with the command's status, or
// 2 on a failure of its own.
//
// path is not looked up in PATH, so a mistyped one fails rather than finding
// another binary.
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
#include <util.h>
#else
#include <pty.h>
#endif

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "usage: run-on-pty <cols> <rows> <path> [args...]\n");
        return 2;
    }

    struct winsize ws;
    ws.ws_col = (unsigned short)atoi(argv[1]);
    ws.ws_row = (unsigned short)atoi(argv[2]);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, &ws) == -1) {
        fprintf(stderr, "openpty: %s\n", strerror(errno));
        return 2;
    }

    // Raw, like the PTY host-wrapper hands the target, so ONLCR does not
    // rewrite the relayed bytes on the way through.
    struct termios ios;
    if (tcgetattr(slave, &ios) == 0) {
        cfmakeraw(&ios);
        tcsetattr(slave, TCSANOW, &ios);
    }

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "fork: %s\n", strerror(errno));
        return 2;
    }
    if (pid == 0) {
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        close(master);
        close(slave);
        execv(argv[3], &argv[3]);
        fprintf(stderr, "execv %s: %s\n", argv[3], strerror(errno));
        _exit(127);
    }

    close(slave);

    // A drained master reports EIO on Linux and a zero read on macOS.
    char buf[4096];
    for (;;) {
        ssize_t n = read(master, buf, sizeof(buf));
        if (n > 0) {
            if (fwrite(buf, 1, (size_t)n, stdout) != (size_t)n) break;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    fflush(stdout);
    close(master);

    int status;
    if (waitpid(pid, &status, 0) == -1) return 2;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}
