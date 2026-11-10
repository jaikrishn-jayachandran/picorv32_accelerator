
#include <stdint.h>

// ============================================================
// SoC Memory Map
// ============================================================

#define RAM_BASE        0x00000000u
#define UART_DEBUG      0x20000000u
#define SIM_EXIT        0x20000004u

#define FFT_CTRL_BASE   0x30000000u

#define FFT_REG_CTRL    0x00u
#define FFT_REG_STATUS  0x04u
#define FFT_REG_N       0x08u

#define FFT_STATUS_BUSY (1u << 0)
#define FFT_STATUS_DONE (1u << 1)

#define FFT_LENGTH      64u

#define FFT_INPUT_OFFSET  0x1000u

#define FFT_TIMEOUT     1000000u

// ============================================================
// MMIO
// ============================================================

#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

// ============================================================
// Debug Output
// ============================================================

static void debug_putchar(char c)
{
    REG32(UART_DEBUG) = (uint32_t)(uint8_t)c;
}

static void print(const char *s)
{
    while (*s)
        debug_putchar(*s++);
}

static void print_uint(uint32_t value)
{
    char buffer[11];
    uint32_t i = 0;

    if (value == 0)
    {
        debug_putchar('0');
        return;
    }

    while (value > 0)
    {
        buffer[i++] = '0' + (value % 10u);
        value /= 10u;
    }

    while (i > 0)
        debug_putchar(buffer[--i]);
}

static void print_samples(
    const char *label,
    volatile uint32_t *samples,
    uint32_t length)
{
    print(label);
    print("\n");

    for (uint32_t i = 0; i < length; i++)
    {
        print("[");
        print_uint(i);
        print("] ");
        print_uint(samples[i]);
        print("\n");
    }
}

// ============================================================
// Simulation Exit
// ============================================================

static void simulation_exit(uint32_t code)
{
    REG32(SIM_EXIT) = code;

    while (1)
        __asm__ volatile ("nop");
}

// ============================================================
// Main Firmware
// ============================================================

int main(void)
{
    volatile uint32_t *sample_dest =
        (volatile uint32_t *)(uintptr_t)
        (RAM_BASE + FFT_INPUT_OFFSET);

    // --------------------------------------------------------
    // 1. Boot
    // --------------------------------------------------------

    print("\n========================================\n");
    print("       PICORV32 FFT ACCELERATOR TEST\n");
    print("========================================\n");

    print("[FIRMWARE] Booting RISC-V SoC...\n");

    // --------------------------------------------------------
    // 2. Initialize input samples in RAM
    // --------------------------------------------------------

    print("\n[INPUT] Initializing sample array...\n");

    for (uint32_t i = 0; i < FFT_LENGTH; i++)
        sample_dest[i] = i;

    for (uint32_t i = 0; i < FFT_LENGTH; i++)
    {
        if (sample_dest[i] != i)
        {
            print("[ERROR] RAM verification failed!\n");
            simulation_exit(2);
        }
    }

    print("[INPUT] RAM verification passed!\n");

    print_samples(
        "[INPUT] Input samples:",
        sample_dest,
        FFT_LENGTH
    );

    // --------------------------------------------------------
    // 3. Check initial FFT status BEFORE starting
    // --------------------------------------------------------

    volatile uint32_t *fft_ctrl =
        (volatile uint32_t *)(uintptr_t)
        (FFT_CTRL_BASE + FFT_REG_CTRL);

    volatile uint32_t *fft_status =
        (volatile uint32_t *)(uintptr_t)
        (FFT_CTRL_BASE + FFT_REG_STATUS);

    volatile uint32_t *fft_n =
        (volatile uint32_t *)(uintptr_t)
        (FFT_CTRL_BASE + FFT_REG_N);

    uint32_t initial_status = *fft_status;

    print("\n[DEBUG] Status before start = ");
    print_uint(initial_status);
    print("\n");

    if (initial_status & FFT_STATUS_DONE)
    {
        print("[ERROR] DONE is already set before FFT start!\n");
        print("[ERROR] Check FFT reset and status-register logic.\n");
        simulation_exit(4);
    }

    if (initial_status & FFT_STATUS_BUSY)
    {
        print("[ERROR] FFT is BUSY before FFT start!\n");
        simulation_exit(5);
    }

    // --------------------------------------------------------
    // 4. Configure FFT
    // --------------------------------------------------------

    print("\n[FFT] Configuring accelerator...\n");

    *fft_n = FFT_LENGTH;

    // --------------------------------------------------------
    // 5. Start FFT
    // --------------------------------------------------------

    print("[FFT] Starting accelerator...\n");

    *fft_ctrl = 1u;

    // Ensure MMIO writes are ordered before status polling.
    __asm__ volatile ("fence iorw, iorw" ::: "memory");

    print("[FFT] Waiting for computation...\n");

    // --------------------------------------------------------
    // 6. Wait for DONE
    // --------------------------------------------------------

    uint32_t timeout = FFT_TIMEOUT;
    uint32_t status = 0;

    while (timeout > 0)
    {
        status = *fft_status;

        if (status & FFT_STATUS_DONE)
            break;

        timeout--;
    }

    print("[DEBUG] Final FFT STATUS = ");
    print_uint(status);
    print("\n");

    if (!(status & FFT_STATUS_DONE))
    {
        print("[ERROR] FFT did not complete!\n");

        if (status & FFT_STATUS_BUSY)
            print("[DEBUG] FFT is still BUSY.\n");
        else
            print("[DEBUG] FFT is IDLE but DONE is not set.\n");

        simulation_exit(3);
    }

    print("[FFT] Computation completed!\n");

    // --------------------------------------------------------
    // 7. Output information
    // --------------------------------------------------------

    print("\n========================================\n");
    print("          FFT COMPUTED OUTPUT\n");
    print("========================================\n");

    print("[OUTPUT] FFT output is available on AXI-Stream.\n");
    print("[OUTPUT] Real and imaginary components are interleaved.\n");
    print("[OUTPUT] Cocotb testbench verifies the output stream.\n");

    // NOTE:
    // There is currently no DMA or hardware path that writes
    // FFT AXI-Stream output into RAM at address 0x2000.
    // Do not read that RAM location as FFT output.

    // --------------------------------------------------------
    // 8. Successful firmware completion
    // --------------------------------------------------------

    print("\n[FIRMWARE] Test sequence completed successfully!\n");
    print("========================================\n");

    simulation_exit(1);

    return 0;
}
