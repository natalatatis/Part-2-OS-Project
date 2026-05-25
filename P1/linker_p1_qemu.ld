ENTRY(main)

SECTIONS
{
    /* Match the load address in the Makefile and OS.c */
    . = 0x00100000;

    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    .bss : {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    }

    /* Stack grows down from 8KB above the base */
    __p1_stack_top = 0x00112000;
}