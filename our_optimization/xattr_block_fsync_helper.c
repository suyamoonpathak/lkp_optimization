#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

/* Usage: xattr_block_fsync_helper <file> <N>
 *
 * Forces the xattr-BLOCK path (what C3's inline-xattr patch does NOT cover)
 * by using a 4000-byte value. That size exceeds the inline xattr region of a
 * 256-byte inode, so ext4_xattr_set_handle falls into ext4_xattr_block_set
 * and — on a C3 kernel — still calls ext4_fc_mark_ineligible.
 *
 * Varies the last byte of the value each iteration so this is a real
 * modification, not a no-op.
 *
 * Prints: elapsed_ns=<ns>
 */
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <file> <N>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    long N = atol(argv[2]);

    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open"); return 1; }

    char buf[4000];
    memset(buf, 'A', sizeof(buf));

    /* Warmup: tiny xattr pays the feature-bit-setting cost once. */
    if (fsetxattr(fd, "user.warmup", "x", 1, 0) < 0) {
        perror("fsetxattr warmup"); return 1;
    }
    if (fsync(fd) < 0) { perror("fsync warmup"); return 1; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long i = 0; i < N; i++) {
        buf[sizeof(buf) - 1] = (char)('A' + (i % 26));
        if (fsetxattr(fd, "user.big", buf, sizeof(buf), 0) < 0) {
            perror("fsetxattr"); return 1;
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
