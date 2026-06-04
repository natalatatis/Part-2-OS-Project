// PROCESS 2
#include "../Library/stdio.h"
#include "../Library/syscall.h"

int p2_main(void)
{
    char c          = 'a';
    int  counter    = 0;
    int  prints     = 0;
    int  total_cycles = 0;

    static const char msg[] = ">>> SYS_WRITE from P2 <<<\n";

    while (1)
    {
        counter++;
        if (counter < 50000000) continue;
        counter = 0;

        PRINT("----FROM P2: %c\n", c);
        c++;
        if (c > 'z') c = 'a';
        prints++;

        if (prints < 5) continue;
        prints = 0;
        total_cycles++;

        if (total_cycles == 1)
        {
            // Chapter 1: normal yield, show we come back
            PRINT("[P2] Chapter 1 — yielding\n");
            sys_yield();
            PRINT("[P2] back from yield\n");
        }
        else if (total_cycles == 2)
        {
            // Chapter 2: sys_write then yield
            PRINT("[P2] Chapter 2 — sys_write then yield\n");
            int rc = sys_write(1, msg, sizeof(msg) - 1);
            PRINT("[P2] sys_write returned %d\n", rc);
            sys_yield();
            PRINT("[P2] back from yield\n");
        }
        else if (total_cycles == 3)
        {
            // Chapter 3: P1 just died from a fault — we should still be running
            PRINT("[P2] Chapter 3 — P1 should be dead, I am still alive\n");
            sys_yield();
            PRINT("[P2] yield returned (scheduler skipped dead P1)\n");
        }
        else if (total_cycles == 4)
        {
            // Chapter 4: run a few more prints to prove solo scheduling works
            PRINT("[P2] Chapter 4 — running alone, will exit next cycle\n");
        }
        else if (total_cycles >= 5)
        {
            PRINT("[P2] clean exit\n");
            sys_exit(0);
        }
    }
}