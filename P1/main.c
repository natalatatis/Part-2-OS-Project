// PROCESS 1 - prints digits from 0 to 9
#include "../Library/stdio.h"
#include "../Library/syscall.h"


int p1_main(void)
{
    int n = 0;
    int counter = 0;
    int prints = 0;
    int total_cycles = 0;

    static const char msg[] = ">>> SYS_WRITE from P1 <<<\n";

    while (1)
    {
        counter++;

        if (counter >= 50000000)
        {
            PRINT("----FROM P1: %d\n", n);

            n = (n + 1) % 10;
            prints++;
            counter = 0;

            if (prints >= 5)
            {
                prints = 0;
                total_cycles++;

                int rc = sys_write(1, msg, sizeof(msg) - 1); // should return positive
               // int rc = sys_write(99, msg, sizeof(msg) - 1); // should return -2 

                PRINT("sys_write returned %d\n", rc);

                if (total_cycles == 2)
                {
                    // ── TEST: DATA ABORT ──────────────────────────────────
                    // Write to address 0x0 — valid kernel vector table area,
                    // USR mode has no write permission → data abort
                    PRINT("P1 triggering data abort...\n");
                    volatile unsigned int *bad_ptr = (unsigned int *)0x00000000;
                    *bad_ptr = 0xDEADBEEF;
                    // Should never reach here — fault handler kills P1
                    PRINT("P1 should not reach here\n");
                }

              /*  if (total_cycles == 3)
                {
                    // ── TEST: PREFETCH ABORT ──────────────────────────────
                    // Jump to address 0xDEAD0000 — unmapped, no code there
                    // CPU tries to fetch instruction → prefetch abort
                    PRINT("P1 triggering prefetch abort...\n");
                    void (*bad_func)(void) = (void (*)(void))0xDEAD0000;
                    bad_func();
                    // Should never reach here — fault handler kills P1
                    PRINT("P1 should not reach here\n");
                }*/

                if (total_cycles >= 4)
                {
                    PRINT("P1 exiting now...\n");
                    sys_exit(0);
                }

                PRINT("P1 before yield\n");
                sys_yield();
                PRINT("P1 after yield\n");
            }
        }
    }
}

