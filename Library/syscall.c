#include "syscall.h"

// YIELD voluntarily gives its "turn"
int sys_yield(void)
{
    int ret;

    asm volatile(
        "mov r0, %1\n"
        "svc #0\n"
        "mov %0, r0\n"
        : "=r"(ret)
        : "r"(SYS_YIELD)
        : "r0", "r1", "r2", "r3", "memory", "cc"
    );

    return ret;
}

void sys_exit(int code)
{
    asm volatile(
        "mov r0, %0\n"
        "mov r1, %1\n"
        "svc #0\n"
        :
        : "r"(SYS_EXIT), "r"(code)
        : "r0", "r1", "r2", "r3", "memory", "cc"
    );

    while (1) {}
}

int sys_write(int fd, const char *buf, unsigned int len)
{
    int ret;

    asm volatile(
        "mov r0, %1\n"
        "mov r1, %2\n"
        "mov r2, %3\n"
        "mov r3, %4\n"
        "svc #0\n"
        "mov %0, r0\n"
        : "=r"(ret)
        : "r"(SYS_WRITE),
          "r"(fd),
          "r"(buf),
          "r"(len)
        : "r0", "r1", "r2", "r3", "memory", "cc"
    );

    return ret;
}