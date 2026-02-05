/**
 * SpMM Accelerator Driver Header
 * 
 * Register interface for the sparse matrix-matrix multiply accelerator.
 * Designed for PicoRV32 bare-metal firmware.
 */

#ifndef SPMM_ACCEL_H
#define SPMM_ACCEL_H

#include <stdint.h>

// ============================================================
// MMIO Base Address (adjust to match your SoC memory map)
// ============================================================
#ifndef ACCEL_BASE
#define ACCEL_BASE  0x10000000
#endif

// ============================================================
// Register Offsets (must match accel_top.sv)
// ============================================================
#define ACCEL_CTRL       0x00   // Control register (W)
#define ACCEL_STATUS     0x04   // Status register (R)
#define ACCEL_M          0x08   // Number of rows in A and C
#define ACCEL_N          0x0C   // Number of cols in B and C (must be >= TN=8)
#define ACCEL_K          0x10   // Number of cols in A / rows in B
#define ACCEL_A_VAL_BASE 0x14   // Base address of A values array
#define ACCEL_A_ROW_BASE 0x18   // Base address of A row pointers (CSR)
#define ACCEL_A_COL_BASE 0x1C   // Base address of A column indices (CSR)
#define ACCEL_B_BASE     0x20   // Base address of B matrix (row-major)
#define ACCEL_C_BASE     0x24   // Base address of C output matrix (row-major)
#define ACCEL_NNZ        0x28   // Number of non-zeros in A

// ============================================================
// CTRL Register Bits
// ============================================================
#define CTRL_START   (1 << 0)   // Start computation (auto-clears)
#define CTRL_CLEAR   (1 << 1)   // Clear done status (auto-clears)
#define CTRL_IRQ_EN  (1 << 2)   // Enable interrupt on completion
#define CTRL_RELU    (1 << 3)   // Enable ReLU activation on output

// ============================================================
// STATUS Register Bits
// ============================================================
#define STATUS_BUSY  (1 << 0)   // Accelerator is running
#define STATUS_DONE  (1 << 1)   // Computation complete

// ============================================================
// MMIO Access Macros
// ============================================================
#define ACCEL_REG(offset)  (*(volatile uint32_t *)(ACCEL_BASE + (offset)))

// ============================================================
// Function Prototypes
// ============================================================

/**
 * Initialize the accelerator (clears any pending done status)
 */
void accel_init(void);

/**
 * Configure the accelerator with matrix dimensions and memory pointers
 * 
 * @param M      Number of rows in sparse matrix A (and output C)
 * @param N      Number of columns in dense matrix B (and output C), must be >= 8
 * @param K      Number of columns in A / rows in B
 * @param nnz    Number of non-zero elements in A
 * @param rowptr CSR row pointer array (M+1 elements)
 * @param colidx CSR column index array (nnz elements)
 * @param values CSR values array (nnz elements)
 * @param B      Dense matrix B, row-major (K x N)
 * @param C      Output matrix C, row-major (M x N)
 */
void accel_configure(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                     uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                     uint32_t *B, uint32_t *C);

/**
 * Start the SpMM computation
 * 
 * @param use_relu  If non-zero, apply ReLU activation to output
 */
void accel_start(int use_relu);

/**
 * Block until computation is complete (polling)
 */
void accel_wait_done(void);

/**
 * Clear the done status flag
 */
void accel_clear_done(void);

/**
 * Check if accelerator is currently busy
 * @return 1 if busy, 0 if idle
 */
int accel_is_busy(void);

/**
 * Check if computation is done
 * @return 1 if done, 0 if not
 */
int accel_is_done(void);

/**
 * Convenience function: configure, run, and wait for completion
 */
void accel_run_spmm(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                    uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                    uint32_t *B, uint32_t *C, int use_relu);

#endif /* SPMM_ACCEL_H */
