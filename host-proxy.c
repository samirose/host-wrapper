#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>

/**
 * Writes a string as a netstring to a file descriptor.
 * Format: [length]:[data],
 */
void write_netstring(int fd, const char *data, size_t len) {
    char header[32];
    int header_len = snprintf(header, sizeof(header), "%zu:", len);
    write(fd, header, (size_t)header_len);
    write(fd, data, len);
    write(fd, ",", 1);
}

/**
 * Child process logic: Redirects stdin to the read end of the pipe
 * and executes the SSH connection script.
 */
void execute_ssh_child(int pipe_read_fd) {
    // Redirect stdin from the pipe
    if (dup2(pipe_read_fd, 0) == -1) {
        perror("dup2");
        exit(1);
    }
    close(pipe_read_fd);

    // Execute the connection script.
    char *script_argv[] = {
        "./host-proxy-ssh.sh", NULL
    };

    execvp(script_argv[0], script_argv);
    perror("execvp host-proxy-ssh.sh");
    exit(1);
}

/**
 * Parent process logic: Serializes argv, forwards stdin to the write end
 * of the pipe, and waits for the child process to exit.
 */
int execute_proxy_parent(int pipe_write_fd, pid_t child_pid, int argc, char *argv[]) {
    // 1. Write target argc (argc-1 because argv[0] is host-proxy)
    char argc_str[16];
    int target_argc = argc - 1;
    snprintf(argc_str, sizeof(argc_str), "%d", target_argc);
    write_netstring(pipe_write_fd, argc_str, strlen(argc_str));

    // 2. Write target argv
    for (int i = 1; i < argc; i++) {
        write_netstring(pipe_write_fd, argv[i], strlen(argv[i]));
    }

    // 3. Forward remaining stdin to the pipe
    unsigned char buffer[4096];
    ssize_t n;
    while ((n = read(0, buffer, sizeof(buffer))) > 0) {
        ssize_t written = 0;
        while (written < n) {
            ssize_t w = write(pipe_write_fd, buffer + written, (size_t)(n - written));
            if (w <= 0) break; // Broken pipe or error
            written += w;
        }
    }

    // Close write end to signal EOF to the SSH process
    close(pipe_write_fd);

    // 4. Wait for SSH to finish and propagate exit code
    int status;
    waitpid(child_pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    int pipe_fds[2];
    if (pipe(pipe_fds) == -1) {
        perror("pipe");
        return 1;
    }

    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        return 1;
    }

    if (pid == 0) {
        close(pipe_fds[1]); // Close write end in child
        execute_ssh_child(pipe_fds[0]);
        // execute_ssh_child never returns
    } else {
        close(pipe_fds[0]); // Close read end in parent
        return execute_proxy_parent(pipe_fds[1], pid, argc, argv);
    }

    return 0; // Unreachable
}
