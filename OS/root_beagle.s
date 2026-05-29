
 // root_beagle.s  —  AM335x / BeagleBone Black

    .syntax unified
    .code 32

    .globl _start
    .globl PUT32
    .globl GET32
    .globl enable_irq
    .globl first_launch

    .extern main
    .extern timer_irq_handler
    .extern current_proc
    .extern next_proc
    .extern os_uart_puts

    .extern __bss_start__
    .extern __bss_end__
    .extern __os_stack_top
    .extern __irq_stack_top
    .extern __svc_stack_top
    .extern os_debug_dump_pcb

    .extern syscall_handler

    .equ PCB_PID,   0
    .equ PCB_SP,    4
    .equ PCB_PC,    8
    .equ PCB_LR,    12
    .equ PCB_R0,    16
    .equ PCB_CPSR,  68
    .equ PCB_STATE, 72

    .equ STATE_READY,   1
    .equ STATE_RUNNING, 2

 // Vector table
    .section .text
    .align 5

_start:
vector_table:
    b reset_handler
    b undefined_handler
    b swi_handler
    b prefetch_handler
    b data_handler
    b .
    b irq_handler
    b fiq_handler


 // Reset handler
reset_handler:
    cpsid i

    // IRQ stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #0x12
    msr cpsr_c, r0
    ldr sp, =__irq_stack_top

    // SVC mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #0x13
    msr cpsr_c, r0
    ldr sp, =__os_stack_top

   // Clear .bss section
    ldr r0, =__bss_start__
    ldr r1, =__bss_end__
    mov r2, #0

clear_bss:
    cmp  r0, r1
    strlt r2, [r0], #4
    blt  clear_bss
    dsb
    isb

    // VBAR (when an interrupt happens, we jump here)
    ldr r0, =vector_table
    mcr p15, 0, r0, c12, c0, 0
    isb

    bl main @Start OS

hang:
    b hang

// Launches P1 
first_launch:
    mov r4, r0

    // Print that we are entering
    ldr r0, =msg_fl_enter
    bl  os_uart_puts


    // Process is running
    mov r1, #STATE_RUNNING
    str r1, [r4, #PCB_STATE]

    // Restore CPU state
    ldr r1, [r4, #PCB_CPSR]
    msr spsr_cxsf, r1

    // Restore stack and link register
    ldr sp, [r4, #PCB_SP]
    ldr lr, [r4, #PCB_LR]

    add r1, r4, #PCB_R0
    ldmia r1, {r0-r12}

    movs pc, lr @ Jump to process

// IRQ handler
irq_handler:
    sub lr, lr, #4 @ Return address
    stmfd sp!, {r0-r12, lr} @Save CPU registers


    // Save current process
    ldr r0, =current_proc
    ldr r0, [r0]
    cmp r0, #0
    beq .Lno_save

    // Save registers
    add r2, r0, #PCB_R0
    ldr r1, [sp, #0]  
    str r1, [r2, #0]
    ldr r1, [sp, #4]  
    str r1, [r2, #4]
    ldr r1, [sp, #8]  
    str r1, [r2, #8]
    ldr r1, [sp, #12] 
    str r1, [r2, #12]
    ldr r1, [sp, #16] 
    str r1, [r2, #16]
    ldr r1, [sp, #20] 
    str r1, [r2, #20]
    ldr r1, [sp, #24] 
    str r1, [r2, #24]
    ldr r1, [sp, #28] 
    str r1, [r2, #28]
    ldr r1, [sp, #32] 
    str r1, [r2, #32]
    ldr r1, [sp, #36] 
    str r1, [r2, #36]
    ldr r1, [sp, #40] 
    str r1, [r2, #40]
    ldr r1, [sp, #44] 
    str r1, [r2, #44]
    ldr r1, [sp, #48] 
    str r1, [r2, #48]

    // Save PC
    ldr r1, [sp, #52]
    str r1, [r0, #PCB_PC]

    // Save SVC SP and LR 
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #0x13
    msr cpsr_c, r2
    str sp, [r0, #PCB_SP]
    str lr, [r0, #PCB_LR]
    msr cpsr_c, r3

    // Save SPSR 
    mrs r1, spsr
    str r1, [r0, #PCB_CPSR]


    mov r1, #STATE_READY
    str r1, [r0, #PCB_STATE]

.Lno_save:
    // Call C handler
    and r4, sp, #4
    sub sp, sp, r4
    push {r4, lr}
    bl timer_irq_handler
    pop {r4, lr}
    add sp, sp, r4

    // Restore next process
    ldr r0, =next_proc
    ldr r0, [r0]

    mov r1, #STATE_RUNNING
    str r1, [r0, #PCB_STATE]

    ldr r1, [r0, #PCB_CPSR]
    msr spsr_cxsf, r1

    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #0x13
    msr cpsr_c, r2
    ldr sp, [r0, #PCB_SP]
    ldr lr, [r0, #PCB_LR]
    msr cpsr_c, r3

    ldr lr, [r0, #PCB_PC]

    add r1, r0, #PCB_R0
    ldmia r1, {r0-r12}

    add sp, sp, #56

    movs pc, lr

/* ============================================================
 * Exception stubs
 * ============================================================ */
undefined_handler:
    /* Print which address caused the fault, then hang */
    push {r0, lr}
    ldr  r0, =msg_undef
    bl   os_uart_puts
    pop  {r0, lr}
    b hang

// Saves registers and goes to syscall
swi_handler:

    mov r12, sp

    ldr sp, =__svc_stack_top

    stmfd sp!, {r0-r3, r12, lr}

    mov r0, sp
    bl syscall_handler

    ldmfd sp!, {r0-r3, r12, lr}

    mov sp, r12

    movs pc, lr


prefetch_handler:
data_handler:
fiq_handler:
    b hang



// Memory stuff
PUT32:
    str r1, [r0]
    bx  lr

GET32:
    ldr r0, [r0]
    bx  lr

enable_irq:
    mrs r0, cpsr
    bic r0, r0, #0x80
    msr cpsr_c, r0
    bx  lr

// To print for debugging
    .section .rodata
hex_chars:
    .ascii "0123456789ABCDEF"

msg_fl_enter:
    .asciz "[first_launch] entering\n"

msg_undef:
    .asciz "[UNDEF EXCEPTION]\n"