#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <file> <N>\n", argv[0]); return 2; }
    const char *path = argv[1];
    long N = atol(argv[2]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    char val[32];
    for (long i = 0; i < N; i++) {
        int n = snprintf(val, sizeof(val), "v%ld", i);
        if (fsetxattr(fd, "user.test", val, n, 0) < 0) { perror("fsetxattr"); return 1; }
        if (fsync(fd) < 0) { perror("fsync"); return 1; }
    }
    close(fd);
    return 0;
}
