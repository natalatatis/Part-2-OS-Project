.syntax unified
.code 32

.global _start
.extern p2_main
.extern __p2_stack_top

.section .text

_start:
    /* Initialize user stack */
    ldr sp, =__p2_stack_top

    /* Call main */
    bl p2_main

hang:
    b hang