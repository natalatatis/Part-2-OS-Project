// PROCESS 1 - prints digits from 0 to 9
#include "../Library/stdio.h"
#include "../Library/syscall.h"


int p1_main(void)
{
    int n = 0;
    int counter = 0;
    int prints = 0;
    int total_cycles = 0; // Track total sets of prints

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
                
                // EXIT CONDITION: Exit after 3 cycles
                if (total_cycles >= 3) {
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

