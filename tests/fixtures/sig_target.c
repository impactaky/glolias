#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    signal(SIGINT, SIG_DFL);
    if (argc != 2) return 2;

    FILE *f = fopen(argv[1], "w");
    if (!f) return 3;

    fprintf(f, "%ld\n", (long)getpid());
    fclose(f);
    sleep(10);
    return 0;
}
