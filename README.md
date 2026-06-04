# PROJECT 2 - MULTIPROGRAMMING + EXECUTION MODES AND SYSCALLS

This project implements a minimal operating system for ARM, featuring:

- Basic kernel initialization
- UART output
- Timer interrupts
- Simple round-robin scheduler
- Context switching between two processes (P1 and P2)
- User/kernel privilege boundary (ARM USR mode)
- System calls (yield, exit, write)
- Fault detection, classification, and task isolation

---

## System Architecture

The system is divided into three main layers:

### 1. Hardware Abstraction Layer (OS/)

Handles direct interaction with hardware:

- UART (for output)
- Timer (for interrupts)
- Interrupt Controller (INTC)

This layer isolates platform differences between BeagleBone (real hardware) and QEMU.

### 2. Kernel (OS/)

Core responsibilities:

- Process management using PCBs (Process Control Blocks)
- Scheduling (Round Robin)
- Context switching (in assembly)
- Interrupt handling
- Syscall dispatching via SVC vector
- Fault handling and task isolation

### 3. User Processes (P1/, P2/)

Two independent user-mode processes:

- P1: prints numbers 0–9, exercises syscalls, and triggers a controlled fault
- P2: prints letters a–z and survives after P1 is killed by a fault

They use `PRINT("----FROM P1: %d\n", n)` instead of direct UART access, and
interact with the kernel exclusively through the syscall interface.

---

## User / Kernel Boundary

A central goal of Phase 2 is enforcing a strict privilege boundary:

- The **kernel** runs in privileged ARM modes (SVC, IRQ, ABT, UND)
- **User tasks** run in unprivileged ARM USR mode
- User code cannot execute privileged instructions or access kernel memory directly
- The only legal entry points from USR into the kernel are:
  - **Timer IRQ** (asynchronous preemption)
  - **SVC instruction** (voluntary syscall)
  - **Fault/abort** (hardware-enforced on illegal access)

Every USR ↔ kernel crossing emits a `MODE_SWITCH` trace line to serial output.

---

## Process Control Block (PCB)

Each process is represented by a `pcb_t` structure that stores the full CPU state
needed to correctly resume a task in USR mode:

```c
typedef struct PCB {
    int             pid;
    proc_state_t    state;        // READY, RUNNING, TERMINATED

    unsigned int    sp;
    unsigned int    pc;
    unsigned int    lr;
    unsigned int    registers[13]; // r0–r12
    unsigned int    cpsr;          // saved USR CPSR

    // Syscall transient state
    int             syscall_id;
    int             syscall_rc;

    // Fault and termination info
    fault_type_t    fault_type;    // FAULT_NONE, PREFETCH, DATA_*, UNDEFINED
    unsigned int    fault_addr;    // FAR value if applicable
    term_reason_t   term_reason;   // TERM_NONE, TERM_EXIT, TERM_FAULT
    int             exit_code;
} pcb_t;
```

---

## Context Switching

### Step-by-step (Timer IRQ path):

1. Timer interrupt fires → CPU jumps to `irq_handler`
2. Save current process state — registers pushed to IRQ stack, then copied into PCB
3. Emit trace: `MODE_SWITCH USER_TO_KERNEL pid=N reason=timer_irq`
4. Call C scheduler (`timer_irq_handler`) — picks next READY process, skipping TERMINATED ones
5. Emit trace: `MODE_SWITCH KERNEL_TO_USER pid=M reason=dispatch`
6. Restore next process registers, SP, LR, CPSR from its PCB
7. Exception return (`movs pc, lr`) → CPU enters USR mode at task's saved PC

---

## Timer and Scheduling

### Timer Interrupt

The hardware timer generates periodic interrupts.
BeagleBone: configured via memory-mapped registers.

### Ticks and Quantum

- A **tick** = one timer interrupt
- A **quantum** = number of ticks a process runs before switching

```c
static uint32_t timer_hz      = 10;  // 10 interrupts per second
static uint32_t quantum_ticks = 20;  // switch every 2 seconds
```

### Scheduler (Round Robin with state awareness)

The scheduler walks forward from the current process index and skips any
TERMINATED process, stopping at the first READY candidate:

```c
for (int i = 1; i <= num_procs; i++) {
    int candidate = current_idx + i;
    if (candidate >= num_procs) candidate -= num_procs;
    if (pcb_array[candidate].state != TERMINATED) {
        next_idx = candidate;
        break;
    }
}
```

If all processes are TERMINATED, the kernel prints a message and halts.

---

## System Calls

User tasks request kernel services by executing `svc #0` with arguments in registers.
The kernel dispatches by syscall ID in r0, runs the handler, and returns the result in r0.

### Register ABI

| Register | Role at entry       | Role at exit         |
|----------|---------------------|----------------------|
| r0       | Syscall ID          | Return value (int32) |
| r1       | Argument 1          | —                    |
| r2       | Argument 2          | —                    |
| r3       | Argument 3          | —                    |

### Syscall Table

| Symbol      | ID | Description                        |
|-------------|----|------------------------------------|
| `SYS_YIELD` | 0  | Voluntary reschedule               |
| `SYS_EXIT`  | 1  | Terminate caller, no return        |
| `SYS_WRITE` | 2  | Write bytes to UART from user buffer |

### Return Codes

| Value | Meaning                                  |
|-------|------------------------------------------|
| >= 0  | Success (byte count where applicable)    |
| -1    | Invalid syscall ID                       |
| -2    | Invalid file descriptor or argument      |
| -3    | Invalid user pointer / protection fault  |

### Syscall path trace example
MODE_SWITCH USER_TO_KERNEL pid=1 reason=syscall id=2
MODE_SWITCH KERNEL_TO_USER pid=1 reason=syscall_return id=2 rc=26

---

## Fault Handling and Task Isolation

When a user task causes an illegal operation, the CPU takes an abort or undefined
instruction exception. The kernel classifies the fault, terminates the offending task,
and resumes the next healthy task — the kernel and peer processes are never affected.

### Fault classification

| Fault type             | Cause                                              |
|------------------------|----------------------------------------------------|
| `FAULT_PREFETCH`       | Instruction fetch from unmapped/invalid address    |
| `FAULT_DATA_INVALID`   | Load/store to unmapped address (translation fault) |
| `FAULT_DATA_PERMISSION`| Load/store to privileged region from USR           |
| `FAULT_DATA_ALIGNMENT` | Misaligned word access with SCTLR.A enabled        |
| `FAULT_UNDEFINED`      | Architecturally undefined instruction executed     |

### Fault containment flow

1. CPU takes abort/undefined vector → privileged handler runs
2. Full USR context saved into PCB (same trap-frame layout as IRQ/SVC)
3. Emit trace: `MODE_SWITCH USER_TO_KERNEL pid=N reason=fault type=<type>`
4. `fault_handler()` reads IFSR/DFSR/FAR, classifies fault, fills PCB fault fields
5. Process marked `TERMINATED`, `term_reason = TERM_FAULT`, `exit_code = -1`
6. `schedule_next()` picks next READY process
7. Emit trace: `MODE_SWITCH KERNEL_TO_USER pid=M reason=fault_recovery`
8. Exception return → healthy task resumes in USR

### Fault trace example
[P1] Chapter 3 — triggering DATA ABORT now
MODE_SWITCH USER_TO_KERNEL pid=1 reason=fault type=data
[FAULT] pid=1 terminated
MODE_SWITCH KERNEL_TO_USER pid=2 reason=fault_recovery
[P2] Chapter 3 — P1 should be dead, I am still alive

---

## MODE_SWITCH Trace Catalog

Every USR ↔ kernel crossing produces one of these lines:

| # | Path        | Direction        | Trace line                                                    |
|---|-------------|------------------|---------------------------------------------------------------|
| 1 | Initial boot | Kernel → User   | `MODE_SWITCH KERNEL_TO_USER pid=N reason=initial_launch`      |
| 2 | Interrupt    | User → Kernel   | `MODE_SWITCH USER_TO_KERNEL pid=N reason=timer_irq`           |
| 3 | Interrupt    | Kernel → User   | `MODE_SWITCH KERNEL_TO_USER pid=M reason=dispatch`            |
| 4 | Syscall      | User → Kernel   | `MODE_SWITCH USER_TO_KERNEL pid=N reason=syscall id=X`        |
| 5 | Syscall      | Kernel → User   | `MODE_SWITCH KERNEL_TO_USER pid=M reason=syscall_return id=X rc=Y` |
| 6 | Fault        | User → Kernel   | `MODE_SWITCH USER_TO_KERNEL pid=N reason=fault type=T`        |
| 7 | Fault        | Kernel → User   | `MODE_SWITCH KERNEL_TO_USER pid=M reason=fault_recovery`      |

---

## Boot Process

### 1. Reset Handler (Assembly)
- Disables interrupts
- Sets up stack pointers for IRQ, SVC, ABT, and UND modes
- Clears `.bss`
- Installs vector table via VBAR
- Calls `main()`

### 2. Kernel Initialization
- Disables watchdog
- Initializes timer and interrupt controller
- Creates and initializes PCBs for P1 and P2
- Sets `current_proc`

### 3. First Launch
- `first_launch()` loads PCB state into CPU registers
- Sets SPSR to USR mode CPSR
- Writes USR SP/LR via SYS mode bank switch
- `movs pc, lr` → exception return into USR

### 4. Execution
Processes run in USR until a timer IRQ, syscall, or fault occurs.

---

## Example Output
[first_launch] entering
MODE_SWITCH KERNEL_TO_USER pid=1 reason=initial_launch
----FROM P1: 0
----FROM P2: a
...
[P1] Chapter 1 — valid sys_write
MODE_SWITCH USER_TO_KERNEL pid=1 reason=syscall id=2
MODE_SWITCH KERNEL_TO_USER pid=1 reason=syscall_return id=2 rc=26
[P1] sys_write(1) returned 26
...
[P1] Chapter 3 — triggering DATA ABORT now
MODE_SWITCH USER_TO_KERNEL pid=1 reason=fault type=data
[FAULT] pid=1 terminated
MODE_SWITCH KERNEL_TO_USER pid=2 reason=fault_recovery
[P2] Chapter 3 — P1 should be dead, I am still alive
...
[P2] clean exit
[SCHEDULER] All processes terminated.

---

## Main Concepts

- Correct context switching across IRQ, SVC, and abort paths
- ARM privilege levels and USR mode enforcement
- Syscall ABI design and dispatcher implementation
- Fault classification using CP15 registers (IFSR, DFSR, FAR)
- Task isolation — faulting process killed, peers unaffected
- Bare-metal programming on ARM Cortex-A8
- Interrupt handling and hardware abstraction
- Memory-mapped I/O

---

## Run on BeagleBone

To load on BeagleBone, if using macOS, set the correct serial port in `deploy_beagle.sh`, then:

```bash
make beagle
```

---

## Future Improvements

- Make the QEMU version fully functional (currently has issues)
- Enable the MMU to support true memory protection and translation faults
- Add a `SYS_READ` syscall
- Extend to more than two processes

---

## Credits

Raquel Urbina
Natalia Sosa