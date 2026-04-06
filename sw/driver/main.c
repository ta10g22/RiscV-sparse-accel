/**
 * SpMM Accelerator Benchmark Program
 *
 * Compares CPU software implementation vs hardware accelerator.
 * Displays cycle counts and speedup on 7-segment displays.
 *
 * Designed for PicoRV32 + accelerator SoC on DE1-SoC.
 */

#include "spmm_accel.h"

// ============================================================
// GPIO for LED/7-Segment output
// ============================================================
#define GPIO_BASE 0x20000000
#define GPIO_OUT (*(volatile uint32_t *)(GPIO_BASE + 0x00)) // LEDs/7-seg
#define GPIO_IN (*(volatile uint32_t *)(GPIO_BASE + 0x04))  // Switches

// ============================================================
// UART MMIO (simpleuart in soc_top)
// ============================================================
#define UART_BASE 0x20000100
#define UART_DIV (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_DATA (*(volatile uint32_t *)(UART_BASE + 0x08))

// 50MHz / 115200 ~= 434
#define UART_DIV_115200 434

// ============================================================
// Cycle Counter (PicoRV32 CSR)
// ============================================================
static inline uint32_t read_cycles(void)
{
    uint32_t cycles;
    asm volatile("rdcycle %0" : "=r"(cycles));
    return cycles;
}

static inline void uart_init(void)
{
    UART_DIV = UART_DIV_115200;
}

static inline void uart_putc(char c)
{
    UART_DATA = (uint32_t)(uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
    {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_put_u32(uint32_t value)
{
    char buf[10];
    int i = 0;

    if (value == 0)
    {
        uart_putc('0');
        return;
    }

    while (value > 0 && i < 10)
    {
        buf[i++] = (char)('0' + (value % 10));
        value /= 10;
    }

    while (i > 0)
    {
        uart_putc(buf[--i]);
    }
}

// ============================================================
// 7-Segment Encoding (active low for DE1-SoC)
// ============================================================
// Segments: 0gfedcba
static const uint8_t seg7_table[16] = {
    0x40, // 0
    0x79, // 1
    0x24, // 2
    0x30, // 3
    0x19, // 4
    0x12, // 5
    0x02, // 6
    0x78, // 7
    0x00, // 8
    0x10, // 9
    0x08, // A
    0x03, // b
    0x46, // C
    0x21, // d
    0x06, // E
    0x0E  // F
};

// Display 6 hex digits on HEX5:HEX0
// Format: HEX5:HEX4 = CPU cycles (÷64), HEX3:HEX2 = Accel cycles, HEX1:HEX0 = Speedup
void display_results(uint32_t cpu_cycles, uint32_t accel_cycles, uint32_t speedup)
{
    // Divide CPU cycles by 64 to fit in 2 hex digits (0-255 represents 0-16320)
    uint32_t cpu_scaled = cpu_cycles >> 6; // ÷64
    if (cpu_scaled > 255)
        cpu_scaled = 255;

    // Accel cycles - cap at 255
    if (accel_cycles > 255)
        accel_cycles = 255;

    // Speedup - cap at 99
    if (speedup > 99)
        speedup = 99;
    uint8_t sp_tens = speedup / 10;
    uint8_t sp_ones = speedup % 10;

    // Pack into GPIO_OUT: bits [23:0] for 6 hex digits
    // HEX0 = [3:0], HEX1 = [7:4], HEX2 = [11:8], HEX3 = [15:12], HEX4 = [19:16], HEX5 = [23:20]
    uint32_t val = 0;
    val |= (sp_ones & 0xF);                   // HEX0 = speedup ones
    val |= (sp_tens & 0xF) << 4;              // HEX1 = speedup tens
    val |= (accel_cycles & 0xF) << 8;         // HEX2 = accel low nibble
    val |= ((accel_cycles >> 4) & 0xF) << 12; // HEX3 = accel high nibble
    val |= (cpu_scaled & 0xF) << 16;          // HEX4 = cpu low nibble
    val |= ((cpu_scaled >> 4) & 0xF) << 20;   // HEX5 = cpu high nibble

    GPIO_OUT = val;
}

// Display error code
void display_error(uint8_t code)
{
    // Show "EE" on HEX1:HEX0
    GPIO_OUT = (0xE << 4) | 0xE | (code << 8);
}

// ============================================================
// Test Data (larger for better benchmark)
// ============================================================

// Sparse matrix A (4x4 in CSR format):
// A = | 2  0  0  0 |
//     | 0  3  0  0 |
//     | 1  0  4  0 |
//     | 0  2  0  5 |
//
// CSR: rowptr=[0,1,2,4,6], colidx=[0,1,0,2,1,3], values=[2,3,1,4,2,5]

#define TEST_M 4
#define TEST_K 4
#define TEST_N 8
#define TEST_NNZ 6

uint32_t A_rowptr[] = {0, 1, 2, 4, 6};
uint32_t A_colidx[] = {0, 1, 0, 2, 1, 3};
uint32_t A_values[] = {2, 3, 1, 4, 2, 5};

// Dense matrix B (4x8 row-major)
uint32_t B_matrix[TEST_K * TEST_N] = {
    1, 2, 3, 4, 5, 6, 7, 8,  // Row 0
    2, 3, 4, 5, 6, 7, 8, 9,  // Row 1
    3, 4, 5, 6, 7, 8, 9, 10, // Row 2
    4, 5, 6, 7, 8, 9, 10, 11 // Row 3
};

// Output matrices
uint32_t C_accel[TEST_M * TEST_N];
uint32_t C_cpu[TEST_M * TEST_N];

// ============================================================
// Software SpMM (CPU baseline)
// ============================================================
void spmm_cpu(uint32_t M, uint32_t N, uint32_t K,
              uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
              uint32_t *B, uint32_t *C)
{
    // Clear output
    for (uint32_t i = 0; i < M * N; i++)
    {
        C[i] = 0;
    }

    // SpMM: C = A * B
    for (uint32_t row = 0; row < M; row++)
    {
        uint32_t row_start = rowptr[row];
        uint32_t row_end = rowptr[row + 1];

        for (uint32_t idx = row_start; idx < row_end; idx++)
        {
            uint32_t col = colidx[idx];
            uint32_t val = values[idx];

            // C[row, :] += val * B[col, :]
            for (uint32_t n = 0; n < N; n++)
            {
                C[row * N + n] += val * B[col * N + n];
            }
        }
    }
}

// ============================================================
// Compare arrays
// ============================================================
int array_compare(uint32_t *a, uint32_t *b, int len)
{
    for (int i = 0; i < len; i++)
    {
        if (a[i] != b[i])
            return 1;
    }
    return 0;
}

void array_clear(uint32_t *arr, int len)
{
    for (int i = 0; i < len; i++)
        arr[i] = 0;
}

// ============================================================
// Main Entry Point - Benchmark
// ============================================================

int main(void)
{
    uint32_t start, end;
    uint32_t cpu_cycles, accel_cycles;
    uint32_t speedup;

    uart_init();
    uart_puts("\nSpMM benchmark start\n");

    // Show "888888" while running (all segments on)
    GPIO_OUT = 0x888888;

    // ========================================
    // Benchmark 1: CPU Software SpMM
    // ========================================
    start = read_cycles();

    spmm_cpu(TEST_M, TEST_N, TEST_K,
             A_rowptr, A_colidx, A_values,
             B_matrix, C_cpu);

    end = read_cycles();
    cpu_cycles = end - start;

    // ========================================
    // Benchmark 2: Hardware Accelerator SpMM
    // ========================================
    array_clear(C_accel, TEST_M * TEST_N);

    start = read_cycles();

    accel_run_spmm(
        TEST_M, TEST_N, TEST_K, TEST_NNZ,
        A_rowptr, A_colidx, A_values,
        B_matrix, C_accel,
        0 // no ReLU
    );

    end = read_cycles();
    accel_cycles = end - start;

    // ========================================
    // Verify results match
    // ========================================
    if (array_compare(C_cpu, C_accel, TEST_M * TEST_N) != 0)
    {
        // ERROR: Results don't match!
        uart_puts("ERROR: CPU and accelerator results mismatch\n");
        display_error(0x01);
        while (1)
            ; // Halt
    }

    // ========================================
    // Calculate and display results
    // ========================================
    // Speedup = CPU_cycles / Accel_cycles
    if (accel_cycles > 0)
    {
        speedup = cpu_cycles / accel_cycles;
    }
    else
    {
        speedup = 99; // Max displayable
    }

    // Display on all 6 seven-segment displays:
    // HEX5:HEX4 = CPU cycles (÷64, in hex)
    // HEX3:HEX2 = Accel cycles (in hex)
    // HEX1:HEX0 = Speedup (in decimal, e.g. "05" = 5x)
    display_results(cpu_cycles, accel_cycles, speedup);

    uart_puts("CPU cycles: ");
    uart_put_u32(cpu_cycles);
    uart_puts("\n");
    uart_puts("Accel cycles: ");
    uart_put_u32(accel_cycles);
    uart_puts("\n");
    uart_puts("Speedup: ");
    uart_put_u32(speedup);
    uart_puts("x\n");

    // Infinite loop - display stays on
    while (1)
        ;

    return 0;
}
