ENTRY(main)

SECTIONS
{
    /* Match the load address in the Makefile and OS.c */
    . = 0x00200000;

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
    __p2_stack_top = 0x00212000;
}