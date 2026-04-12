# RISC-V Sparse Matrix Accelerator

This repository contains a PicoRV32-based SoC with a custom SystemVerilog sparse matrix-matrix multiplication (SpMM) accelerator for the Terasic DE1-SoC FPGA board.

The current integrated build is focused on one kernel:

- CSR-format SpMM: `C = A x B`
- Optional ReLU on the output writeback path
- `INT8` packed input mode for CSR values and dense `B`, with `INT32` accumulation

This repository is not currently an open-ended "AI instruction extension" platform. The implemented and benchmarked path is a memory-mapped SpMM accelerator attached to PicoRV32.

## Current Status

- SoC integration working on DE1-SoC
- PicoRV32 firmware configures and launches the accelerator through MMIO
- Shared on-chip RAM used for firmware, matrices, and output buffers
- UART benchmark output working from hardware
- `INT8` packed-input mode implemented and validated
- All 12 current hardware benchmark cases pass against the quantized CPU reference

Important current constraints:

- Completion is polling-based, not interrupt-driven
- The accelerator is tiled across output columns with `TN = 8`
- The benchmark firmware currently evaluates quantized CPU SpMM versus quantized `INT8` accelerator SpMM

## Architecture

The implemented system consists of:

- `PicoRV32` RV32IM soft-core CPU
- `accel_top`, `accel_ctrl`, and `accel_datapath` SystemVerilog modules
- 64 KB on-chip RAM
- MMIO-mapped accelerator control registers
- GPIO output for board display
- `simpleuart` MMIO window for UART logging

High-level accelerator behavior:

1. Firmware writes matrix dimensions and buffer base addresses to MMIO registers.
2. The controller walks CSR row pointers, column indices, and values.
3. For each nonzero in `A`, the accelerator fetches a tile of `B`.
4. A `TN=8` datapath performs 8 MAC updates in parallel for the current output tile.
5. The output tile is written back to RAM, optionally with ReLU applied.

In `INT8` mode:

- CSR values and dense `B` are packed as 4 signed 8-bit values per 32-bit word
- The datapath sign-extends packed bytes back to 32-bit values internally
- Accumulation remains `INT32`
- One packed 32-bit `B` read can feed up to 4 `B` lanes, reducing memory traffic

## Memory Map

The integrated SoC uses the following memory map:

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
| `sw/driver/` | Bare-metal PicoRV32 firmware and benchmark program |
| `ip/picorv32/` | Third-party PicoRV32 core and related collateral |
| `docs/` | Report sources and project documentation |
| `sim/` | Simulation scripts |

## Build Flow

### Firmware

Build the PicoRV32 firmware and regenerate Quartus memory images:

```bash
cd sw/driver
make clean
make all mif install-mif
```

This now updates both:

- `sw/driver/firmware.mif`
- `fpga/quartus/firmware.mif`

as well as the split byte-lane MIFs used elsewhere in the flow.

### Quartus

After regenerating the firmware MIFs, recompile the Quartus project so the new firmware is embedded in the FPGA image:

```bash
cd fpga/quartus
quartus_sh --flow compile de1_soc_spmm
```

### Programming

Example programming command:

```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/de1_soc_spmm.sof"
```

## Benchmark Method

The current firmware:

- generates runtime test matrices
- stores `A` in CSR format
- quantizes CSR values and dense `B` to signed `INT8`
- packs those values into 32-bit words
- times a quantized CPU reference
- times the `INT8` accelerator
- prints per-test cycle counts and speedup over UART

The current hardware benchmark mode is:

`runtime symmetric INT8 quantization (A_values, B), INT32 accumulate`

The accelerator output is checked against the quantized CPU reference, not the full-precision software result.

## Current Hardware Results

Current UART sweep output on hardware:

| ID | M | K | N | Sparsity | Pattern | NNZ | CPU Cycles | ACCEL Cycles | Speedup | Pass |
|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---|
| T1 | 8 | 8 | 8 | 75 | uniform | 16 | 10735 | 567 | 18.93x | PASS |
| T2 | 16 | 16 | 8 | 75 | uniform | 64 | 38087 | 1111 | 34.28x | PASS |
| T3 | 32 | 32 | 8 | 75 | uniform | 256 | 142999 | 2964 | 48.25x | PASS |
| T4 | 64 | 64 | 8 | 75 | uniform | 1024 | 553655 | 9747 | 56.80x | PASS |
| T5 | 64 | 64 | 16 | 75 | uniform | 1024 | 1044151 | 19216 | 54.34x | PASS |
| T6 | 64 | 64 | 32 | 75 | uniform | 1024 | 2025143 | 38171 | 53.05x | PASS |
| T7 | 32 | 32 | 32 | 50 | uniform | 512 | 1012631 | 19216 | 52.70x | PASS |
| T8 | 32 | 32 | 32 | 75 | uniform | 256 | 522391 | 11039 | 47.32x | PASS |
| T9 | 32 | 32 | 32 | 90 | uniform | 102 | 227481 | 6109 | 37.24x | PASS |
| T10 | 32 | 32 | 32 | 75 | row_skewed | 256 | 522391 | 11039 | 47.32x | PASS |
| T11 | 32 | 32 | 32 | 75 | clustered | 256 | 522391 | 11039 | 47.32x | PASS |
| T12 | 64 | 64 | 32 | 90 | uniform | 410 | 849333 | 18519 | 45.86x | PASS |

Summary:

- 12/12 cases passed
- Observed speedup range: `18.93x` to `56.80x`
- Best reported case in the current sweep: `T4 = 56.80x`

## Measured INT8 Packing Effect

To isolate the effect of the `INT8` packed-memory path on accelerator runtime, the old and new accelerator cycle totals were compared directly:

- Total old accelerator cycles: `324,568`
- Total new accelerator cycles: `148,737`
- Measured accelerator-cycle reduction from `INT8` packing: `2.18x`

This number is specifically the accelerator-side effect of the packed `INT8` path. It is different from the end-to-end CPU-versus-accelerator speedup table above.

## What The Project Currently Does Not Claim

The current integrated build does not yet demonstrate:

- end-to-end interrupt-driven completion
- custom RISC-V instructions for accelerator invocation
- pooling support in the active hardware/firmware path
- a full power and area evaluation in this README

Those are valid future extensions, but they are not the current mainline result.

## Notes

- As `N` grows beyond the tile width `TN=8`, the accelerator processes multiple output-column tiles. This repeats tile-clear, row traversal, and writeback overhead per tile.
- Because of that, end-to-end speedup does not scale perfectly with larger `N`, even though the accelerator remains substantially faster than the CPU baseline.

## References

- PicoRV32 upstream core: `ip/picorv32/`
- Quartus project notes: [`fpga/quartus/README.md`](fpga/quartus/README.md)
- Driver and benchmark source: [`sw/driver/main.c`](sw/driver/main.c)
- Accelerator register definitions: [`sw/driver/spmm_accel.h`](sw/driver/spmm_accel.h)
