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

void uart_put_speedup_x100(uint32_t speedup_x100)
{
    uint32_t whole = speedup_x100 / 100;
    uint32_t frac = speedup_x100 % 100;

    uart_put_u32(whole);
    uart_putc('.');
    uart_putc((char)('0' + (frac / 10)));
    uart_putc((char)('0' + (frac % 10)));
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
// Runtime Benchmark Suite (generated test matrices)
// ============================================================
#define MAX_M 64
#define MAX_K 64
#define MAX_N 32
#define MAX_A_NNZ ((MAX_M * MAX_K) / 4) // Supports up to 75% sparsity at 64x64.
#define PACKED_WORDS(count) (((count) + 3u) >> 2)

typedef enum
{
    PATTERN_UNIFORM = 0,
    PATTERN_ROW_SKEWED,
    PATTERN_CLUSTERED
} pattern_t;

typedef struct
{
    const char *id;
    uint32_t M;
    uint32_t K;
    uint32_t N;
    uint32_t sparsity_pct; // percentage of zeros in A
    pattern_t pattern;
    uint32_t seed;
} benchmark_case_t;

static const benchmark_case_t benchmark_cases[] = {
    {"T1", 8, 8, 8, 75, PATTERN_UNIFORM, 0x1001},
    {"T2", 16, 16, 8, 75, PATTERN_UNIFORM, 0x1002},
    {"T3", 32, 32, 8, 75, PATTERN_UNIFORM, 0x1003},
    {"T4", 64, 64, 8, 75, PATTERN_UNIFORM, 0x1004},
    {"T5", 64, 64, 16, 75, PATTERN_UNIFORM, 0x1005},
    {"T6", 64, 64, 32, 75, PATTERN_UNIFORM, 0x1006},
    {"T7", 32, 32, 32, 50, PATTERN_UNIFORM, 0x1007},
    {"T8", 32, 32, 32, 75, PATTERN_UNIFORM, 0x1008},
    {"T9", 32, 32, 32, 90, PATTERN_UNIFORM, 0x1009},
    {"T10", 32, 32, 32, 75, PATTERN_ROW_SKEWED, 0x100A},
    {"T11", 32, 32, 32, 75, PATTERN_CLUSTERED, 0x100B},
    {"T12", 64, 64, 32, 90, PATTERN_UNIFORM, 0x100C},
};

#define NUM_TESTS ((uint32_t)(sizeof(benchmark_cases) / sizeof(benchmark_cases[0])))

// Runtime-generated matrix storage.
uint32_t A_rowptr[MAX_M + 1];
uint32_t A_colidx[MAX_A_NNZ];
int32_t A_values[MAX_A_NNZ];
int32_t B_matrix[MAX_K * MAX_N];
int32_t C_accel[MAX_M * MAX_N];
int32_t C_cpu[MAX_M * MAX_N];
int32_t C_cpu_q[MAX_M * MAX_N];
int8_t A_values_q8[MAX_A_NNZ];
int8_t B_matrix_q8[MAX_K * MAX_N];
uint32_t A_values_q8_packed[PACKED_WORDS(MAX_A_NNZ)];
uint32_t B_matrix_q8_packed[PACKED_WORDS(MAX_K * MAX_N)];

static uint32_t rng_state = 1;

static inline void rng_seed(uint32_t seed)
{
    rng_state = seed ? seed : 1u;
}

static inline uint32_t rng_next(void)
{
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state;
}

static inline uint32_t rng_range(uint32_t limit)
{
    return limit ? (rng_next() % limit) : 0u;
}

static inline uint32_t i32_abs_u32(int32_t v)
{
    return (v < 0) ? (uint32_t)(-v) : (uint32_t)v;
}

void min_max_i32(const int32_t *arr, uint32_t len, int32_t *min_v, int32_t *max_v)
{
    int32_t mn = 0;
    int32_t mx = 0;
    if (len > 0)
    {
        mn = arr[0];
        mx = arr[0];
        for (uint32_t i = 1; i < len; i++)
        {
            if (arr[i] < mn)
                mn = arr[i];
            if (arr[i] > mx)
                mx = arr[i];
        }
    }
    *min_v = mn;
    *max_v = mx;
}

int8_t quantize_i32_to_i8(int32_t value, uint32_t max_abs)
{
    int32_t q;
    uint32_t abs_v;
    if (max_abs == 0u)
        return 0;

    abs_v = i32_abs_u32(value);
    q = (int32_t)((abs_v * 127u + (max_abs / 2u)) / max_abs);
    if (value < 0)
        q = -q;

    if (q > 127)
        q = 127;
    if (q < -128)
        q = -128;
    return (int8_t)q;
}

void quantize_array_i32_to_i8(const int32_t *src, uint32_t len, uint32_t max_abs, int8_t *dst)
{
    for (uint32_t i = 0; i < len; i++)
        dst[i] = quantize_i32_to_i8(src[i], max_abs);
}

void pack_i8_to_u32(const int8_t *src, uint32_t len, uint32_t *dst)
{
    uint32_t out_idx = 0u;
    for (uint32_t i = 0; i < len; i += 4u)
    {
        uint32_t word = (uint8_t)src[i];
        if (i + 1u < len)
            word |= ((uint32_t)(uint8_t)src[i + 1u]) << 8;
        if (i + 2u < len)
            word |= ((uint32_t)(uint8_t)src[i + 2u]) << 16;
        if (i + 3u < len)
            word |= ((uint32_t)(uint8_t)src[i + 3u]) << 24;
        dst[out_idx++] = word;
    }
}

const char *pattern_name(pattern_t pattern)
{
    switch (pattern)
    {
    case PATTERN_UNIFORM:
        return "uniform";
    case PATTERN_ROW_SKEWED:
        return "row_skewed";
    case PATTERN_CLUSTERED:
        return "clustered";
    default:
        return "unknown";
    }
}

uint32_t target_nnz_from_sparsity(uint32_t M, uint32_t K, uint32_t sparsity_pct)
{
    uint32_t total = M * K;
    uint32_t dense_pct;

    if (sparsity_pct > 100u)
        sparsity_pct = 100u;

    dense_pct = 100u - sparsity_pct;
    return (total * dense_pct + 50u) / 100u;
}

uint32_t choose_clustered_column(uint32_t K)
{
    uint32_t block_w = K / 4u;
    uint32_t max_start;
    uint32_t starts[3];
    uint32_t c;

    if (block_w < 2u)
        block_w = (K >= 2u) ? 2u : 1u;
    if (block_w > K)
        block_w = K;

    max_start = K - block_w;
    starts[0] = 0u;
    starts[1] = K / 3u;
    starts[2] = (2u * K) / 3u;

    if (starts[1] > max_start)
        starts[1] = max_start;
    if (starts[2] > max_start)
        starts[2] = max_start;

    if (rng_range(100u) < 80u)
    {
        c = rng_range(3u);
        return starts[c] + rng_range(block_w);
    }
    return rng_range(K);
}

uint32_t assign_row_nnz(const benchmark_case_t *tc, uint32_t target_nnz, uint16_t *row_nnz)
{
    uint32_t i;
    uint32_t added_total = 0;

    for (i = 0; i < tc->M; i++)
        row_nnz[i] = 0;

    for (i = 0; i < target_nnz; i++)
    {
        uint32_t row;
        uint32_t probe;
        uint32_t added = 0;

        if (tc->pattern == PATTERN_UNIFORM)
        {
            row = i % tc->M;
        }
        else if (tc->pattern == PATTERN_ROW_SKEWED)
        {
            uint32_t hot_rows = tc->M / 4u;
            if (hot_rows == 0u)
                hot_rows = 1u;

            if (rng_range(100u) < 70u)
                row = rng_range(hot_rows);
            else
                row = rng_range(tc->M);
        }
        else
        {
            uint32_t block_h = tc->M / 4u;
            uint32_t starts[3];
            uint32_t c;

            if (block_h == 0u)
                block_h = 1u;

            starts[0] = 0u;
            starts[1] = tc->M / 3u;
            starts[2] = (2u * tc->M) / 3u;

            if (rng_range(100u) < 85u)
            {
                c = rng_range(3u);
                row = starts[c] + rng_range(block_h);
                if (row >= tc->M)
                    row = tc->M - 1u;
            }
            else
            {
                row = rng_range(tc->M);
            }
        }

        if (row_nnz[row] < tc->K)
        {
            row_nnz[row]++;
            added = 1;
        }
        else
        {
            for (probe = 0; probe < tc->M; probe++)
            {
                uint32_t rr = (row + probe + 1u) % tc->M;
                if (row_nnz[rr] < tc->K)
                {
                    row_nnz[rr]++;
                    added = 1;
                    break;
                }
            }
        }

        if (!added)
            break;
        added_total++;
    }

    return added_total;
}

uint32_t generate_sparse_A_csr(const benchmark_case_t *tc, uint32_t target_nnz)
{
    uint16_t row_nnz[MAX_M];
    uint8_t used_cols[MAX_K];
    uint32_t row_cols[MAX_K];
    uint32_t pos = 0;
    uint32_t r;
    uint32_t i;
    uint32_t actual_nnz;

    actual_nnz = assign_row_nnz(tc, target_nnz, row_nnz);
    (void)actual_nnz;

    A_rowptr[0] = 0;

    for (r = 0; r < tc->M; r++)
    {
        uint32_t cnt = row_nnz[r];
        uint32_t filled = 0;

        for (i = 0; i < tc->K; i++)
            used_cols[i] = 0u;

        for (i = 0; i < cnt; i++)
        {
            uint32_t col;
            uint32_t tries = 0;

            if (tc->pattern == PATTERN_CLUSTERED)
                col = choose_clustered_column(tc->K);
            else
                col = rng_range(tc->K);

            while (used_cols[col] && tries < tc->K)
            {
                col = (col + 1u) % tc->K;
                tries++;
            }

            if (used_cols[col])
                break;

            used_cols[col] = 1u;
            row_cols[filled++] = col;
        }

        // Insertion sort for stable, deterministic CSR colidx ordering.
        for (i = 1; i < filled; i++)
        {
            uint32_t key = row_cols[i];
            uint32_t j = i;
            while (j > 0 && row_cols[j - 1] > key)
            {
                row_cols[j] = row_cols[j - 1];
                j--;
            }
            row_cols[j] = key;
        }

        for (i = 0; i < filled; i++)
        {
            if (pos >= MAX_A_NNZ)
                break;

            A_colidx[pos] = row_cols[i];
            A_values[pos] = (int32_t)rng_range(2047u) - 1023;
            if (A_values[pos] == 0)
                A_values[pos] = 1;
            pos++;
        }

        A_rowptr[r + 1] = pos;
    }

    return pos;
}

void generate_dense_B(uint32_t K, uint32_t N)
{
    uint32_t i;
    uint32_t total = K * N;

    for (i = 0; i < total; i++)
    {
        B_matrix[i] = (int32_t)rng_range(2047u) - 1023;
        if (B_matrix[i] == 0)
            B_matrix[i] = -1;
    }
}

uint32_t generate_case_data(const benchmark_case_t *tc)
{
    uint32_t target_nnz = target_nnz_from_sparsity(tc->M, tc->K, tc->sparsity_pct);

    if (target_nnz > MAX_A_NNZ)
        target_nnz = MAX_A_NNZ;

    rng_seed(tc->seed);
    generate_dense_B(tc->K, tc->N);
    return generate_sparse_A_csr(tc, target_nnz);
}

void compute_speedups(uint32_t cpu_cycles, uint32_t accel_cycles, uint32_t *speedup_x100, uint32_t *speedup_led)
{
    if (accel_cycles > 0)
    {
        uint32_t num = cpu_cycles;
        uint32_t den = accel_cycles;

        // Keep arithmetic 32-bit so bare-metal link does not require __udivdi3.
        while (num > (UINT32_MAX / 100u) && den > 1u)
        {
            num >>= 1;
            den >>= 1;
        }

        *speedup_x100 = (num * 100u + (den / 2u)) / den;
        *speedup_led = (*speedup_x100 + 50u) / 100u;
        if (*speedup_led > 99u)
            *speedup_led = 99u;
    }
    else
    {
        *speedup_x100 = 9999u; // 99.99x sentinel
        *speedup_led = 99u;
    }
}

void uart_print_result_row(const benchmark_case_t *tc, uint32_t nnz, uint32_t cpu_cycles,
                           uint32_t accel_cycles, uint32_t speedup_x100, int pass)
{
    uart_puts(tc->id);
    uart_putc(',');
    uart_put_u32(tc->M);
    uart_putc(',');
    uart_put_u32(tc->K);
    uart_putc(',');
    uart_put_u32(tc->N);
    uart_putc(',');
    uart_put_u32(tc->sparsity_pct);
    uart_putc(',');
    uart_puts(pattern_name(tc->pattern));
    uart_putc(',');
    uart_put_u32(nnz);
    uart_putc(',');
    uart_put_u32(cpu_cycles);
    uart_putc(',');
    uart_put_u32(accel_cycles);
    uart_putc(',');
    uart_put_speedup_x100(speedup_x100);
    uart_putc(',');
    uart_puts(pass ? "PASS" : "FAIL");
    uart_puts("\n");
}

// ============================================================
// Software SpMM (CPU baseline)
// ============================================================
void spmm_cpu(uint32_t M, uint32_t N, uint32_t K,
              uint32_t *rowptr, uint32_t *colidx, int32_t *values,
              int32_t *B, int32_t *C)
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
            int32_t val = values[idx];

            // C[row, :] += val * B[col, :]
            for (uint32_t n = 0; n < N; n++)
            {
                C[row * N + n] += val * B[col * N + n];
            }
        }
    }
}

void spmm_cpu_q8(uint32_t M, uint32_t N,
                 uint32_t *rowptr, uint32_t *colidx, int8_t *values_q8,
                 int8_t *B_q8, int32_t *C)
{
    for (uint32_t i = 0; i < M * N; i++)
    {
        C[i] = 0;
    }

    for (uint32_t row = 0; row < M; row++)
    {
        uint32_t row_start = rowptr[row];
        uint32_t row_end = rowptr[row + 1];

        for (uint32_t idx = row_start; idx < row_end; idx++)
        {
            uint32_t col = colidx[idx];
            int32_t val = (int32_t)values_q8[idx];

            for (uint32_t n = 0; n < N; n++)
            {
                C[row * N + n] += val * (int32_t)B_q8[col * N + n];
            }
        }
    }
}

// ============================================================
// Compare arrays
// ============================================================
int array_compare(int32_t *a, int32_t *b, int len)
{
    for (int i = 0; i < len; i++)
    {
        if (a[i] != b[i])
            return 1;
    }
    return 0;
}

void array_clear(int32_t *arr, int len)
{
    for (int i = 0; i < len; i++)
        arr[i] = 0;
}

// ============================================================
// Main Entry Point - Benchmark
// ============================================================

int main(void)
{
    uint32_t start;
    uint32_t end;
    uint32_t cpu_cycles, accel_cycles;
    uint32_t speedup_led;
    uint32_t speedup_x100;
    uint32_t t;
    uint32_t pass_count = 0;

    uart_init();
    uart_puts("\nSpMM benchmark sweep start\n");
    uart_puts("Mode: runtime symmetric INT8 quantization (A_values, B), INT32 accumulate\n");
    uart_puts("Pass checks quantized CPU reference vs INT8 accelerator output\n");
    uart_puts("ID,M,K,N,Sparsity,Pattern,NNZ,CPU,ACCEL,Speedup,Pass\n");

    for (t = 0; t < NUM_TESTS; t++)
    {
        const benchmark_case_t *tc = &benchmark_cases[t];
        uint32_t nnz;
        uint32_t max_abs_a;
        uint32_t max_abs_b;
        int32_t min_a, max_a;
        int32_t min_b, max_b;
        int pass;

        // Show "888888" while each test is running.
        GPIO_OUT = 0x888888;

        nnz = generate_case_data(tc);
        array_clear(C_cpu, (int)(tc->M * tc->N));
        array_clear(C_cpu_q, (int)(tc->M * tc->N));
        array_clear(C_accel, (int)(tc->M * tc->N));

        min_max_i32(A_values, nnz, &min_a, &max_a);
        min_max_i32(B_matrix, tc->K * tc->N, &min_b, &max_b);
        max_abs_a = i32_abs_u32(min_a);
        if (i32_abs_u32(max_a) > max_abs_a)
            max_abs_a = i32_abs_u32(max_a);
        max_abs_b = i32_abs_u32(min_b);
        if (i32_abs_u32(max_b) > max_abs_b)
            max_abs_b = i32_abs_u32(max_b);
        quantize_array_i32_to_i8(A_values, nnz, max_abs_a, A_values_q8);
        quantize_array_i32_to_i8(B_matrix, tc->K * tc->N, max_abs_b, B_matrix_q8);

        pack_i8_to_u32(A_values_q8, nnz, A_values_q8_packed);
        pack_i8_to_u32(B_matrix_q8, tc->K * tc->N, B_matrix_q8_packed);

        // Full-precision software reference (for quality analysis, untimed).
        spmm_cpu(tc->M, tc->N, tc->K, A_rowptr, A_colidx, A_values, B_matrix, C_cpu);

        // CPU baseline in quantized arithmetic domain (fair against INT8 accelerator).
        start = read_cycles();
        spmm_cpu_q8(tc->M, tc->N, A_rowptr, A_colidx, A_values_q8, B_matrix_q8, C_cpu_q);
        end = read_cycles();
        cpu_cycles = end - start;

        // Accelerator
        start = read_cycles();
        accel_run_spmm_int8(tc->M, tc->N, tc->K, nnz,
                            A_rowptr, A_colidx, A_values_q8_packed, B_matrix_q8_packed, C_accel, 0);
        end = read_cycles();
        accel_cycles = end - start;

        // Compare and report
        pass = (array_compare(C_cpu_q, C_accel, (int)(tc->M * tc->N)) == 0);
        if (pass)
            pass_count++;

        compute_speedups(cpu_cycles, accel_cycles, &speedup_x100, &speedup_led);

        // Keep board display behavior simple: rounded integer speedup.
        display_results(cpu_cycles, accel_cycles, speedup_led);
        uart_print_result_row(tc, nnz, cpu_cycles, accel_cycles, speedup_x100, pass);
    }

    uart_puts("SUMMARY,pass=");
    uart_put_u32(pass_count);
    uart_puts(",total=");
    uart_put_u32(NUM_TESTS);
    uart_puts("\n");

    if (pass_count != NUM_TESTS)
        display_error(0x01);

    // Infinite loop - display stays on
    while (1)
        ;

    return 0;
}
