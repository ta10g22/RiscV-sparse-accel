/**
 * SpMM Accelerator Driver Implementation
 *
 * Bare-metal driver for the sparse matrix-matrix multiply accelerator.
 */

#include "spmm_accel.h"

void accel_init(void)
{
    // Clear any pending done status from previous run
    ACCEL_REG(ACCEL_CTRL) = CTRL_CLEAR;
}

void accel_configure(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                     uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                     uint32_t *B, uint32_t *C)
{
    // Set matrix dimensions
    ACCEL_REG(ACCEL_M) = M;
    ACCEL_REG(ACCEL_N) = N;
    ACCEL_REG(ACCEL_K) = K;
    ACCEL_REG(ACCEL_NNZ) = nnz;

    // Set CSR pointers for sparse matrix A
    ACCEL_REG(ACCEL_A_ROW_BASE) = (uint32_t)rowptr;
    ACCEL_REG(ACCEL_A_COL_BASE) = (uint32_t)colidx;
    ACCEL_REG(ACCEL_A_VAL_BASE) = (uint32_t)values;

    // Set dense matrix pointers
    ACCEL_REG(ACCEL_B_BASE) = (uint32_t)B;
    ACCEL_REG(ACCEL_C_BASE) = (uint32_t)C;
}

void accel_start(int use_relu)
{
    uint32_t ctrl = CTRL_START;
    if (use_relu)
    {
        ctrl |= CTRL_RELU;
    }
    ACCEL_REG(ACCEL_CTRL) = ctrl;
}

void accel_wait_done(void)
{
    // Spin-wait for completion
    while (!(ACCEL_REG(ACCEL_STATUS) & STATUS_DONE))
    {
        // Could add a yield or WFI here if using interrupts
    }
}

void accel_clear_done(void)
{
    ACCEL_REG(ACCEL_CTRL) = CTRL_CLEAR;
}

int accel_is_busy(void)
{
    return (ACCEL_REG(ACCEL_STATUS) & STATUS_BUSY) != 0;
}

int accel_is_done(void)
{
    return (ACCEL_REG(ACCEL_STATUS) & STATUS_DONE) != 0;
}

void accel_run_spmm(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                    uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                    uint32_t *B, uint32_t *C, int use_relu)
{
    accel_init();
    accel_configure(M, N, K, nnz, rowptr, colidx, values, B, C);
    accel_start(use_relu);
    accel_wait_done();
    accel_clear_done();
}
