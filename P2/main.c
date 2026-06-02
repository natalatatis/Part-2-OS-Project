#include "../Library/stdio.h"
#include "../Library/syscall.h"

int p2_main(void)
{
    char c = 'a';
    int counter = 0;
    int prints = 0;
    int total_cycles = 0;

    while (1)
    {
        counter++;
        if (counter >= 50000000)
        {
            PRINT("----FROM P2: %c\n", c);
            c++;
            if (c > 'z') c = 'a';

            prints++;
            counter = 0;

            if (prints >= 5)
            {
                prints = 0;
                total_cycles++;

                // EXIT CONDITION: Exit after a set number of cycles
                if (total_cycles >= 4) {
                    PRINT("P2 exiting now...\n");
                    sys_exit(0);
                    while(1);
                }

                PRINT("P2 before yield\n");
                sys_yield();
                PRINT("P2 after yield\n");
            }
        }
    }
}