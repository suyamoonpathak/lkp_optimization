#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/falloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* Usage: fallocate_range_helper <path> <N> <mode: collapse|insert>
 *
 * Pre-sizes <path> to 64 MB, then loops N times calling
 * fallocate(fd, mode, 4096, 4096); fsync(fd);
 *
 * For COLLAPSE_RANGE, the file shrinks by 4 KB per iteration.
 * For INSERT_RANGE, the file grows by 4 KB per iteration.
 * Neither mode approaches EOF in 1000 iterations of a 64 MB file.
 *
 * Prints: elapsed_ns=<ns>
 */
int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <path> <N> <collapse|insert>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    long N = atol(argv[2]);
    int mode;
    if (!strcmp(argv[3], "collapse"))
        mode = FALLOC_FL_COLLAPSE_RANGE;
    else if (!strcmp(argv[3], "insert"))
        mode = FALLOC_FL_INSERT_RANGE;
    else {
        fprintf(stderr, "mode must be collapse or insert\n");
        return 2;
    }

    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open"); return 1; }

    if (ftruncate(fd, 64L * 1024 * 1024) < 0) { perror("ftruncate"); return 1; }
    if (fsync(fd) < 0) { perror("fsync pre"); return 1; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long i = 0; i < N; i++) {
        if (fallocate(fd, mode, 4096, 4096) < 0) {
            fprintf(stderr, "fallocate mode=%s iter=%ld: ", argv[3], i);
            perror("fallocate");
            return 1;
        }
        if (fsync(fd) < 0) { perror("fsync"); return 1; }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    long long elapsed_ns =
        (long long)(t1.tv_sec - t0.tv_sec) * 1000000000LL +
        (t1.tv_nsec - t0.tv_nsec);
    printf("elapsed_ns=%lld\n", elapsed_ns);

    close(fd);
    return 0;
}
