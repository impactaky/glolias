/* Launcher that execs ./argv0 with a TRULY empty argv (argc == 0).
 * Most shells/languages won't let you do this easily; raw execv can. */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    char *empty[] = { NULL };       /* no argv[0] at all */
    execv("./argv0", empty);
    perror("execv");                /* only reached if exec fails */
    return 1;
}
