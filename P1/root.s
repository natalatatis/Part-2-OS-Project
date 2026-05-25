.syntax unified
.code 32

.global _start
.extern p1_main
.extern __p1_stack_top

.section .text

_start:
    /* Initialize user stack */
    ldr sp, =__p1_stack_top

    /* Call main */
    bl p1_main

/* If main returns, halt forever */
hang:
    b hang