/**
 * SpMM Accelerator Test Program
 *
 * Simple test that runs a 2x2 sparse matrix times 2x8 dense matrix
 * and verifies the result.
 *
 * Designed for simulation on PicoRV32 + accelerator SoC.
 */

#include "spmm_accel.h"

// ============================================================
// GPIO for LED/7-Segment output
// ============================================================
#define GPIO_BASE   0x20000000
#define GPIO_OUT    (*(volatile uint32_t *)(GPIO_BASE + 0x00))  // LEDs/7-seg
#define GPIO_IN     (*(volatile uint32_t *)(GPIO_BASE + 0x04))  // Switches

// ============================================================
// Test Data
// ============================================================

// Sparse matrix A (2x2 in CSR format):
// A = | 2  0 |
//     | 0  3 |
//
// CSR representation:
//   rowptr = [0, 1, 2]  (row 0 has 1 NZ starting at index 0, row 1 has 1 NZ starting at index 1)
//   colidx = [0, 1]     (NZ 0 is in col 0, NZ 1 is in col 1)
//   values = [2, 3]     (NZ 0 = 2, NZ 1 = 3)

uint32_t A_rowptr[] = {0, 1, 2};
uint32_t A_colidx[] = {0, 1};
uint32_t A_values[] = {2, 3};

// Dense matrix B (2x8 row-major):
// B = | 4  5  0  0  0  0  0  0 |
//     | 6  7  0  0  0  0  0  0 |

uint32_t B_matrix[2 * 8] = {
    4, 5, 0, 0, 0, 0, 0, 0, // Row 0
    6, 7, 0, 0, 0, 0, 0, 0  // Row 1
};

// Output matrix C (2x8)
uint32_t C_matrix[2 * 8];

// Expected result:
// C = A * B
// C[0,:] = A[0,0] * B[0,:] = 2 * [4, 5, 0, 0, 0, 0, 0, 0] = [8, 10, 0, 0, 0, 0, 0, 0]
// C[1,:] = A[1,1] * B[1,:] = 3 * [6, 7, 0, 0, 0, 0, 0, 0] = [18, 21, 0, 0, 0, 0, 0, 0]

uint32_t C_expected[2 * 8] = {
    8, 10, 0, 0, 0, 0, 0, 0,
    18, 21, 0, 0, 0, 0, 0, 0};

// ============================================================
// Test Functions
// ============================================================

/**
 * Compare two arrays
 * @return 0 if equal, 1 if different
 */
int array_compare(uint32_t *a, uint32_t *b, int len)
{
    for (int i = 0; i < len; i++)
    {
        if (a[i] != b[i])
        {
            return 1; // mismatch
        }
    }
    return 0; // match
}

/**
 * Clear an array to zero
 */
void array_clear(uint32_t *arr, int len)
{
    for (int i = 0; i < len; i++)
    {
        arr[i] = 0;
    }
}

// ============================================================
// Main Entry Point
// ============================================================

int main(void)
{
    int result = 0;

    // Clear output matrix
    array_clear(C_matrix, 2 * 8);

    // Run SpMM: C = A * B (no ReLU)
    accel_run_spmm(
        2, // M = 2 rows
        8, // N = 8 cols (must be >= TN=8)
        2, // K = 2
        2, // nnz = 2 non-zeros
        A_rowptr,
        A_colidx,
        A_values,
        B_matrix,
        C_matrix,
        0 // use_relu = 0
    );

    // Verify result
    if (array_compare(C_matrix, C_expected, 2 * 8) != 0)
    {
        result = 1; // FAIL
    }

    // ========================================
    // Test 2: ReLU activation with negative
    // ========================================

    // Modify A to have a negative value
    // A = | -2  0 |
    //     |  0  3 |
    A_values[0] = (uint32_t)(-2); // -2 in two's complement

    // Expected with ReLU:
    // C[0,:] = ReLU(-2 * B[0,:]) = ReLU([-8, -10, ...]) = [0, 0, 0, 0, 0, 0, 0, 0]
    // C[1,:] = ReLU(3 * B[1,:]) = [18, 21, 0, 0, 0, 0, 0, 0]
    uint32_t C_expected_relu[2 * 8] = {
        0, 0, 0, 0, 0, 0, 0, 0,
        18, 21, 0, 0, 0, 0, 0, 0};

    // Clear and run with ReLU
    array_clear(C_matrix, 2 * 8);

    accel_run_spmm(
        2, 8, 2, 2,
        A_rowptr, A_colidx, A_values,
        B_matrix, C_matrix,
        1 // use_relu = 1
    );

    // Verify ReLU result
    if (array_compare(C_matrix, C_expected_relu, 2 * 8) != 0)
    {
        result = 2; // FAIL (ReLU test)
    }

    // ========================================
    // Output result to LEDs and 7-segment
    // ========================================
    // GPIO_OUT[5:0] -> LED[5:0]
    // GPIO_OUT[7:0] -> 7-seg display (HEX1:HEX0)
    // 
    // 0x00 = PASS (displays "00", LEDs off)
    // 0x01 = basic test fail
    // 0x02 = ReLU test fail
    // 0xAA = running pattern (before tests)
    
    if (result == 0) {
        GPIO_OUT = 0x00;  // All LEDs off, 7-seg shows "00" = PASS
    } else {
        GPIO_OUT = (result << 4) | 0x0F;  // Show error code, light some LEDs
    }

    // ========================================
    // Return result
    // ========================================
    // 0 = PASS, 1 = basic test fail, 2 = ReLU test fail

    return result;
}
