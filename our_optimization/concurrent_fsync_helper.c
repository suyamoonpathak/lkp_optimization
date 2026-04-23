#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* Usage: concurrent_fsync_helper <dir> <threads> <ops-per-thread>
 *
 * Spawns <threads> pthreads. Each opens its own file under <dir>
 * (overwriting if present) and does <ops> iterations of
 * pwrite(4 KB) + fsync(). Threads synchronize on a barrier before
 * starting so wall-clock measurement covers the parallel region.
 *
 * Signal interpretation: if tx_delta grows linearly with <threads>,
 * JBD2 is not sharing commits across concurrent fsync-ers — that is
 * the headroom a CJFS compound-flush backport would target. If the
 * delta is already sub-linear, less room.
 *
 * Prints: threads=<T> ops_each=<ops> elapsed_ns=<ns> total_ops=<T*ops>
 */
struct arg {
    char path[512];
    long ops;
    pthread_barrier_t *bar;
};

static void *work(void *a) {
    struct arg *x = (struct arg *)a;
    int fd = open(x->path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return NULL; }
    char buf[4096];
    memset(buf, 'z', sizeof(buf));
    pthread_barrier_wait(x->bar);
    for (long i = 0; i < x->ops; i++) {
        if (pwrite(fd, buf, sizeof(buf), (off_t)i * 4096) != (ssize_t)sizeof(buf)) {
            perror("pwrite");
            close(fd);
            return NULL;
        }
        if (fsync(fd) < 0) {
            perror("fsync");
            close(fd);
            return NULL;
        }
    }
    close(fd);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <dir> <threads> <ops-per-thread>\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    int T = atoi(argv[2]);
    long ops = atol(argv[3]);
    if (T < 1 || ops < 1) { fprintf(stderr, "bad T or ops\n"); return 2; }

    pthread_t *th = calloc((size_t)T, sizeof *th);
    struct arg *args = calloc((size_t)T, sizeof *args);
    if (!th || !args) { perror("calloc"); return 1; }

    pthread_barrier_t bar;
    if (pthread_barrier_init(&bar, NULL, (unsigned int)T) != 0) {
        perror("barrier"); return 1;
    }

    for (int i = 0; i < T; i++) {
        snprintf(args[i].path, sizeof args[i].path, "%s/t%d", dir, i);
        args[i].ops = ops;
        args[i].bar = &bar;
    }

    struct timespec t0, t1;
    for (int i = 0; i < T; i++) {
        if (pthread_create(&th[i], NULL, work, &args[i]) != 0) {
            perror("pthread_create"); return 1;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < T; i++) pthread_join(th[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    long long elapsed_ns =
        (long long)(t1.tv_sec - t0.tv_sec) * 1000000000LL +
        (t1.tv_nsec - t0.tv_nsec);
    printf("threads=%d ops_each=%ld elapsed_ns=%lld total_ops=%ld\n",
           T, ops, elapsed_ns, (long)T * ops);

    pthread_barrier_destroy(&bar);
    free(th);
    free(args);
    return 0;
}
