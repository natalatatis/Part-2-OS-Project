//Process Control Block
#ifndef PCB_H
#define PCB_H 

// States
typedef enum{
    READY, 
    RUNNING,
    TERMINATED
} proc_state_t;

typedef struct PCB{
    // Process ID
    int pid;
    // Stack pointer
    unsigned int sp;
    // Program counter
    unsigned int pc;
    // Link register
    unsigned int lr;
    // General-purpose registers (r0-r12)
    unsigned int registers[13];
    // Status register
    unsigned int cpsr;
    // State
    proc_state_t state;

} pcb_t;

#endif