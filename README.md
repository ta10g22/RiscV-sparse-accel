# RISC-V Sparse Matrix Accelerator

This repository contains a PicoRV32-based SoC with a custom SystemVerilog sparse matrix-matrix multiplication (SpMM) accelerator for the Terasic DE1-SoC FPGA board.

The implemented kernel is:

- CSR-format SpMM: `C = A x B`
- Optional ReLU on output writeback
- Runtime symmetric `INT8` quantization mode for CSR values and dense `B` with `INT32` accumulation

## Final Project Status

- SoC integration works on DE1-SoC
- PicoRV32 firmware configures and launches the accelerator over MMIO
- Shared on-chip RAM is used for firmware, matrices, and outputs
- UART benchmark output works in hardware (`simpleuart`)
- Parallel DSP-based MAC optimization implemented
- Runtime `INT8` packed path implemented and validated
- All 12 benchmark cases pass across recorded sweeps

## Architecture

The system consists of:

- `PicoRV32` RV32IM soft-core CPU
- Accelerator RTL: `accel_top`, `accel_ctrl`, `accel_datapath`
- 64 KB on-chip RAM
- MMIO-mapped accelerator control registers
- GPIO window for board outputs
- `simpleuart` MMIO window for UART logging

High-level accelerator flow:

1. Firmware writes matrix dimensions and buffer base addresses to MMIO registers.
2. Controller walks CSR row pointers, column indices, and values.
3. For each nonzero in `A`, accelerator fetches a tile segment from `B`.
4. `TN=8` datapath performs 8 MAC updates in parallel for the current tile.
5. Tile is written back to RAM, optionally with ReLU.

In `INT8` mode:

- CSR values and dense `B` are packed as 4 signed 8-bit values per 32-bit word
- Datapath sign-extends packed bytes back to 32-bit internally
- Accumulation remains `INT32`
- One 32-bit `B` read can feed up to 4 `B` lanes

## Memory Map

| Address Range | Peripheral | Description |
|---|---|---|
| `0x0000_0000 - 0x0000_FFFF` | RAM | 64 KB on-chip RAM |
| `0x1000_0000 - 0x1000_00FF` | Accelerator | SpMM MMIO registers |
| `0x2000_0000 - 0x2000_000F` | GPIO | LEDs, switches, HEX display output |
| `0x2000_0100 - 0x2000_01FF` | UART | `simpleuart` MMIO window |

## Repository Layout

| Path | Purpose |
|---|---|
| `rtl/` | Accelerator RTL (`accel_top`, `accel_ctrl`, `accel_datapath`) |
| `tb/` | Unit and integration testbenches |
| `fpga/rtl/` | DE1-SoC top-level SoC integration |
| `fpga/quartus/` | Quartus project, constraints, generated firmware MIFs |
| `sw/driver/` | Bare-metal PicoRV32 benchmark firmware |
| `ip/picorv32/` | Third-party PicoRV32 core and related collateral |
| `docs/` | Report sources and project documentation |
| `sim/` | Simulation scripts |

## Build Flow

### Firmware

```bash
cd sw/driver
make clean
make all mif install-mif
```

This updates:

- `sw/driver/firmware.mif`
- `fpga/quartus/firmware.mif`
- split byte-lane MIF files used in the Quartus flow

### Quartus

```bash
cd fpga/quartus
quartus_sh --flow compile de1_soc_spmm
```

### Programming

```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/de1_soc_spmm.sof"
```

## Benchmark Input Set

The same 12 benchmark IDs are used across the recorded sweeps.

| Test ID | M x K x N | Sparsity of A | Pattern of A | Reason |
|---|---:|---:|---|---|
| T1 | 8 x 8 x 8 | 75% | Uniform | Very small sanity/debug case to verify correctness on an easy example. |
| T2 | 16 x 16 x 8 | 75% | Uniform | Small baseline case. |
| T3 | 32 x 32 x 8 | 75% | Uniform | Medium baseline case. |
| T4 | 64 x 64 x 8 | 75% | Uniform | Larger size scaling case. |
| T5 | 64 x 64 x 16 | 75% | Uniform | Used to observe the effect of increasing `N`. |
| T6 | 64 x 64 x 32 | 75% | Uniform | Used to observe scaling with a wider dense matrix. |
| T7 | 32 x 32 x 32 | 50% | Uniform | Lower sparsity case with more non-zero values. |
| T8 | 32 x 32 x 32 | 75% | Uniform | Mid-sparsity reference case. |
| T9 | 32 x 32 x 32 | 90% | Uniform | Very sparse case. |
| T10 | 32 x 32 x 32 | 75% | Row-skewed NNZ | Tests sensitivity to uneven non-zero distribution across rows. |
| T11 | 32 x 32 x 32 | 75% | Clustered / blocky NNZ | Tests sensitivity to clustered non-zero patterns. |
| T12 | 64 x 64 x 32 | 90% | Uniform | Larger sparse stress case. |

## Results 1: Baseline CPU vs Baseline CPU+Accelerator

Before enabling parallel DSP-based multi-MAC per cycle.

| Test ID | CPU Cycles | Accelerator Cycles | Speedup | Pass/Fail | Notes |
|---|---:|---:|---:|---|---|
| T1 | 10373 | 856 | 12.12x | PASS | Very small sanity/debug case passed. |
| T2 | 36573 | 2318 | 15.78x | PASS | Small baseline case. |
| T3 | 136877 | 7809 | 17.53x | PASS | Medium baseline case. |
| T4 | 529101 | 29195 | 18.12x | PASS | Best observed speedup in the sweep. |
| T5 | 986829 | 58112 | 16.98x | PASS | Increasing `N` to 16 maintained strong acceleration. |
| T6 | 1902285 | 115980 | 16.40x | PASS | Wider dense matrix case with `N=32`. |
| T7 | 951213 | 58112 | 16.37x | PASS | Lower sparsity (50%) case still achieved strong speedup. |
| T8 | 491693 | 30470 | 16.14x | PASS | Mid-sparsity reference case. |
| T9 | 215263 | 13844 | 15.55x | PASS | Very sparse case with 90% sparsity. |
| T10 | 491693 | 30470 | 16.14x | PASS | Row-skewed pattern matched reference performance in this setup. |
| T11 | 491693 | 30470 | 16.14x | PASS | Clustered pattern matched reference performance in this setup. |
| T12 | 800155 | 49663 | 16.11x | PASS | Larger sparse stress case. |

Summary:

- 12/12 passed
- Speedup range: `12.12x` to `18.12x`
- Best case: `T4 = 18.12x`

## Results 2: Parallel DSP-Based MAC Update

After enabling parallel DSP-based multiple MAC operations per clock cycle.

| Test ID | CPU Cycles | Accelerator Cycles | Speedup | Pass/Fail | Notes |
|---|---:|---:|---:|---|---|
| T1 | 10373 | 737 | 14.07x | PASS | Improved small sanity/debug case after parallel MAC update. |
| T2 | 36573 | 1859 | 19.67x | PASS | Small baseline case improved with parallel DSP usage. |
| T3 | 136877 | 6024 | 22.72x | PASS | Medium baseline case showed strong improvement. |
| T4 | 529101 | 22021 | 24.03x | PASS | Best observed speedup in the updated sweep. |
| T5 | 986829 | 43781 | 22.54x | PASS | Increasing `N` to 16 still maintained strong acceleration. |
| T6 | 1902285 | 87301 | 21.79x | PASS | Wider dense matrix case with `N=32` improved significantly. |
| T7 | 951213 | 43781 | 21.73x | PASS | Lower sparsity (50%) case still achieved strong speedup. |
| T8 | 491693 | 23296 | 21.11x | PASS | Mid-sparsity reference case. |
| T9 | 215263 | 10988 | 19.59x | PASS | Very sparse case with 90% sparsity. |
| T10 | 491693 | 23296 | 21.11x | PASS | Row-skewed pattern matched reference performance in this setup. |
| T11 | 491693 | 23296 | 21.11x | PASS | Clustered pattern matched reference performance in this setup. |
| T12 | 800155 | 38188 | 20.95x | PASS | Larger sparse stress case. |

Summary:

- 12/12 passed
- Speedup range: `14.07x` to `24.03x`
- Best case: `T4 = 24.03x`
- Total accelerator cycles reduced from `427,299` to `324,568` vs baseline (`1.32x` reduction)

## Results 3: Runtime Symmetric INT8 Quantization

Quantized CPU reference vs accelerator with runtime symmetric `INT8` quantization of `A_values` and `B`, with `INT32` accumulation.

| Test ID | CPU Cycles | Accelerator Cycles | Speedup | Pass/Fail | Notes |
|---|---:|---:|---:|---|---|
| T1 | 10735 | 567 | 18.93x | PASS | Quantized small sanity/debug case. |
| T2 | 38087 | 1111 | 34.28x | PASS | Small baseline case improved strongly after INT8 quantization. |
| T3 | 142999 | 2964 | 48.25x | PASS | Medium baseline case showed major speedup gain. |
| T4 | 553655 | 9747 | 56.80x | PASS | Best observed speedup in the INT8 sweep. |
| T5 | 1044151 | 19216 | 54.34x | PASS | Increasing `N` to 16 still maintained very strong acceleration. |
| T6 | 2025143 | 38171 | 53.05x | PASS | Wider dense matrix case with `N=32` benefited significantly. |
| T7 | 1012631 | 19216 | 52.70x | PASS | Lower sparsity (50%) case still achieved very strong speedup. |
| T8 | 522391 | 11039 | 47.32x | PASS | Mid-sparsity reference case. |
| T9 | 227481 | 6109 | 37.24x | PASS | Very sparse case with 90% sparsity. |
| T10 | 522391 | 11039 | 47.32x | PASS | Row-skewed pattern matched reference performance in this setup. |
| T11 | 522391 | 11039 | 47.32x | PASS | Clustered pattern matched reference performance in this setup. |
| T12 | 849333 | 18519 | 45.86x | PASS | Larger sparse stress case with strong INT8 acceleration. |

Summary:

- 12/12 passed
- Speedup range: `18.93x` to `56.80x`
- Best case: `T4 = 56.80x`
- Total accelerator cycles reduced from `324,568` to `148,737` vs parallel-DSP run (`2.18x` reduction)

## Results 4: ARM Cortex-M0 Software vs INT8 Accelerator

Cortex-M0 software SpMM compared against the same INT8 accelerator cycles used in the sweep above.

| Test ID | Cortex-M0 Cycles | Accelerator Cycles | Speedup | Pass/Fail | Notes |
|---|---:|---:|---:|---|---|
| T1 | 2952 | 567 | 5.21x | PASS | Small sanity/debug case. |
| T2 | 9448 | 1111 | 8.50x | PASS | Small baseline case. |
| T3 | 31912 | 2964 | 10.77x | PASS | Medium case showed clear acceleration benefit. |
| T4 | 116200 | 9747 | 11.92x | PASS | Best observed speedup against the Cortex-M0 baseline. |
| T5 | 207592 | 19216 | 10.80x | PASS | Increasing `N` to 16 maintained strong speedup. |
| T6 | 390376 | 38171 | 10.23x | PASS | Wider dense matrix case with `N=32`. |
| T7 | 195240 | 19216 | 10.16x | PASS | Lower sparsity (50%) case still achieved strong acceleration. |
| T8 | 104488 | 11039 | 9.47x | PASS | Mid-sparsity reference case. |
| T9 | 46892 | 6109 | 7.68x | PASS | Very sparse case showed reduced but still strong speedup. |
| T10 | 99748 | 11039 | 9.04x | PASS | Row-skewed pattern showed slight sensitivity on Cortex-M0. |
| T11 | 102209 | 11039 | 9.26x | PASS | Clustered pattern remained close to the uniform reference. |
| T12 | 169710 | 18519 | 9.16x | PASS | Larger sparse stress case. |

Summary:

- 12/12 passed
- Speedup range: `5.21x` to `11.92x`
- Best case: `T4 = 11.92x`

## Key Takeaways

- Parallel DSP-based MAC improved accelerator runtime before quantization.
- INT8 packed memory path delivered the largest cycle reduction by improving effective data fetch density.
- The strongest acceleration is observed in larger dense-width and moderate-sparsity workloads.
- All benchmark sets remained functionally correct (`PASS` in every case).

## Scope Limits

This README does not claim:

- interrupt-driven completion in mainline firmware (current flow is polling-based)
- custom ISA instruction extensions for accelerator invocation
- pooling kernels in the active benchmark path
- full power/area characterization

## References

- PicoRV32 upstream core: `ip/picorv32/`
- Quartus project notes: [`fpga/quartus/README.md`](fpga/quartus/README.md)
- Driver and benchmark source: [`sw/driver/main.c`](sw/driver/main.c)
- Accelerator register definitions: [`sw/driver/spmm_accel.h`](sw/driver/spmm_accel.h)
