ENTRY(_start)

SECTIONS
{
    /* Vector table at 0x0 for QEMU */
    . = 0x00000000;
    .vectors : {
        KEEP(*(.vectors))
    }

    /* OS API at fixed address */
    . = 0x00008000;
    .os_api : {
        KEEP(*(.os_api))
    }

    /* OS Kernel code and data */
    . = 0x00010000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    }

    /* Stacks */
    __irq_stack_top__ = 0x0001A000;
    __os_stack_top__  = 0x0001B000;

}