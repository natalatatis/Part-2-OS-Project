// PROCESS 1 - prints digits from 0 to 9
#include "../Library/stdio.h"
#include "../Library/syscall.h"

int p1_main(void)
{
    int n = 0;
    int counter = 0;

    while (1)
    {
        counter++;

        if (counter >= 50000000)
        {
            sys_yield();

            PRINT("----FROM P1: %d\n", n);

            n = (n + 1) % 10;

            counter = 0;
        }
    }

    while (1);
}

