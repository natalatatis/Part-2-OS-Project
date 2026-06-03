#include <stdint.h>
#include <stddef.h>
#include "os.h"
#include "pcb.h"
#include "os_api.h"
#include "syscall.h"

#define NUM_PROCS 2

/* Addresses of the processes and their stacks */
#if defined(TARGET_QEMU)
#define P1_ENTRY     0x00100000u
#define P2_ENTRY     0x00200000u
#define P1_STACK_TOP 0x00112000u
#define P2_STACK_TOP 0x00212000u

#elif defined(TARGET_BEAGLE)

#define P1_ENTRY     0x82100000u
#define P2_ENTRY     0x82200000u

#define P1_STACK_TOP 0x82112000u
#define P2_STACK_TOP 0x82212000u

#else
#error "Define TARGET_QEMU or TARGET_BEAGLE"
#endif

pcb_t  pcb_array[NUM_PROCS];
pcb_t *current_proc = NULL;
pcb_t *next_proc    = NULL;
volatile int syscall_switch_requested = 0;

/* Number of timer interrupts per second */
static uint32_t timer_hz = 1;

/* Current tick counter */
static uint32_t tick_count = 0;

/* Quantums */
static uint32_t quantum_ticks;

/* Convert seconds to ticks */
static uint32_t seconds_to_ticks(uint32_t seconds) {
    return seconds * timer_hz;
}

void schedule_next(void);

extern void PUT32(uint32_t addr, uint32_t value);
extern uint32_t GET32(uint32_t addr);
extern void enable_irq(void);
extern void first_launch(pcb_t *pcb);

/* ------------------------------------------------ */

typedef enum { PLATFORM_BEAGLE = 0, PLATFORM_QEMU = 1 } platform_t;

#if defined(TARGET_BEAGLE)
static const platform_t current_platform = PLATFORM_BEAGLE;
#elif defined(TARGET_QEMU)
static const platform_t current_platform = PLATFORM_QEMU;
#else
#error "Compile with -DTARGET_BEAGLE or -DTARGET_QEMU"
#endif

typedef struct {
    uint32_t uart_base, uart_tx_reg, uart_status_reg;
    uint32_t uart_tx_ready_mask, uart_tx_ready_value;
    uint32_t timer_base, intc_base, wdt_base;
} hw_config_t;

static const hw_config_t hw_table[] = {
    [PLATFORM_BEAGLE] = {
        .uart_base           = 0x44E09000u,
        .uart_tx_reg         = 0x00u,
        .uart_status_reg     = 0x14u,
        .uart_tx_ready_mask  = 0x20u,
        .uart_tx_ready_value = 0x20u,
        .timer_base          = 0x48040000u,
        .intc_base           = 0x48200000u,
        .wdt_base            = 0x44E35000u
    },
    [PLATFORM_QEMU] = {
        .uart_base           = 0x101F1000u,
        .uart_tx_reg         = 0x00u,
        .uart_status_reg     = 0x18u,
        .uart_tx_ready_mask  = 0x20u,
        .uart_tx_ready_value = 0x00u,
        .timer_base          = 0x101E2000u,
        .intc_base           = 0x10140000u,
        .wdt_base            = 0x00000000u
    }
};

static inline const hw_config_t *hw(void) { return &hw_table[current_platform]; }

/* ============================================================
 * UART
 * ============================================================ */
void os_uart_putc(char c) {
    const hw_config_t *cfg = hw();
    while ((GET32(cfg->uart_base + cfg->uart_status_reg) & cfg->uart_tx_ready_mask)
           != cfg->uart_tx_ready_value) {
    }
    PUT32(cfg->uart_base + cfg->uart_tx_reg, (uint32_t)c);
}

void os_uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') os_uart_putc('\r');
        os_uart_putc(*s++);
    }
}


__attribute__((section(".os_api"), used))
const os_api_t os_api_table = {
    .putc = os_uart_putc,
    .puts = os_uart_puts
};

/* Function used to print addresses for debugging */
void print_dec(uint32_t v) {
    char buf[12];
    int i = 0;
    if (!v) {
        os_uart_putc('0');
        return;
    }
    while (v) {
        buf[i++] = '0' + (v % 10u);
        v /= 10u;
    }
    while (i--) os_uart_putc(buf[i]);
}

/* ============================================================
 * Watchdog
 * ============================================================ */
static void watchdog_disable(void) {
    if (current_platform != PLATFORM_BEAGLE) return;
    PUT32(hw()->wdt_base + 0x48u, 0x0000AAAAu);
    while (GET32(hw()->wdt_base + 0x34u)) {}
    PUT32(hw()->wdt_base + 0x48u, 0x00005555u);
    while (GET32(hw()->wdt_base + 0x34u)) {}
}

/* ============================================================
 * Timer init
 * ============================================================ */
static void timer_init_beagle(void) {
    const hw_config_t *cfg = hw();

    /* Disable timer */
    PUT32(cfg->timer_base + 0x38u, 0x0);

    /* Reset counter */
    PUT32(cfg->timer_base + 0x3Cu, 0x0);

    /* Load value for ~1 second */
    PUT32(cfg->timer_base + 0x40u, 0xFE000000u);
    PUT32(cfg->timer_base + 0x3Cu, 0xFE000000u);

    /* Enable overflow interrupt */
    PUT32(cfg->timer_base + 0x2Cu, 0x2u);

    /* Start timer: auto-reload + start */
    PUT32(cfg->timer_base + 0x38u, 0x3u);
}

static void timer_init_qemu(void) {
    const hw_config_t *cfg = hw();
    PUT32(cfg->timer_base + 0x08u, 0);
    PUT32(cfg->timer_base + 0x0Cu, 1);
    PUT32(cfg->timer_base + 0x00u, 1000000u);
    PUT32(cfg->timer_base + 0x08u, 0xE2u);
}

static void timer_init(void) {
    if (current_platform == PLATFORM_BEAGLE) timer_init_beagle();
    else                                      timer_init_qemu();
}

static void timer_ack(void) {
    const hw_config_t *cfg = hw();
    if (current_platform == PLATFORM_BEAGLE) {
        PUT32(cfg->timer_base + 0x28u, 0x2u);
        while (GET32(cfg->timer_base + 0x34u) & 1u) {}
    } else {
        PUT32(cfg->timer_base + 0x0Cu, 1u);
    }
}

/* ============================================================
 * INTC
 * ============================================================ */
static void intc_init_beagle(void) {
    PUT32(hw()->intc_base + 0x48u, 0x1u);
    PUT32(hw()->intc_base + 0xC8u, (1u << 4));
}

static void intc_init_qemu(void) {
    PUT32(hw()->intc_base + 0x0Cu, 0);
    PUT32(hw()->intc_base + 0x10u, (1u << 4));
}

static void intc_init(void) {
    if (current_platform == PLATFORM_BEAGLE) intc_init_beagle();
    else                                      intc_init_qemu();
}

static void intc_eoi(void) {
    if (current_platform == PLATFORM_BEAGLE)
        PUT32(hw()->intc_base + 0x48u, 0x1u);
    else
        PUT32(hw()->intc_base + 0x30u, 0);
}

/* ============================================================
 * Process Control Block setup
 * ============================================================ */
static void setup_initial_stack(pcb_t *pcb, unsigned int stack_top, unsigned int entry_point, int pid)
{
    int i;

    for (i = 0; i < 13; i++)
        pcb->registers[i] = 0;

    pcb->pid   = pid;
    pcb->sp    = stack_top;
    pcb->pc    = entry_point;
    pcb->lr    = entry_point;

#if defined(TARGET_QEMU) || defined(TARGET_BEAGLE)
    pcb->cpsr = 0x10u;
#endif

    pcb->state = READY;

    // Syscall transient state — cleared until first syscall
    pcb->syscall_id = -1;
    pcb->syscall_rc = 0;

    // Fault info — no fault has occurred yet
    pcb->fault_type  = FAULT_NONE;
    pcb->fault_addr  = 0;

    // Termination — process is alive, no exit yet
    pcb->term_reason = TERM_NONE;
    pcb->exit_code   = 0;
}
/* ============================================================
 * Main
 * ============================================================ */
int main(void) {
    watchdog_disable();

    os_uart_puts("OS booting...\nPlatform: ");
    os_uart_puts(current_platform == PLATFORM_BEAGLE ? "BEAGLE\n" : "QEMU\n");
    os_uart_puts("--------------------\n\n");

    intc_init();
    timer_init();

    setup_initial_stack(&pcb_array[0], P1_STACK_TOP, P1_ENTRY, 1);
    setup_initial_stack(&pcb_array[1], P2_STACK_TOP, P2_ENTRY, 2);

    current_proc = &pcb_array[0];
    next_proc    = &pcb_array[1];

    quantum_ticks = seconds_to_ticks(1);

    enable_irq();
    os_uart_puts("NOT WINDOWS XP \n");
    os_uart_puts("IRQs enabled\n");
    os_uart_puts("Calling first_launch for P1...\n");

    first_launch(current_proc);

    os_uart_puts("ERROR: first_launch returned!\n");

    #ifdef TARGET_QEMU   // ARMv5 / arm926ej-s
    while (1) { __asm__ volatile ("nop"); }   // safe spin
    #else                  // ARMv7+ / Cortex-A
        __asm__ volatile ("wfi");                 // low-power wait
    #endif

    return 0;
}

/* ============================================================
 * Timer IRQ handler
 * ============================================================ */
void timer_irq_handler(void) {
    timer_ack();
    intc_eoi();

    tick_count++;

    if (tick_count >= quantum_ticks) {
        tick_count = 0;

        int current_idx = current_proc->pid - 1;
        int num_procs = 2;
        int next_idx = current_idx;

        for (int i = 1; i <= num_procs; i++) {
            int candidate = current_idx + i;
            if (candidate >= num_procs)
                candidate -= num_procs;   

            if (pcb_array[candidate].state != TERMINATED) {
                next_idx = candidate;
                break;
            }
        }

        if (pcb_array[next_idx].state == TERMINATED) {
            os_uart_puts("[SCHEDULER] All processes terminated.\n");
            next_proc = current_proc;
            return;
        }

        next_proc = &pcb_array[next_idx];
        current_proc = next_proc;
    }
}

// SYSCALL HANDLER
void syscall_handler(uint32_t *stack_frame)
{
    uint32_t syscall_id = stack_frame[0];
    uint32_t arg1 = stack_frame[1];
    uint32_t arg2 = stack_frame[2];
    uint32_t arg3 = stack_frame[3];

    switch (syscall_id)
    {
        case SYS_YIELD:
        {
            pcb_t *target = (current_proc == &pcb_array[0]) ? &pcb_array[1] : &pcb_array[0];

            // Only switch if the target hasn't exited
            if (target->state != TERMINATED) {
                next_proc = target;
                
                // Ensure the current process is marked as READY before switching
                current_proc->state = READY;
                
                os_uart_puts("[SWITCHED TO ");
                print_dec(next_proc->pid);
                os_uart_puts("]\n");
                
                syscall_switch_requested = 1;
            } else {
                os_uart_puts("[YIELD: Target EXITED, continuing...]\n");
            }

            stack_frame[0] = 0; 
            break;
        }

        case SYS_EXIT:
        {
            current_proc->state = TERMINATED;

            os_uart_puts("[SYS_EXIT PID=");
            print_dec(current_proc->pid);
            os_uart_puts("]\n");

            os_uart_puts("P1 state=");
            print_dec(pcb_array[0].state);
            os_uart_puts(" P2 state=");
            print_dec(pcb_array[1].state);
            os_uart_puts("\n");
            
            pcb_t *next = (current_proc == &pcb_array[0]) ? &pcb_array[1] : &pcb_array[0];

            // This will evaluate to FALSE if next->state is 2
            if (next->state != TERMINATED) {
                next_proc = next;
                syscall_switch_requested = 1;
            } else {
                os_uart_puts("All processes terminated. System Halted.\n");
                while(1); 
            }
            break;
        }

        case SYS_WRITE:
        {
            int fd = (int)arg1;
            const char *buf = (const char *)arg2;
            uint32_t len = arg3;

            if (fd != 1)
            {
                stack_frame[0] = (uint32_t)-2;
                break;
            }

            if (buf == NULL)
            {
                stack_frame[0] = (uint32_t)-3;
                break;
            }

            if (len > 1024)
            {
                stack_frame[0] = (uint32_t)-2;
                break;
            }

            for (uint32_t i = 0; i < len; i++)
            {
                os_uart_putc(buf[i]);
            }

            stack_frame[0] = len;
            break;
        }

        default:
        {
            stack_frame[0] = (uint32_t)-1;
            break;
        }
    }
}


// Fault classification — called from assembly abort handlers
// mode: 0 = prefetch abort, 1 = data abort
void fault_handler(int mode) {
    if (current_proc == NULL) {
        os_uart_puts("[FAULT] no current process, halting\n");
        while(1);
    }

    unsigned int ifsr = 0, dfsr = 0, far_val = 0;

    if (mode == 0) {
        // Prefetch abort: read IFSR 
        __asm__ volatile("mrc p15, 0, %0, c5, c0, 1" : "=r"(ifsr));
        current_proc->fault_type = FAULT_PREFETCH;
        current_proc->fault_addr = current_proc->pc;
    } else {
        // Data abort: read DFSR (Data Fault Status Register) and FAR (Fault Address Register)
        __asm__ volatile("mrc p15, 0, %0, c5, c0, 0" : "=r"(dfsr));
        __asm__ volatile("mrc p15, 0, %0, c6, c0, 0" : "=r"(far_val));
        current_proc->fault_addr = far_val;

        // Combine bits [3:0] and bit [10] into a 5-bit fault status field 
        unsigned int fs = (dfsr & 0xF) | ((dfsr >> 6) & 0x10);

        switch (fs) {
            case 0x00:
                // Alignment fault 
                current_proc->fault_type = FAULT_DATA_ALIGNMENT;
                break;
            case 0x01: case 0x02: case 0x03:
            case 0x05: case 0x06: case 0x07:
                // Translation / mapping fault — address has no valid page table entry
                current_proc->fault_type = FAULT_DATA_INVALID;
                break;
            case 0x0D: case 0x0F:
                // Permission fault — address mapped but USR mode not allowed to access it
                current_proc->fault_type = FAULT_DATA_PERMISSION;
                break;
            default:
                // Catch-all for any other DFSR code (external abort, parity, etc.)
                current_proc->fault_type = FAULT_DATA_INVALID;
                break;
        }
    }

    current_proc->term_reason = TERM_FAULT;
    current_proc->exit_code   = -1;
    current_proc->state       = TERMINATED;

    os_uart_puts("[FAULT] pid=");
    os_uart_puts(" terminated\n");

    schedule_next();
}


// Picks the next READY process and writes it into next_proc
// Called after a fault or exit terminates the current process
// Same round robin logic as the irq_handler scheduler
void schedule_next(void) {
    int current_idx = current_proc->pid - 1;
    int num_procs = 2;
    int next_idx = current_idx;

    for (int i = 1; i <= num_procs; i++) {
        int candidate = current_idx + i;
        if (candidate >= num_procs)
            candidate -= num_procs;
        if (pcb_array[candidate].state != TERMINATED) {
            next_idx = candidate;
            break;
        }
    }

    if (pcb_array[next_idx].state == TERMINATED) {
        os_uart_puts("[SCHEDULER] All processes terminated.\n");
        next_proc = current_proc;
        return;
    }

    next_proc = &pcb_array[next_idx];
}
