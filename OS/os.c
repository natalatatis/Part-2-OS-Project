#include <stdint.h>
#include <stddef.h>
#include "os.h"
#include "pcb.h"
#include "os_api.h"

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
static void print_dec(uint32_t v) {
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
    pcb->cpsr = 0x10u;  /* USR mode for both */
#endif

    pcb->state = READY;
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

        next_proc = (current_proc->pid == 1)
                  ? &pcb_array[1]
                  : &pcb_array[0];

        /* Correctly update current_proc for context switching */
        current_proc = next_proc;
    }
}