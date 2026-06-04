// PROCESS 1
#include "../Library/stdio.h"
#include "../Library/syscall.h"

int p1_main(void)
{
    int n          = 0;
    int counter    = 0;
    int prints     = 0;
    int total_cycles = 0;

    static const char msg[] = ">>> SYS_WRITE from P1 <<<\n";

    while (1)
    {
        counter++;
        if (counter < 50000000) continue;
        counter = 0;

        PRINT("----FROM P1: %d\n", n);
        n = (n + 1) % 10;
        prints++;

        if (prints < 5) continue;
        prints = 0;
        total_cycles++;

        //  Every 5 prints: one "chapter" of behaviour 

        if (total_cycles == 1)
        {
            // Chapter 1: show sys_write with a valid fd — expect positive rc
            PRINT("[P1] Chapter 1 — valid sys_write\n");
            int rc = sys_write(1, msg, sizeof(msg) - 1);
            PRINT("[P1] sys_write(1) returned %d\n", rc);
            PRINT("[P1] yielding to P2...\n");
            sys_yield();
            PRINT("[P1] back from yield\n");
        }
        else if (total_cycles == 2)
        {
            // Chapter 2: show sys_write with a bad fd — expect negative rc
            PRINT("[P1] Chapter 2 — invalid sys_write\n");
            int rc = sys_write(99, msg, sizeof(msg) - 1);
            PRINT("[P1] sys_write(99) returned %d\n", rc);
            PRINT("[P1] yielding to P2...\n");
            sys_yield();
            PRINT("[P1] back from yield\n");
        }
        else if (total_cycles == 3)
        {
            // Chapter 3: trigger a data abort — USR writing to kernel vector table
            // Fault handler should kill P1; P2 must survive and keep running

            PRINT("[P1] Chapter 3 — triggering DATA ABORT (invalid read) now\n");
            volatile unsigned int *unmapped = (unsigned int *)0x50000000;
            unsigned int val = *unmapped;
            (void)val;
        }

        // total_cycles >= 4 is unreachable for P1 (killed in chapter 3)
        if (total_cycles >= 4)
        {
            PRINT("[P1] clean exit\n");
            sys_exit(0);
        }
    }
}

/*
CODE SNIPPETS TO TRY THE DIFFERENT FAULTS WE CAN ENCOUNTER
*/
/*
// ── OPTION A: DATA ABORT (current)
// Write to address 0x0 — kernel vector table, USR has no write permission
// Expected: FAULT_DATA_PERMISSION or FAULT_DATA_INVALID depending on MPU config
PRINT("[P1] Chapter 3 — triggering DATA ABORT now\n");
volatile unsigned int *bad_ptr = (unsigned int *)0x00000000;
*bad_ptr = 0xDEADBEEF;


// ── OPTION B: PREFETCH ABORT 
// Jump to a completely unmapped address — CPU tries to fetch an instruction
// from there and fails before executing anything
// Expected: FAULT_PREFETCH
PRINT("[P1] Chapter 3 — triggering PREFETCH ABORT now\n");
void (*bad_func)(void) = (void (*)(void))0xDEAD0000;
bad_func();


// ── OPTION C: DATA ABORT (misaligned access) 
// Read a word from an address that is not 4-byte aligned
// Expected: FAULT_DATA_ALIGNMENT
// Note: only faults if the MMU/MPU has alignment checking enabled (SCTLR.A=1)
// On BeagleBone with default settings this may or may not trap — good to test
PRINT("[P1] Chapter 3 — triggering ALIGNMENT FAULT now\n");
unsigned int buffer[2] = {0x12345678, 0x9ABCDEF0};
volatile unsigned int *misaligned = (unsigned int *)((char *)buffer + 1);
unsigned int val2 = *misaligned;
(void)val2;


// ── OPTION D: UNDEFINED INSTRUCTION
// Inject an undefined instruction word directly into the instruction stream
// CPU hits it, takes the UNDEF vector instead of prefetch/data abort
// Expected: undefined_handler fires, prints [UNDEF EXCEPTION], then hangs
PRINT("[P1] Chapter 3 — triggering UNDEFINED INSTRUCTION now\n");
__asm__ volatile(".word 0xE7F000F0");  // architecturally undefined on ARMv7

*/