#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <linux/fs.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include <linux/io_uring.h>

#define ENTRIES 2048
#define BUFSIZE 1024

#define read_barrier()  __asm__ __volatile__("":::"memory")
#define write_barrier() __asm__ __volatile__("":::"memory")

/*
 * System call wrapper functions.
 */

int io_uring_setup(unsigned entries, struct io_uring_params *p)
{
    return (int) syscall(__NR_io_uring_setup, entries, p);
}

int io_uring_enter(int ring_fd, unsigned int to_submit,
                          unsigned int min_complete, unsigned int flags)
{
    return (int) syscall(__NR_io_uring_enter, ring_fd, to_submit, min_complete,
                   flags, NULL, 0);
}

int io_uring_register(unsigned fd, unsigned opcode, void *arg, unsigned nr_args)
{
    return (int) syscall(__NR_io_uring_register, fd, opcode, arg, nr_args);
}

struct user_sq_ring {
    unsigned *head;
    unsigned *tail;
    unsigned *ring_mask;
    unsigned *ring_entries;
    unsigned *flags;
    unsigned *array;
};

struct user_cq_ring {
    unsigned *head;
    unsigned *tail;
    unsigned *ring_mask;
    unsigned *ring_entries;
    struct io_uring_cqe *cqes;
};

struct ring_instance {
    int ring_fd;
    struct user_sq_ring sq_ring;
    struct user_cq_ring cq_ring;
    struct io_uring_sqe *sqes;
};

int init_ring(struct ring_instance *instance, unsigned entries)
{
    struct io_uring_params params;
    void *sq_ptr, *cq_ptr;
    int sq_size, cq_size;

    memset(&params, 0, sizeof(struct io_uring_params));
    instance->ring_fd = io_uring_setup(entries, &params);
    if (instance->ring_fd < 0) {
        perror("io_uring_setup");
        return 1;
    }

    sq_size = params.sq_off.array + params.sq_entries * sizeof(unsigned);
    cq_size = params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);

    /*
     * If IORING_FEAT_SINGLE_MMAP is set, it is possible to map
     * the SQ and CQ with a single mmap() call.
     */
    if (params.features & IORING_FEAT_SINGLE_MMAP) {
        if (cq_size > sq_size)
            sq_size = cq_size;
        sq_ptr = mmap(0, sq_size, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_POPULATE,
                instance->ring_fd, IORING_OFF_SQ_RING);
        if (sq_ptr == MAP_FAILED) {
            perror("SQ ring mmap");
            return 1;
        }
        cq_ptr = sq_ptr;
    } else {
        sq_ptr = mmap(0, sq_size, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_POPULATE,
                instance->ring_fd, IORING_OFF_SQ_RING);
        if (sq_ptr == MAP_FAILED) {
            perror("SQ ring mmap");
            return 1;
        }
        cq_ptr = mmap(0, cq_size, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_POPULATE,
                instance->ring_fd, IORING_OFF_CQ_RING);
        if (cq_ptr == MAP_FAILED) {
            perror("CQ ring mmap");
            return 1;
        }
    }

    instance->sq_ring.head = sq_ptr + params.sq_off.head;
    instance->sq_ring.tail = sq_ptr + params.sq_off.tail;
    instance->sq_ring.ring_mask = sq_ptr + params.sq_off.ring_mask;
    instance->sq_ring.ring_entries = sq_ptr + params.sq_off.ring_entries;
    instance->sq_ring.flags = sq_ptr + params.sq_off.flags;
    instance->sq_ring.array = sq_ptr + params.sq_off.array;

    instance->cq_ring.head = cq_ptr + params.cq_off.head;
    instance->cq_ring.tail = cq_ptr + params.cq_off.tail;
    instance->cq_ring.ring_mask = cq_ptr + params.cq_off.ring_mask;
    instance->cq_ring.ring_entries = cq_ptr + params.cq_off.ring_entries;
    instance->cq_ring.cqes = cq_ptr + params.cq_off.cqes;

    instance->sqes = mmap(0, params.sq_entries * sizeof(struct io_uring_sqe),
            PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
            instance->ring_fd, IORING_OFF_SQES);
    if (instance->sqes == MAP_FAILED) {
        perror("sqes mmap");
        return 1;
    }

    return 0;
}

int close_ring(struct ring_instance *instance)
{
    if(close(instance->ring_fd)) {
        perror("close");
        return 1;
    }
}

static void prep_sqe(int op, struct ring_instance *instance, int fd,
                     unsigned long addr, unsigned len, unsigned off,
                     unsigned long user_data, int flags)
{
    struct user_sq_ring *sring = &instance->sq_ring;
    unsigned index = 0, tail = 0, next_tail = 0;
    struct io_uring_sqe *sqe;

    next_tail = tail = *sring->tail;
    next_tail++;
    read_barrier();
    index = tail & *sring->ring_mask;
    sqe = &instance->sqes[index];
    sqe->fd = fd;
    sqe->flags = flags;
    sqe->opcode = op;
    sqe->addr = addr;
    sqe->len = len;
    sqe->off = off;
    sqe->user_data = user_data;
    sring->array[index] = index;
    tail = next_tail;
    if(*sring->tail != tail) {
        *sring->tail = tail;
        write_barrier();
    }
}

static void prep_read_sqe(struct ring_instance *instance, int fd,
                          unsigned long buf, unsigned len, int flags)
{
    prep_sqe(IORING_OP_READ, instance, fd, buf, len, 0, buf, flags);
}

static void prep_write_sqe(struct ring_instance *instance, int fd,
                           unsigned long buf, unsigned len, unsigned off,
                           int flags)
{
    prep_sqe(IORING_OP_WRITE, instance, fd, buf, len, off, buf, flags);
}

static void prep_cancel_sqe(struct ring_instance *instance, unsigned long cancel_sqe,
                            unsigned long user_data, int flags)
{
    prep_sqe(IORING_OP_ASYNC_CANCEL, instance, -1, cancel_sqe, 0, 0, user_data, 0);
}

static void prep_timeout_sqe(struct ring_instance *instance, unsigned long addr,
                             unsigned long counts, int flags)
{
    prep_sqe(IORING_OP_TIMEOUT, instance, -1, addr, 1, counts, 0, flags);
}

int get_cqe(struct ring_instance *instance, struct io_uring_cqe **cqe)
{
    struct user_cq_ring *cring = &instance->cq_ring;
    unsigned head = *cring->head;

    read_barrier();
    if (head == *cring->tail)
        return -1;
    *cqe = &cring->cqes[head & *cring->ring_mask];
    head++;
    *cring->head = head;
    write_barrier();
    return 0;
}

static void test_create_and_remove_instance(void)
{
    struct ring_instance *instance;

    instance = malloc(sizeof(struct ring_instance));
    if (!instance) {
        perror("malloc");
        goto fail;
    }
    memset(instance, 0, sizeof(struct ring_instance));

    if(init_ring(instance, ENTRIES)) {
        printf("Failed to setup io_uring.\n");
        goto fail;
    }

    if(close_ring(instance)) {
        printf("Failed to close io_uring.\n");
        goto fail;
    }

    free(instance);
    printf("Pass %s\n", __func__);
    return;

fail:
    free(instance);
    printf("Fail %s\n", __func__);
}

static void test_create_and_remove_instance10(void)
{
    struct ring_instance *instance[10];
    int i;

    for(i = 0; i < 10; i++) {
        instance[i] = malloc(sizeof(struct ring_instance));
        if (!instance[i]) {
            perror("malloc");
            goto fail;
        }
        memset(instance[i], 0, sizeof(struct ring_instance));
    
        if(init_ring(instance[i], ENTRIES)) {
            printf("Failed to setup io_uring.\n");
            goto fail;
        }
    }
    for(i = 0; i < 10; i++) {
        if(close_ring(instance[i])) {
            printf("Failed to close io_uring.\n");
            goto fail;
        }
        free(instance[i]);
    }
    printf("Pass %s\n", __func__);
    return;

fail:
    for(i = 0; i < 10; i++)
        free(instance[i]);
    printf("Fail %s\n", __func__);
}

static void test_cancel_sqe(void)
{
    struct ring_instance *instance;
    struct io_uring_cqe *cqe;
    int file_fd, i;
    int cancelled = 0, cancell_running = 0, executed = 0;
    char *buf[ENTRIES] = {0};
    char *cmp;

    instance = malloc(sizeof(struct ring_instance));
    if (!instance) {
        perror("malloc");
        goto fail;
    }
    memset(instance, 0, sizeof(struct ring_instance));

    if(init_ring(instance, ENTRIES)) {
        printf("Failed to setup io_uring.\n");
        goto fail;
    }

    file_fd = open("/dev/urandom", O_RDONLY);
    if (file_fd < 0 ) {
        perror("open");
        goto fail;
    }

    /* IORING_OP_READ */
    for(i = 0; i < ENTRIES; i++) {
        buf[i] = (char *)malloc(BUFSIZE);
        if (!buf[i]) {
            perror("malloc");
            goto fail;
        }
        memset(buf[i], 0, BUFSIZE);
    }

    for(i = 0; i < ENTRIES/2; i++) {
        prep_read_sqe(instance, file_fd, (unsigned long)buf[i],
                      BUFSIZE, IOSQE_ASYNC);
    }

    if(io_uring_enter(instance->ring_fd, ENTRIES/2, 0, 0) < 0) {
        perror("io_uring_enter");
        goto fail;
    }

    /* IORING_OP_ASYNC_CANCEL */
    for(i = 0; i < ENTRIES/2; i++) {
        prep_cancel_sqe(instance, (unsigned long)buf[i],
                        (unsigned long)buf[i+ENTRIES/2], 0);
    }

    if(io_uring_enter(instance->ring_fd, ENTRIES/2, 0, 0) < 0) {
        perror("io_uring_enter");
        goto fail;
    }

    cmp = (char *)malloc(BUFSIZE);
    if (!cmp) {
        perror("malloc");
        goto fail;
    }
    memset(cmp, 0, BUFSIZE);

    /* read cqe */
    do {
        if(get_cqe(instance, &cqe))
            break;
        for(i = ENTRIES/2; i < ENTRIES; i++) {
            if(cqe->user_data == (unsigned long)buf[i]) {
                switch(cqe->res) {
                    case 0:
                        if(strcmp(buf[i-ENTRIES/2], cmp)) {
                            printf("The operation should have been canceled\n");
                            goto fail;
                        }
                        cancelled++;
                        break;
                    case -EALREADY:
                        cancell_running++;
                        break;
                    case -ENOENT:
                        if(!strcmp(buf[i-ENTRIES/2], cmp)) {
                            printf("The operation should have been executed\n");
                            goto fail;
                        }
                        executed++;
                        break;
                }
            }
        }
    } while(1);

    if(close_ring(instance)) {
        printf("Failed to close io_uring.\n");
        goto fail;
    }

    free(instance);
    for(i = 0; i < ENTRIES; i++)
        free(buf[i]);
    free(cmp);

    printf("Pass %s cancelled = %d, cancell_running = %d, executed = %d\n", 
            __func__, cancelled, cancell_running, executed);
    return;

fail:
    free(instance);
    for(i = 0; i < ENTRIES; i++)
        free(buf[i]);
    sleep(1);
    free(cmp);
    printf("Fail %s\n", __func__);
}

/* IOSQE_IO_LINK, IOSQE_IO_HARDLINK, IO_SQE_DRAIN の
 * 機能テスト。狙った順番通りに実行されることをテストする。 */
static void test_io_link(void)
{
    struct ring_instance *instance;
    struct io_uring_cqe *cqe;
    int file_fd, i;
    char *buf[9] = {0};
    char text[10] = {0};
    char c;
    struct timespec *ts;

    instance = malloc(sizeof(struct ring_instance));
    if (!instance) {
        perror("malloc");
        goto fail;
    }
    memset(instance, 0, sizeof(struct ring_instance));

    if(init_ring(instance, ENTRIES)) {
        printf("Failed to setup io_uring.\n");
        goto fail;
    }

    file_fd = open("/tmp/test-io_uring",
                   O_RDWR|O_CREAT|O_TRUNC|O_APPEND, S_IRWXU);
    if (file_fd < 0 ) {
        perror("open");
        goto fail;
    }

    for(i = 0; i < 9; i++) {
        buf[i] = (char *)malloc(BUFSIZE);
        if (!buf[i]) {
            perror("malloc");
            goto fail;
        }
        memset(buf[i], 0, BUFSIZE);
        c = '1' + i;
        strncpy(buf[i], &c, 1);
    }

    ts = malloc(sizeof(struct timespec));
    if (!ts) {
        perror("malloc");
        goto fail;
    }
    /* タイムアウトを 1msec に設定する。 */
    ts->tv_sec = 0;
    ts->tv_nsec = 1000000;

    prep_write_sqe(instance, file_fd, (unsigned long)buf[0],
                  strlen(buf[0]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[1],
                  strlen(buf[1]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[2],
                  strlen(buf[2]), 0, 0);

    prep_timeout_sqe(instance, (unsigned long)ts, 3, IOSQE_IO_DRAIN|IOSQE_IO_LINK);

    prep_write_sqe(instance, file_fd, (unsigned long)buf[6],
                  strlen(buf[6]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[7],
                  strlen(buf[7]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[8],
                  strlen(buf[8]), 0, 0);

    prep_write_sqe(instance, file_fd, (unsigned long)buf[3],
                  strlen(buf[3]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[4],
                  strlen(buf[4]), 0, IOSQE_IO_LINK);
    prep_write_sqe(instance, file_fd, (unsigned long)buf[5],
                  strlen(buf[5]), 0, 0);

    if(io_uring_enter(instance->ring_fd, 10, 0, 0) < 0) {
        perror("io_uring_enter");
        goto fail;
    }

    sleep(1);

    do {
        if(get_cqe(instance, &cqe))
            break;
        if(cqe->user_data != 0) {
            if(cqe->res < 0)
                printf("write error. cqe->res = %d\n", cqe->res);
        } else {
            if(cqe->res < 0)
                printf("timeout error. cqe->res = %d\n", cqe->res);
        }
    } while(1);

    if(close(file_fd)) {
        perror("close");
        goto fail;
    }

    if(close_ring(instance)) {
        printf("Failed to close io_uring.\n");
        goto fail;
    }

    file_fd = open("/tmp/test-io_uring", O_RDWR);
    if (file_fd < 0 ) {
        perror("open");
        goto fail;
    }

    if(read(file_fd, text, 10) < 0) {
        perror("read");
        goto fail;
    }

    if(strcmp(text, "123456789")) {
        printf("Not in the order given. %s\n", text);
        goto fail;
    }

    free(instance);
    for(i = 0; i < 9; i++)
        free(buf[i]);
    free(ts);

    printf("Pass %s\n", __func__);
    return;

fail:
    free(instance);
    for(i = 0; i < 9; i++)
        free(buf[i]);
    free(ts);
    printf("Fail %s\n", __func__);
}

static void test_ring_overflow(void)
{
    struct ring_instance *instance;
    int file_fd, i;
    char *buf[32] = {0};

    instance = malloc(sizeof(struct ring_instance));
    if (!instance) {
        perror("malloc");
        goto fail;
    }
    memset(instance, 0, sizeof(struct ring_instance));

    if(init_ring(instance, 8)) {
        printf("Failed to setup io_uring.\n");
        goto fail;
    }

    file_fd = open("/dev/urandom", O_RDONLY);
    if (file_fd < 0 ) {
        perror("open");
        goto fail;
    }

    /* IORING_OP_READ */
    for(i = 0; i < 32; i++) {
        buf[i] = (char *)malloc(BUFSIZE);
        if (!buf[i]) {
            perror("malloc");
            goto fail;
        }
        memset(buf[i], 0, BUFSIZE);
    }

    for(i = 0; i < 32; i++) {
        prep_read_sqe(instance, file_fd, (unsigned long)buf[i],
                      BUFSIZE, IOSQE_ASYNC);
        if(io_uring_enter(instance->ring_fd, 1, 0, 0) < 0) {
            perror("io_uring_enter");
            goto fail;
        }
        /* cqe が生成されるのを待つ */
        sleep(0.1);
    }

    printf("Pass %s\n", __func__);
    return;
fail:
    free(instance);
    for(i = 0; i < 32; i++)
        free(buf[i]);
    printf("Fail %s\n", __func__);
}

static void test_eventfd(void)
{
    struct ring_instance *instance;
    struct io_uring_cqe *cqe;
    int file_fd, event_fd, i;
    int count = 0;
    unsigned long event_count;
    char *buf[ENTRIES] = {0};

    instance = malloc(sizeof(struct ring_instance));
    if (!instance) {
        perror("malloc");
        goto fail;
    }
    memset(instance, 0, sizeof(struct ring_instance));

    if(init_ring(instance, ENTRIES)) {
        printf("Failed to setup io_uring.\n");
        goto fail;
    }

    file_fd = open("/dev/urandom", O_RDONLY);
    if (file_fd < 0 ) {
        perror("open");
        goto fail;
    }

    for(i = 0; i < ENTRIES; i++) {
        buf[i] = (char *)malloc(BUFSIZE);
        if (!buf[i]) {
            perror("malloc");
            goto fail;
        }
        memset(buf[i], 0, BUFSIZE);
    }

    event_fd = eventfd(0, EFD_CLOEXEC);
    io_uring_register(instance->ring_fd, IORING_REGISTER_EVENTFD,
                        &event_fd, 1);

    for(i = 0; i < ENTRIES; i++) {
        prep_read_sqe(instance, file_fd, (unsigned long)buf[i],
                      BUFSIZE, IOSQE_ASYNC);
    }

    if(io_uring_enter(instance->ring_fd, ENTRIES, 0, 0) < 0) {
        perror("io_uring_enter");
        goto fail;
    }

    while(1){
        if(read(event_fd, &event_count, 8) < 0)
            break;
        for(i = 0; i < event_count; i++) {
            get_cqe(instance, &cqe);
            count++;
        }
        if(count >= ENTRIES)
            break;
    }
    printf("Pass %s\n", __func__);

    free(instance);
    for(i = 0; i < ENTRIES; i++)
        free(buf[i]);
    return;

fail:
    free(instance);
    for(i = 0; i < ENTRIES; i++)
        free(buf[i]);
    printf("Fail %s\n", __func__);
}

int main(int argc, char *argv[]) {
    test_create_and_remove_instance();
    test_create_and_remove_instance10();
    test_cancel_sqe();
    test_io_link();
    test_ring_overflow();
    test_eventfd();
}
