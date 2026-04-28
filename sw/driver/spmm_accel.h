

#ifndef SPMM_ACCEL_H
#define SPMM_ACCEL_H

#include <stdint.h>


#ifndef ACCEL_BASE
#define ACCEL_BASE 0x10000000
#endif


#define ACCEL_CTRL 0x00
#define ACCEL_STATUS 0x04
#define ACCEL_M 0x08
#define ACCEL_N 0x0C
#define ACCEL_K 0x10
#define ACCEL_A_VAL_BASE 0x14
#define ACCEL_A_ROW_BASE 0x18
#define ACCEL_A_COL_BASE 0x1C
#define ACCEL_B_BASE 0x20
#define ACCEL_C_BASE 0x24
#define ACCEL_NNZ 0x28


#define CTRL_START (1 << 0)
#define CTRL_CLEAR (1 << 1)
#define CTRL_IRQ_EN (1 << 2)
#define CTRL_RELU (1 << 3)
#define CTRL_INT8 (1 << 4)


#define STATUS_BUSY (1 << 0)
#define STATUS_DONE (1 << 1)


#define ACCEL_REG(offset) (*(volatile uint32_t *)(ACCEL_BASE + (offset)))


void accel_init(void);


void accel_configure(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                     uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                     uint32_t *B, int32_t *C);


void accel_start(int use_relu);


void accel_start_mode(int use_relu, int use_int8);


void accel_wait_done(void);


void accel_clear_done(void);


int accel_is_busy(void);


int accel_is_done(void);


void accel_run_spmm(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                    uint32_t *rowptr, uint32_t *colidx, uint32_t *values,
                    uint32_t *B, int32_t *C, int use_relu);


void accel_run_spmm_int8(uint32_t M, uint32_t N, uint32_t K, uint32_t nnz,
                         uint32_t *rowptr, uint32_t *colidx, uint32_t *values_packed,
                         uint32_t *B_packed, int32_t *C, int use_relu);

#endif
