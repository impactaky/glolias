#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char first_secret[] = "SYNTHETIC_GLOLIAS_FIRST_7H3Q9K";
static const char second_secret[] = "SYNTHETIC_GLOLIAS_SECOND_4P8M2R";

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: pty_secret <first|second|empty> <command> [args...]\n");
        return 2;
    }
    const char *secret = NULL;
    if (strcmp(argv[1], "first") == 0) secret = first_secret;
    if (strcmp(argv[1], "second") == 0) secret = second_secret;
    if (strcmp(argv[1], "empty") == 0) secret = "";
    if (secret == NULL) return 2;

    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, NULL);
    if (child < 0) return 2;
    if (child == 0) {
        execvp(argv[2], &argv[2]);
        _exit(127);
    }

    char seen[4096] = {0};
    size_t seen_len = 0;
    int supplied = 0;
    for (;;) {
        char buffer[1024];
        ssize_t count = read(master, buffer, sizeof(buffer));
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno == EIO) break;
            return 2;
        }
        if (count == 0) break;
        if (write(STDOUT_FILENO, buffer, (size_t)count) != count) return 2;
        if (!supplied) {
            size_t copy = (size_t)count;
            if (copy > sizeof(seen) - 1 - seen_len) copy = sizeof(seen) - 1 - seen_len;
            memcpy(seen + seen_len, buffer, copy);
            seen_len += copy;
            seen[seen_len] = '\0';
            if (strstr(seen, "Secret: ") != NULL) {
                if (write(master, secret, strlen(secret)) < 0 || write(master, "\n", 1) != 1) return 2;
                supplied = 1;
            }
        }
    }
    close(master);
    int status = 0;
    if (waitpid(child, &status, 0) < 0) return 2;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 2;
}
