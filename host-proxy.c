#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
#include <limits.h>
#include <libgen.h>
#include <sys/ioctl.h>

/**
 * Robustly writes all data to a file descriptor, handling partial writes
 * and EINTR. Returns 0 on success, -1 on error.
 */
int write_all(int fd, const void *buf, size_t count) {
    const char *ptr = buf;
    size_t written = 0;
    while (written < count) {
        ssize_t w = write(fd, ptr + written, count - written);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) break;
        written += (size_t)w;
    }
    return (written == count) ? 0 : -1;
}

/**
 * Writes a string as a netstring to a file descriptor.
 * Format: [length]:[data],
 */
int write_netstring(int fd, const char *data, size_t len) {
    char header[32];
    int header_len = snprintf(header, sizeof(header), "%zu:", len);
    if (write_all(fd, header, (size_t)header_len) == -1) return -1;
    if (write_all(fd, data, len) == -1) return -1;
    if (write_all(fd, ",", 1) == -1) return -1;
    return 0;
}

/**
 * Child process logic: Redirects stdin to the read end of the pipe
 * and executes the SSH connection script.
 * The script is expected to be in the same directory as the proxy binary.
 */
void execute_ssh_child(int pipe_read_fd, const char *proxy_dir) {
    // Redirect stdin from the pipe
    if (dup2(pipe_read_fd, 0) == -1) {
        perror("dup2");
        exit(1);
    }
    close(pipe_read_fd);

    // Construct the path to the connection script: [proxy_dir]/host-proxy-ssh.sh
    char script_path[PATH_MAX];
    snprintf(script_path, sizeof(script_path), "%s/host-proxy-ssh.sh", proxy_dir);

    // Execute the connection script.
    char *script_argv[] = {
        script_path, NULL
    };

    execvp(script_argv[0], script_argv);
    fprintf(stderr, "execvp failed for %s: %s\n", script_path, strerror(errno));
    exit(1);
}

/**
 * Stdin pump logic: Reads from stdin and writes to the pipe.
 * Exits when stdin reaches EOF or the pipe is closed.
 */
void execute_stdin_pump(int pipe_write_fd) {
    unsigned char buffer[4096];
    ssize_t n;
    while ((n = read(0, buffer, sizeof(buffer))) > 0) {
        if (write_all(pipe_write_fd, buffer, (size_t)n) == -1) {
            // Broken pipe or error, exit pump cleanly
            close(pipe_write_fd);
            exit(0);
        }
    }
    close(pipe_write_fd);
    exit(0);
}

/**
 * Parent process logic: Serializes argv, forks a dedicated stdin pump process,
 * waits for the SSH process to exit, and then cleans up the pump.
 */
int execute_proxy_parent(int pipe_write_fd, pid_t child_pid, int argc, char *argv[]) {
    // Ignore SIGPIPE so processes can handle broken pipes via return values
    signal(SIGPIPE, SIG_IGN);

    // Get terminal size of the invoking environment
    struct winsize ws;
    int cols = 80;
    int rows = 24;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
        cols = ws.ws_col;
        rows = ws.ws_row;
    }
    char winsize_str[32];
    snprintf(winsize_str, sizeof(winsize_str), "%d,%d", cols, rows);
    if (write_netstring(pipe_write_fd, winsize_str, strlen(winsize_str)) == -1) {
        // Pipe is likely broken already
        close(pipe_write_fd);
        waitpid(child_pid, NULL, 0);
        return 1;
    }

    // 1. Write target argc (argc-1 because argv[0] is host-proxy)
    char argc_str[16];
    int target_argc = argc - 1;
    snprintf(argc_str, sizeof(argc_str), "%d", target_argc);
    if (write_netstring(pipe_write_fd, argc_str, strlen(argc_str)) == -1) {
        // Pipe is likely broken already
        close(pipe_write_fd);
        waitpid(child_pid, NULL, 0);
        return 1;
    }

    // 2. Write target argv
    for (int i = 1; i < argc; i++) {
        if (write_netstring(pipe_write_fd, argv[i], strlen(argv[i])) == -1) {
            close(pipe_write_fd);
            waitpid(child_pid, NULL, 0);
            return 1;
        }
    }

    // 3. Fork a dedicated stdin pump process
    pid_t pump_pid = fork();
    if (pump_pid == -1) {
        perror("fork pump");
        return 1;
    }

    if (pump_pid == 0) {
        execute_stdin_pump(pipe_write_fd);
        // execute_stdin_pump never returns
    }

    // --- Main Parent Process ---
    // Close the write end of the pipe in the parent so that when the pump dies,
    // the SSH process receives an EOF on its stdin.
    close(pipe_write_fd);

    // 4. Wait for SSH to finish
    int status;
    waitpid(child_pid, &status, 0);

    // 5. SSH is done. The host command has finished.
    // Clean up the pump if it is still waiting for input (e.g., from an open terminal).
    kill(pump_pid, SIGTERM);
    waitpid(pump_pid, NULL, 0);

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 1;
}

int main(int argc, char *argv[]) {
    char *proxy_dir = NULL;
    char *argv0_copy = NULL;
    int result = 1;

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    // Determine the directory of the host-proxy binary
    argv0_copy = strdup(argv[0]);
    if (!argv0_copy) {
        perror("strdup");
        goto cleanup;
    }
    proxy_dir = strdup(dirname(argv0_copy));
    if (!proxy_dir) {
        perror("strdup proxy_dir");
        goto cleanup;
    }

    int pipe_fds[2];
    if (pipe(pipe_fds) == -1) {
        perror("pipe");
        goto cleanup;
    }

    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        goto cleanup;
    }

    if (pid == 0) {
        close(pipe_fds[1]); // Close write end in child
        execute_ssh_child(pipe_fds[0], proxy_dir);
        // execute_ssh_child never returns
    } else {
        close(pipe_fds[0]); // Close read end in parent
        result = execute_proxy_parent(pipe_fds[1], pid, argc, argv);
    }

cleanup:
    free(argv0_copy);
    free(proxy_dir);
    return result;
}
