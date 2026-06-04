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

    .equ PCB_PID,        0
    .equ PCB_STATE,      4
    .equ PCB_SP,         8
    .equ PCB_PC,         12
    .equ PCB_LR,         16
    .equ PCB_R0,         20
    .equ PCB_CPSR,       72
    .equ PCB_SYSCALL_ID, 76
    .equ PCB_SYSCALL_RC, 80
    .equ PCB_FAULT_TYPE, 84
    .equ PCB_FAULT_ADDR, 88
    .equ PCB_TERM_REASON,92
    .equ PCB_EXIT_CODE,  96

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
// reset_handler
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

    // Abort mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #0x17
    msr cpsr_c, r0
    ldr sp, =__irq_stack_top

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


// ============================================================
// print_dec  —  print r0 as unsigned decimal via os_uart_puts
print_dec:
    push {r4-r6, lr}
    mov  r4, r0

    // Handle negative: print '-' then negate
    cmp  r4, #0
    bge  .Lpd_positive
    push {r4}
    ldr  r0, =msg_minus
    bl   os_uart_puts
    pop  {r4}
    rsb  r4, r4, #0             // r4 = -r4

.Lpd_positive:
    ldr  r5, =print_dec_buf
    add  r6, r5, #10            // r6 = end of buffer
    mov  r3, #0
    strb r3, [r6]               // null-terminate

    // Special-case zero
    cmp  r4, #0
    bne  .Lpd_loop
    mov  r3, #'0'
    strb r3, [r5]
    add  r5, r5, #1
    mov  r3, #0
    strb r3, [r5]
    ldr  r0, =print_dec_buf
    bl   os_uart_puts
    pop  {r4-r6, pc}

.Lpd_loop:
    mov  r5, r6

.Lpd_digit:
    cmp  r4, #0
    beq  .Lpd_print
    sub  r5, r5, #1
    mov  r2, r4
    mov  r3, #0

.Lpd_div:
    cmp  r2, #10
    blt  .Lpd_div_done
    sub  r2, r2, #10
    add  r3, r3, #1
    b    .Lpd_div

.Lpd_div_done:
    add  r2, r2, #'0'
    strb r2, [r5]
    mov  r4, r3
    b    .Lpd_digit

.Lpd_print:
    mov  r0, r5
    bl   os_uart_puts
    pop  {r4-r6, pc}


// ============================================================
// first_launch  —  kernel → first USR task
//
// TRACE 1: MODE_SWITCH KERNEL_TO_USER pid=X reason=initial_launch
first_launch:
    mov r4, r0                      // r4 = PCB pointer

    ldr r0, =msg_fl_enter
    bl  os_uart_puts

    // Mark RUNNING
    mov r1, #STATE_RUNNING
    str r1, [r4, #PCB_STATE]

    //  TRACE 1 
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    ldr  r0, [r4, #PCB_PID]
    bl   print_dec
    ldr  r0, =msg_reason_initial
    bl   os_uart_puts

    // Load task CPSR into SPSR_svc so exception return sets USR mode
    ldr r1, [r4, #PCB_CPSR]
    msr spsr_cxsf, r1

    // Write USR sp and lr via SYS mode
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
// irq_handler  —  preemptive timer IRQ
//
// TRACE 2: MODE_SWITCH USER_TO_KERNEL pid=X reason=timer_irq   (after save)
// TRACE 3: MODE_SWITCH KERNEL_TO_USER pid=X reason=dispatch    (before return)
irq_handler:
    sub lr, lr, #4
    stmfd sp!, {r0-r12, lr}

    // Save current process context
    ldr r0, =current_proc
    ldr r0, [r0]
    cmp r0, #0
    beq .Lno_save

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

    ldr r1, [sp, #52]
    str r1, [r0, #PCB_PC]

    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    str sp, [r0, #PCB_SP]
    str lr, [r0, #PCB_LR]
    msr cpsr_c, r3

    mrs r1, spsr
    str r1, [r0, #PCB_CPSR]

    ldr r1, [r0, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq .Lno_mark_ready_irq

    mov r1, #STATE_READY
    str r1, [r0, #PCB_STATE]

.Lno_mark_ready_irq:

    // TRACE 2: USER_TO_KERNEL reason=timer_irq
    // r0 still holds current_proc PCB pointer here
    push {r0}
    ldr  r0, =msg_u2k_prefix
    bl   os_uart_puts
    pop  {r0}
    push {r0}
    ldr  r0, [r0, #PCB_PID]
    bl   print_dec
    pop  {r0}
    push {r0}
    ldr  r0, =msg_reason_timer
    bl   os_uart_puts
    pop  {r0}

.Lno_save:
    // Call C timer handler 
    and r4, sp, #4
    sub sp, sp, r4
    push {r4, lr}
    bl timer_irq_handler
    pop {r4, lr}
    add sp, sp, r4

    // Restore next_proc
    ldr r0, =next_proc
    ldr r0, [r0]

    // TRACE 3: KERNEL_TO_USER reason=dispatch
    push {r0}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r0}
    push {r0}
    ldr  r0, [r0, #PCB_PID]
    bl   print_dec
    pop  {r0}
    push {r0}
    ldr  r0, =msg_reason_dispatch
    bl   os_uart_puts
    pop  {r0}

    mov r1, #STATE_RUNNING
    str r1, [r0, #PCB_STATE]

    ldr r1, [r0, #PCB_CPSR]
    msr spsr_cxsf, r1

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
// TRACE 4: MODE_SWITCH USER_TO_KERNEL pid=X reason=syscall id=Y  (after save)
// TRACE 5: MODE_SWITCH KERNEL_TO_USER pid=X reason=syscall_return id=Y rc=Z
swi_handler:
    stmfd sp!, {r0-r12, lr}

    ldr r4, =current_proc
    ldr r4, [r4]
    cmp r4, #0
    beq .Lswi_no_save

    add r2, r4, #PCB_R0
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

    ldr r1, [sp, #52]
    str r1, [r4, #PCB_PC]

    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    str sp, [r4, #PCB_SP]
    str lr, [r4, #PCB_LR]
    msr cpsr_c, r3

    mrs r1, spsr
    str r1, [r4, #PCB_CPSR]

    ldr r1, [r4, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq .Lswi_no_mark_ready

    mov r1, #STATE_READY
    str r1, [r4, #PCB_STATE]

.Lswi_no_mark_ready:

    // TRACE 4: USER_TO_KERNEL reason=syscall id=X
    ldr  r5, [sp, #0]               // r5 = syscall ID 

    push {r4, r5}
    ldr  r0, =msg_u2k_prefix
    bl   os_uart_puts
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, [r4, #PCB_PID]
    bl   print_dec
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, =msg_reason_syscall
    bl   os_uart_puts
    pop  {r4, r5}

    push {r4, r5}
    mov  r0, r5                     // syscall ID
    bl   print_dec
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, =msg_newline
    bl   os_uart_puts
    pop  {r4, r5}

.Lswi_no_save:
    ldr r0, =next_proc
    str r4, [r0]

    mov r0, sp
    bl  syscall_handler
    // sp[0] now holds the rc that syscall_handler wrote back
    // r4 = current PCB, r5 = syscall ID 

    ldr r0, =syscall_switch_requested
    ldr r0, [r0]
    cmp r0, #0
    bne .Lswi_do_switch

    //  No switch: TRACE 5 
    push {r4, r5}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, [r4, #PCB_PID]
    bl   print_dec
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, =msg_reason_sysret
    bl   os_uart_puts
    pop  {r4, r5}

    push {r4, r5}
    mov  r0, r5                     // syscall ID 
    bl   print_dec
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, =msg_rc_prefix
    bl   os_uart_puts
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, [sp, #8]               
    bl   print_dec
    pop  {r4, r5}

    push {r4, r5}
    ldr  r0, =msg_newline
    bl   os_uart_puts
    pop  {r4, r5}


    ldmfd sp!, {r0-r12, lr}
    movs  pc, lr

.Lswi_do_switch:
    mov r1, #0
    ldr r2, =syscall_switch_requested
    str r1, [r2]

    add sp, sp, #56

    b restore_process

// ============================================================
// restore_process  —  resume next_proc in USR mode
// TRACE 5 (switch path): KERNEL_TO_USER pid=X reason=syscall_return id=? rc=?
restore_process:
    ldr r4, =next_proc
    ldr r4, [r4]

    ldr r1, =current_proc
    str r4, [r1]

    ldr r1, [r4, #PCB_STATE]
    cmp r1, #STATE_TERMINATED
    beq hang

    push {r4}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r4}
    push {r4}
    ldr  r0, [r4, #PCB_PID]
    bl   print_dec
    pop  {r4}
    push {r4}
    ldr  r0, =msg_reason_dispatch
    bl   os_uart_puts
    pop  {r4}

    mov r1, #STATE_RUNNING
    str r1, [r4, #PCB_STATE]

    ldr r1, [r4, #PCB_CPSR]
    msr spsr_cxsf, r1

    mrs r3, cpsr
    bic r2, r3, #0x1F
    orr r2, r2, #MODE_SYS
    msr cpsr_c, r2
    ldr sp, [r4, #PCB_SP]
    ldr lr, [r4, #PCB_LR]
    msr cpsr_c, r3

    ldr lr, [r4, #PCB_PC]

    add r1, r4, #PCB_R0
    ldmia r1, {r0-r12}

    movs pc, lr


// ============================================================
// Exception stubs
// ============================================================
undefined_handler:
    sub  lr, lr, #4
    stmfd sp!, {r0-r12, lr}

    // Save context into current_proc 
    ldr  r0, =current_proc
    ldr  r0, [r0]
    cmp  r0, #0
    beq  .Lund_no_save

    add  r2, r0, #PCB_R0
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

    ldr  r1, [sp, #52]
    str  r1, [r0, #PCB_PC]

    mrs  r3, cpsr
    bic  r2, r3, #0x1F
    orr  r2, r2, #MODE_SYS
    msr  cpsr_c, r2
    str  sp, [r0, #PCB_SP]
    str  lr, [r0, #PCB_LR]
    msr  cpsr_c, r3

    mrs  r1, spsr
    str  r1, [r0, #PCB_CPSR]

    // TRACE 6: USER_TO_KERNEL reason=fault type=undefined 
    push {r0}
    ldr  r0, =msg_u2k_prefix
    bl   os_uart_puts
    pop  {r0}
    push {r0}
    ldr  r0, [r0, #PCB_PID]
    bl   print_dec
    pop  {r0}
    push {r0}
    ldr  r0, =msg_reason_fault_undef
    bl   os_uart_puts
    pop  {r0}
    // -----------------------------------------------------------

.Lund_no_save:
    // Call C fault classifier with mode=2 (undefined instruction)
    and  r4, sp, #4
    sub  sp, sp, r4
    push {r4, lr}
    mov  r0, #2
    bl   fault_handler
    pop  {r4, lr}
    add  sp, sp, r4

    // --- TRACE 7 ---
    ldr  r0, =next_proc
    ldr  r5, [r0]
    push {r5}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r5}
    push {r5}
    ldr  r0, [r5, #PCB_PID]
    bl   print_dec
    pop  {r5}
    push {r5}
    ldr  r0, =msg_reason_fault_recovery
    bl   os_uart_puts
    pop  {r5}
    // ---------------

    add  sp, sp, #56
    b    restore_process

// ============================================================
// prefetch_abort_handler — instruction fetch fault from USR
prefetch_handler:
    sub  lr, lr, #4             // adjust to faulting instruction
    stmfd sp!, {r0-r12, lr}

    // Save context into current_proc 
    ldr  r0, =current_proc
    ldr  r0, [r0]
    cmp  r0, #0
    beq  .Lpf_no_save

    add  r2, r0, #PCB_R0
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

    ldr  r1, [sp, #52]        
    str  r1, [r0, #PCB_PC]

    mrs  r3, cpsr
    bic  r2, r3, #0x1F
    orr  r2, r2, #MODE_SYS
    msr  cpsr_c, r2
    str  sp, [r0, #PCB_SP]
    str  lr, [r0, #PCB_LR]
    msr  cpsr_c, r3

    mrs  r1, spsr
    str  r1, [r0, #PCB_CPSR]

    // TRACE 6: USER_TO_KERNEL reason=fault type=prefetch
    push {r0}
    ldr  r0, =msg_u2k_prefix
    bl   os_uart_puts
    pop  {r0}
    push {r0}
    ldr  r0, [r0, #PCB_PID]
    bl   print_dec
    pop  {r0}
    push {r0}
    ldr  r0, =msg_reason_fault_prefetch
    bl   os_uart_puts
    pop  {r0}

.Lpf_no_save:
    // Call C fault classifier (mode=0 → prefetch)
    and  r4, sp, #4
    sub  sp, sp, r4
    push {r4, lr}
    mov  r0, #0
    bl   fault_handler
    pop  {r4, lr}
    add  sp, sp, r4

    // TRACE 7: KERNEL_TO_USER reason=fault_recovery
    ldr  r0, =next_proc
    ldr  r5, [r0]               // r5 = next PCB
    push {r5}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r5}
    push {r5}
    ldr  r0, [r5, #PCB_PID]
    bl   print_dec
    pop  {r5}
    push {r5}
    ldr  r0, =msg_reason_fault_recovery
    bl   os_uart_puts
    pop  {r5}

    add  sp, sp, #56
    b    restore_process


// ==================================================
// data_abort_handler — data access fault from USR
data_handler:
    sub  lr, lr, #8             // adjust to faulting instruction
    stmfd sp!, {r0-r12, lr}

    ldr  r0, =current_proc
    ldr  r0, [r0]
    cmp  r0, #0
    beq  .Lda_no_save

    add  r2, r0, #PCB_R0
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

    ldr  r1, [sp, #52]
    str  r1, [r0, #PCB_PC]

    mrs  r3, cpsr
    bic  r2, r3, #0x1F
    orr  r2, r2, #MODE_SYS
    msr  cpsr_c, r2
    str  sp, [r0, #PCB_SP]
    str  lr, [r0, #PCB_LR]
    msr  cpsr_c, r3

    mrs  r1, spsr
    str  r1, [r0, #PCB_CPSR]

    // USER_TO_KERNEL reason=fault type=data 
    push {r0}
    ldr  r0, =msg_u2k_prefix
    bl   os_uart_puts
    pop  {r0}
    push {r0}
    ldr  r0, [r0, #PCB_PID]
    bl   print_dec
    pop  {r0}
    push {r0}
    ldr  r0, =msg_reason_fault_data
    bl   os_uart_puts
    pop  {r0}

.Lda_no_save:
    and  r4, sp, #4
    sub  sp, sp, r4
    push {r4, lr}
    mov  r0, #1
    bl   fault_handler          // mode=1 → data abort
    pop  {r4, lr}
    add  sp, sp, r4

    //  TRACE 7 
    ldr  r0, =next_proc
    ldr  r5, [r0]
    push {r5}
    ldr  r0, =msg_k2u_prefix
    bl   os_uart_puts
    pop  {r5}
    push {r5}
    ldr  r0, [r5, #PCB_PID]
    bl   print_dec
    pop  {r5}
    push {r5}
    ldr  r0, =msg_reason_fault_recovery
    bl   os_uart_puts
    pop  {r5}


    add  sp, sp, #56
    b    restore_process

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

// Trace message fragments
msg_k2u_prefix:
    .asciz "MODE_SWITCH KERNEL_TO_USER pid="

msg_u2k_prefix:
    .asciz "MODE_SWITCH USER_TO_KERNEL pid="

msg_reason_initial:
    .asciz " reason=initial_launch\n"

msg_reason_timer:
    .asciz " reason=timer_irq\n"

msg_reason_dispatch:
    .asciz " reason=dispatch\n"

msg_reason_syscall:
    .asciz " reason=syscall id="

msg_reason_sysret:
    .asciz " reason=syscall_return id="

msg_rc_prefix:
    .asciz " rc="

msg_newline:
    .asciz "\n"

msg_minus:
    .asciz "-"

msg_reason_fault_prefetch:
    .asciz " reason=fault type=prefetch\n"

msg_reason_fault_data:
    .asciz " reason=fault type=data\n"

msg_reason_fault_recovery:
    .asciz " reason=fault_recovery\n"

msg_reason_fault_undef:
    .asciz " reason=fault type=undefined\n"
    
// ============================================================
// BSS — print_dec scratch buffer (11 bytes: max 10 digits + null)
// ============================================================
    .section .bss
    .align 2
print_dec_buf:
    .space 12