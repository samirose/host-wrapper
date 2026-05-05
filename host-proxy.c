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
        // --- Child Process: SSH ---
        close(pipe_fds[1]); // Close write end

        // Redirect stdin from the pipe
        if (dup2(pipe_fds[0], 0) == -1) {
            perror("dup2");
            exit(1);
        }
        close(pipe_fds[0]);

        // Execute SSH. 
        // Note: The host and user should ideally be configured via env or a config file.
        // For now, we assume standard 'host.docker.internal' or similar.
        // The host wrapper path must also be known.
        char *ssh_argv[] = {
            "ssh", "-q", "-T", "host.docker.internal", "host-wrapper", NULL
        };

        execvp("ssh", ssh_argv);
        perror("execvp ssh");
        exit(1);
    } else {
        // --- Parent Process: Proxy ---
        close(pipe_fds[0]); // Close read end

        // 1. Write target argc (argc-1 because argv[0] is host-proxy)
        char argc_str[16];
        int target_argc = argc - 1;
        snprintf(argc_str, sizeof(argc_str), "%d", target_argc);
        write_netstring(pipe_fds[1], argc_str, strlen(argc_str));

        // 2. Write target argv
        for (int i = 1; i < argc; i++) {
            write_netstring(pipe_fds[1], argv[i], strlen(argv[i]));
        }

        // 3. Forward remaining stdin to the pipe
        unsigned char buffer[4096];
        ssize_t n;
        while ((n = read(0, buffer, sizeof(buffer))) > 0) {
            ssize_t written = 0;
            while (written < n) {
                ssize_t w = write(pipe_fds[1], buffer + written, (size_t)(n - written));
                if (w <= 0) break;
                written += w;
            }
        }

        close(pipe_fds[1]); // Close write end to signal EOF to SSH

        // 4. Wait for SSH to finish and propagate exit code
        int status;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status)) {
            return WEXITSTATUS(status);
        }
        return 1;
    }
}
