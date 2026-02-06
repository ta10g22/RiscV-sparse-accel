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
#define GPIO_IN  (*(volatile uint32_t *)(GPIO_BASE + 0x04)) // Switches

// ============================================================
// Cycle Counter (PicoRV32 CSR)
// ============================================================
static inline uint32_t read_cycles(void) {
    uint32_t cycles;
    asm volatile ("rdcycle %0" : "=r"(cycles));
    return cycles;
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

// Display two hex digits on HEX1:HEX0
void display_hex(uint8_t value) {
    uint8_t lo = seg7_table[value & 0xF];
    uint8_t hi = seg7_table[(value >> 4) & 0xF];
    GPIO_OUT = (hi << 8) | lo;
}

// Display speedup ratio (0-99)
void display_speedup(uint32_t speedup) {
    if (speedup > 99) speedup = 99;
    uint8_t tens = speedup / 10;
    uint8_t ones = speedup % 10;
    uint8_t lo = seg7_table[ones];
    uint8_t hi = seg7_table[tens];
    GPIO_OUT = (hi << 8) | lo | (0x3F << 16); // LEDs show pattern
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
    1, 2, 3, 4, 5, 6, 7, 8,   // Row 0
    2, 3, 4, 5, 6, 7, 8, 9,   // Row 1
    3, 4, 5, 6, 7, 8, 9, 10,  // Row 2
    4, 5, 6, 7, 8, 9, 10, 11  // Row 3
};

// Output matrices
uint32_t C_accel[TEST_M * TEST_N];
uint32_t C_cpu[TEST_M * TEST_N];

// ============================================================
// Software SpMM (CPU baseline)
// ============================================================
void spmm_cpu(uint32_t M, uint32_t N, uint32_t K,
              uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
              uint32_t *B, uint32_t *C) {
    // Clear output
    for (uint32_t i = 0; i < M * N; i++) {
        C[i] = 0;
    }
    
    // SpMM: C = A * B
    for (uint32_t row = 0; row < M; row++) {
        uint32_t row_start = rowptr[row];
        uint32_t row_end = rowptr[row + 1];
        
        for (uint32_t idx = row_start; idx < row_end; idx++) {
            uint32_t col = colidx[idx];
            uint32_t val = values[idx];
            
            // C[row, :] += val * B[col, :]
            for (uint32_t n = 0; n < N; n++) {
                C[row * N + n] += val * B[col * N + n];
            }
        }
    }
}

// ============================================================
// Compare arrays
// ============================================================
int array_compare(uint32_t *a, uint32_t *b, int len) {
    for (int i = 0; i < len; i++) {
        if (a[i] != b[i]) return 1;
    }
    return 0;
}

void array_clear(uint32_t *arr, int len) {
    for (int i = 0; i < len; i++) arr[i] = 0;
}

// ============================================================
// Main Entry Point - Benchmark
// ============================================================

int main(void)
{
    uint32_t start, end;
    uint32_t cpu_cycles, accel_cycles;
    uint32_t speedup;
    
    // Show "88" while running (all segments on)
    GPIO_OUT = 0x0000;
    
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
        0  // no ReLU
    );
    
    end = read_cycles();
    accel_cycles = end - start;
    
    // ========================================
    // Verify results match
    // ========================================
    if (array_compare(C_cpu, C_accel, TEST_M * TEST_N) != 0) {
        // ERROR: Results don't match!
        display_hex(0xEE);  // Show "EE" for error
        while(1);  // Halt
    }
    
    // ========================================
    // Calculate and display speedup
    // ========================================
    // Speedup = CPU_cycles / Accel_cycles
    if (accel_cycles > 0) {
        speedup = cpu_cycles / accel_cycles;
    } else {
        speedup = 99;  // Max displayable
    }
    
    // Display speedup on 7-segment (e.g., "05" = 5x faster)
    display_speedup(speedup);
    
    // Also set LEDs to show cycle count ranges:
    // LED[0] = accel < 100 cycles
    // LED[1] = accel < 500 cycles
    // LED[2] = accel < 1000 cycles
    // LED[3] = cpu > 1000 cycles
    // LED[4] = cpu > 5000 cycles
    // LED[5] = verification passed
    uint32_t led_pattern = 0x20;  // LED[5] = pass
    if (accel_cycles < 100)  led_pattern |= 0x01;
    if (accel_cycles < 500)  led_pattern |= 0x02;
    if (accel_cycles < 1000) led_pattern |= 0x04;
    if (cpu_cycles > 1000)   led_pattern |= 0x08;
    if (cpu_cycles > 5000)   led_pattern |= 0x10;
    
    GPIO_OUT = (GPIO_OUT & 0xFFFF) | (led_pattern << 16);
    
    // Infinite loop - display stays on
    while(1);
    
    return 0;
}
