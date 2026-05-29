#ifndef SYSCALL_H
#define SYSCALL_H

#define SYS_YIELD 0
#define SYS_EXIT  1
#define SYS_WRITE 2

int sys_yield(void);
void sys_exit(int code);
int sys_write(int fd, const char *buf, unsigned int len);

#endif