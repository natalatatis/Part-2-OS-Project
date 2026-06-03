//Process Control Block
#ifndef PCB_H
#define PCB_H 

// States
typedef enum{
    READY, 
    RUNNING,
    TERMINATED
} proc_state_t;

// Fault classification
typedef enum{
    FAULT_NONE = 0,
    FAULT_PREFETCH,
    FAULT_DATA_INVALID,
    FAULT_DATA_PERMISSION,
    FAULT_DATA_ALIGNMENT,
    FAULT_UNDEFINED,
} fault_type_t;

// Termination reason
typedef enum{
    TERM_NONE = 0,
    TERM_EXIT,
    TERM_FAULT,
} term_reason_t;


typedef struct PCB{
    // Process ID
    int pid;
    // State
    proc_state_t state;

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

    // syscall id
    int syscall_id;
    //return value
    int syscall_rc;

    // Fault type
    fault_type_t fault_type;
    // Fault address register
    unsigned int fault_addr;
    // Termination reason
    term_reason_t term_reason;
    // Exit code
    int exit_code;

} pcb_t;

#endif