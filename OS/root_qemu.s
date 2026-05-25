@ Add these globals at the top of the file
.globl PUT32
.globl GET32
.globl enable_irq
.globl irq_handler

@ ... existing vector table and reset_handler code ...

@ ============================================================
@ IRQ Handler - Logic for context switching
@ ============================================================
irq_handler:
    sub lr, lr, #4
    stmfd sp!, {r0-r12, lr}      @ Save registers to IRQ stack

    ldr r0, =current_proc
    ldr r0, [r0]
    cmp r0, #0
    beq .Lno_save

    @ Save SVC SP and LR by switching modes 
    mrs r1, spsr
    str r1, [r0, #68]            @ Save SPSR (process CPSR) to PCB offset 68
    
    mrs r3, cpsr
    msr cpsr_c, #0x13            @ Switch to SVC mode
    str sp, [r0, #4]             @ Save SP to PCB offset 4
    str lr, [r0, #12]            @ Save LR to PCB offset 12
    msr cpsr_c, r3               @ Back to IRQ mode

    @ Save PC (stored as LR on stack)
    ldr r1, [sp, #52]
    str r1, [r0, #8]             @ Save PC to PCB offset 8

    @ Save R0-R12
    add r2, r0, #16              @ R0 offset in PCB
    mov r1, sp
    ldmia r1!, {r3-r12}          @ Use temp registers to avoid r0/r2 corruption
    stmia r2!, {r3-r12}

.Lno_save:
    bl timer_irq_handler         @ Call C scheduler

    @ Restore next process
    ldr r0, =next_proc
    ldr r0, [r0]

    ldr r1, [r0, #68]
    msr spsr_cxsf, r1            @ Restore SPSR

    mrs r3, cpsr
    msr cpsr_c, #0x13
    ldr sp, [r0, #4]             @ Restore SVC SP
    ldr lr, [r0, #12]            @ Restore SVC LR
    msr cpsr_c, r3

    ldr lr, [r0, #8]             @ Restore PC into LR for return
    add r1, r0, #16
    ldmia r1, {r0-r12}           @ Restore R0-R12

    add sp, sp, #56              @ Clean up IRQ stack
    movs pc, lr                  @ Exception return 

@ ============================================================
@ Hardware Helpers
@ ============================================================
PUT32:
    str r1, [r0]
    bx lr

GET32:
    ldr r0, [r0]
    bx lr

enable_irq:
    mrs r0, cpsr
    bic r0, r0, #0x80            @ Clear I-bit to enable IRQs
    msr cpsr_c, r0
    bx lr