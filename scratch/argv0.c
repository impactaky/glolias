/* Throwaway demo: what does a program see as argv[0], and how does that
 * compare to /proc/self/exe, when invoked through a symlink?
 * This is exactly the information glolias's dispatcher keys off of. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>

int main(int argc, char **argv) {
    printf("argc           : %d\n", argc);

    if (argc >= 1 && argv[0] != NULL) {
        char tmp[4096];
        strncpy(tmp, argv[0], sizeof(tmp) - 1);
        tmp[sizeof(tmp) - 1] = '\0';
        printf("argv[0]        : '%s'\n", argv[0]);
        printf("basename(argv0): '%s'   <-- glolias uses THIS as the alias name\n",
               basename(tmp));
    } else {
        printf("argv[0]        : <none>  (empty argv! glolias would error here)\n");
    }

    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n >= 0) {
        buf[n] = '\0';
        char tmp2[4096];
        strncpy(tmp2, buf, sizeof(tmp2) - 1);
        tmp2[sizeof(tmp2) - 1] = '\0';
        printf("/proc/self/exe : '%s'\n", buf);
        printf("basename(exe)  : '%s'   <-- NOTE: symlink already resolved away\n",
               basename(tmp2));
    }
    printf("\n");
    return 0;
}
