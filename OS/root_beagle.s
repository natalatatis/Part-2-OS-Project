// root_beagle.s  

    .syntax unified
    .code 32

    .globl _start
    .globl PUT32
    .globl GET32
    .globl enable_irq
    .globl first_launch
    .globl restore_process

    .extern main
    .extern timer_irq_handler
    .extern current_proc
    .extern next_proc
    .extern os_uart_puts
    .extern syscall_handler
    .extern syscall_switch_requested

    .extern __bss_start__
    .extern __bss_end__
    .extern __os_stack_top
    .extern __irq_stack_top

    .equ PCB_PID,   0
    .equ PCB_SP,    4
    .equ PCB_PC,    8
    .equ PCB_LR,    12
    .equ PCB_R0,    16
    .equ PCB_CPSR,  68
    .equ PCB_STATE, 72

    .equ STATE_READY,   0
    .equ STATE_RUNNING, 1
    .equ STATE_TERMINATED, 2

    .equ MODE_USR, 0x10
    .equ MODE_SYS, 0x1F

 // ============================================================
 // Vector table
 // ============================================================
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


 // ============================================================
 // Reset handler
 // ============================================================
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

    // Clear .bss
    ldr r0, =__bss_start__
    ldr r1, =__bss_end__
    mov r2, #0
clear_bss:
    cmp  r0, r1
    strlt r2, [r0], #4
    blt  clear_bss
    dsb
    isb

    // Install vector table via VBAR
    ldr r0, =vector_table
    mcr p15, 0, r0, c12, c0, 0
    isb

    bl main

hang:
    b hang


 
 // first_launch  —  kernel → first USR task
 
 // r0 = pcb_t* of task to launch
 // Uses SYS mode to write USR sp/lr, then exception-returns
 // into USR via movs pc, lr.
first_launch:
    mov r4, r0                      // r4 = PCB pointer

    ldr r0, =msg_fl_enter
    bl  os_uart_puts

    // Mark RUNNING
    mov r1, #STATE_RUNNING
    str r1, [r4, #PCB_STATE]

    // Load task CPSR into SPSR_svc so exception return sets USR mode
    ldr r1, [r4, #PCB_CPSR]
    msr spsr_cxsf, r1

    // Write USR sp and lr via SYS mode (shares USR register bank)
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    ldr sp, [r4, #PCB_SP]
    ldr lr, [r4, #PCB_LR]
    msr cpsr_c, r3                  // back to SVC

    // LR_svc = entry PC  (movs pc, lr will use this)
    ldr lr, [r4, #PCB_PC]

    // Restore r0-r12
    add r1, r4, #PCB_R0
    ldmia r1, {r0-r12}

    movs pc, lr                     // exception return → USR


 // ============================================================
 // irq_handler  —  preemptive timer IRQ
 // ============================================================
irq_handler:
    sub lr, lr, #4
    stmfd sp!, {r0-r12, lr}

    // Save current process context
    ldr r0, =current_proc
    ldr r0, [r0]
    cmp r0, #0
    beq .Lno_save

    // Save r0-r12 from IRQ stack frame into PCB.registers
    add r2, r0, #PCB_R0
    ldr r1, [sp, #0];  str r1, [r2, #0]
    ldr r1, [sp, #4];  str r1, [r2, #4]
    ldr r1, [sp, #8];  str r1, [r2, #8]
    ldr r1, [sp, #12]; str r1, [r2, #12]
    ldr r1, [sp, #16]; str r1, [r2, #16]
    ldr r1, [sp, #20]; str r1, [r2, #20]
    ldr r1, [sp, #24]; str r1, [r2, #24]
    ldr r1, [sp, #28]; str r1, [r2, #28]
    ldr r1, [sp, #32]; str r1, [r2, #32]
    ldr r1, [sp, #36]; str r1, [r2, #36]
    ldr r1, [sp, #40]; str r1, [r2, #40]
    ldr r1, [sp, #44]; str r1, [r2, #44]
    ldr r1, [sp, #48]; str r1, [r2, #48]

    // Save PC (adjusted lr on stack at offset 52)
    ldr r1, [sp, #52]
    str r1, [r0, #PCB_PC]

    // Save USR sp and lr via SYS mode bank switch
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    str sp, [r0, #PCB_SP]
    str lr, [r0, #PCB_LR]
    msr cpsr_c, r3

    // Save SPSR (USR CPSR)
    mrs r1, spsr
    str r1, [r0, #PCB_CPSR]

    ldr r1, [r0, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq .Lno_mark_ready_irq

    mov r1, #STATE_READY
    str r1, [r0, #PCB_STATE]

.Lno_mark_ready_irq:

.Lno_save:
    // Call C timer handler (align stack per AAPCS)
    and r4, sp, #4
    sub sp, sp, r4
    push {r4, lr}
    bl timer_irq_handler
    pop {r4, lr}
    add sp, sp, r4

    // Restore next_proc
    ldr r0, =next_proc
    ldr r0, [r0]

    mov r1, #STATE_RUNNING
    str r1, [r0, #PCB_STATE]

    ldr r1, [r0, #PCB_CPSR]
    msr spsr_cxsf, r1

    // Restore USR sp/lr via SYS mode
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    ldr sp, [r0, #PCB_SP]
    ldr lr, [r0, #PCB_LR]
    msr cpsr_c, r3

    ldr lr, [r0, #PCB_PC]

    add r1, r0, #PCB_R0
    ldmia r1, {r0-r12}

    add sp, sp, #56
    movs pc, lr


 // ============================================================
 // swi_handler  —  SYS_YIELD / SYS_WRITE / SYS_EXIT
 //
swi_handler:
    stmfd sp!, {r0-r12, lr}

    // Save USR context into current_proc PCB 
    ldr r4, =current_proc
    ldr r4, [r4]                    
    cmp r4, #0
    beq .Lswi_no_save

    // Save r0-r12: read original values from the stack frame
    add r2, r4, #PCB_R0
    ldr r1, [sp, #0];  str r1, [r2, #0]   // r0 (syscall id)
    ldr r1, [sp, #4];  str r1, [r2, #4]   // r1
    ldr r1, [sp, #8];  str r1, [r2, #8]   // r2
    ldr r1, [sp, #12]; str r1, [r2, #12]  // r3
    ldr r1, [sp, #16]; str r1, [r2, #16]  // r4
    ldr r1, [sp, #20]; str r1, [r2, #20]  // r5
    ldr r1, [sp, #24]; str r1, [r2, #24]  // r6
    ldr r1, [sp, #28]; str r1, [r2, #28]  // r7
    ldr r1, [sp, #32]; str r1, [r2, #32]  // r8
    ldr r1, [sp, #36]; str r1, [r2, #36]  // r9
    ldr r1, [sp, #40]; str r1, [r2, #40]  // r10
    ldr r1, [sp, #44]; str r1, [r2, #44]  // r11
    ldr r1, [sp, #48]; str r1, [r2, #48]  // r12

    // Save PC = LR_svc = address after the svc instruction
    ldr r1, [sp, #52]
    str r1, [r4, #PCB_PC]

    // Save USR sp and lr via SYS mode bank switch
    // (SVC sp/lr are banked; SYS shares USR's registers)
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    str sp, [r4, #PCB_SP]           // save USR stack pointer
    str lr, [r4, #PCB_LR]           // save USR link register
    msr cpsr_c, r3                  // back to SVC

    // Save SPSR_svc 
    mrs r1, spsr
    str r1, [r4, #PCB_CPSR]

    ldr r1, [r4, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq .Lswi_no_mark_ready

    mov r1, #STATE_READY
    str r1, [r4, #PCB_STATE]

.Lswi_no_mark_ready:

.Lswi_no_save:
    // Default next_proc = current_proc (syscall_handler may change it)
    ldr r0, =next_proc
    str r4, [r0]

    // Call syscall_handler(stack_frame*)  — r0 = sp (stack frame pointer)
    mov r0, sp
    bl  syscall_handler
    // r4 is callee-saved so it still holds the PCB pointer

    // Check if a context switch was requested
    ldr r0, =syscall_switch_requested
    ldr r0, [r0]
    cmp r0, #0
    bne .Lswi_do_switch

    // ------- No switch: return to the same task -------
    // Restore r0 with the return value syscall_handler wrote into stack[0]
    ldmfd sp!, {r0-r12, lr}         // restore all regs (including syscall rc in r0)
    movs  pc, lr                    // exception return → USR (CPSR ← SPSR_svc)

    // ------- Switch: restore next_proc -------
.Lswi_do_switch:
    // Clear the flag
    mov r1, #0
    ldr r2, =syscall_switch_requested
    str r1, [r2]

    // Discard the SVC stack frame (we will restore from PCB instead)
    add sp, sp, #56                 // 14 regs × 4 = 56 bytes

    b restore_process



 // restore_process  —  resume next_proc in USR mode
restore_process:
    ldr r4, =next_proc
    ldr r4, [r4]                    // r4 = next PCB 

    // Update current_proc
    ldr r1, =current_proc
    str r4, [r1]

    ldr r1, [r4, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq hang

    mov r1, #STATE_RUNNING
    str r1, [r4, #PCB_STATE]

    // Load task CPSR into SPSR so exception return enters USR
    ldr r1, [r4, #PCB_CPSR]
    msr spsr_cxsf, r1

    // Restore USR sp and lr via SYS mode bank switch
    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    ldr sp, [r4, #PCB_SP]
    ldr lr, [r4, #PCB_LR]
    msr cpsr_c, r3                  // back to SVC

    ldr lr, [r4, #PCB_PC]

    add r1, r4, #PCB_R0
    ldmia r1, {r0-r12}

    movs pc, lr                     // exception return → USR


 // ============================================================
 // Exception stubs
 // ============================================================
undefined_handler:
    push {r0, lr}
    ldr  r0, =msg_undef
    bl   os_uart_puts
    pop  {r0, lr}
    b hang

prefetch_handler:
data_handler:
fiq_handler:
    b hang


 // ============================================================
 // Low-level memory accessors
 // ============================================================
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


 // ============================================================
 // Read-only data
 // ============================================================
    .section .rodata

msg_fl_enter:
    .asciz "[first_launch] entering\n"

msg_undef:
    .asciz "[UNDEF EXCEPTION]\n"