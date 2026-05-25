# PROJECT 1 - MULTIPROGRAMMING

This project implements a minimal operating system for ARM, featuring:

- Basic kernel initialization
- UART output
- Timer interrupts
- Simple round-robin scheduler
- Context switching between two processes (P1 and P2)

### System Architecture

The system is divided into three main layers:

1. Hardware Abstraction Layer (OS/)

Handles direct interaction with hardware:

UART (for output)
Timer (for interrupts)
Interrupt Controller (INTC)

This layer isolates platform differences between:

BeagleBone (real hardware)

2. Kernel (OS/)

Core responsibilities:

Process management using PCBs (Process Control Blocks)
Scheduling (Round Robin)
Context switching (in assembly)
Interrupt handling

3. User Processes (P1/, P2/)

Two independent processes:

P1: prints numbers 0–9 in a loop
P2: prints letters a–z in a loop

They use: PRINT("----FROM P1: %d\n", n); instead of direct UART access.

Process Management
Process Control Block (PCB)

Each process is represented by a pcb_t structure:

Each PCB stores the entire CPU state of a process.


### Step-by-step:
1. Interrupt occurs (timer)
CPU jumps to irq_handler
2. Save current process state

Registers are pushed to stack and then stored in the PCB

3. Call scheduler (C code)
timer_irq_handler();

This decides the next process:

``next_proc = (current_proc->pid == 1) ? &pcb_array[1] : &pcb_array[0];``

4. Restore next process

Registers and state are restored:

The CPU resumes execution of the next process.

### Timer and Scheduling
Timer Interrupt

The hardware timer generates periodic interrupts.

BeagleBone: configured via memory-mapped registers

Ticks and Quantum
A tick = one timer interrupt
A quantum = number of ticks a process runs before switching

Example:

static uint32_t timer_hz = 10;     // 10 interrupts per second
static uint32_t quantum_ticks = 20; // switch every 2 seconds


### Scheduler (Round Robin)

The scheduler alternates between processes:

if (tick_count >= quantum_ticks) {
    tick_count = 0;
    switch process;
}


### Boot Process
1. Reset Handler (Assembly)
Disables interrupts
Sets up stack pointers (IRQ and SVC)
Clears .bss
Sets vector table
Calls main()
2. Kernel Initialization
Disables watchdog
Initializes timer and interrupt controller
Creates PCBs
Sets first process
3. First Launch
first_launch:
Loads PCB into CPU registers
Jumps to process entry point
4. Execution Begins

Process runs until:

Timer interrupt occurs
Context switch happens

### Example Output
----FROM P1: 0
----FROM P1: 1
...
----FROM P2: a
----FROM P2: b
...


## Main concepts learnt

- Correct context switching
- Independent execution of processes
- Bare-metal programming
- Interrupt handling
- Context switching
- Scheduling (Round Robin)
- Hardware abstraction
-Memory-mapped I/O


## Run on Beagle
To load on beagle, if using MacOS, just go to deploy_beagle.sh and set the port where your Beagle is at. Then just compile with 
``
make beagle
``


## Future improvements
Make the QEMU version fully functional, as at the moment, it has some issues.


### Creditos
Raquel Urbina
Natalia Sosa