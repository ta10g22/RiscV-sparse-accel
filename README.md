# RISC-V Sparse Matrix Accelerator

This project implements a small FPGA SoC for accelerating sparse matrix-dense
matrix multiplication:

```text
C = A x B
```

`A` is stored in CSR format, `B` is dense, and the accelerator writes an
`INT32` dense output matrix `C`. The design targets the Terasic DE1-SoC board
and is built around a PicoRV32 RV32IM soft CPU, shared on-chip RAM, and a
custom SystemVerilog SpMM accelerator.

## Current Design

- PicoRV32 firmware configures the accelerator through MMIO.
- The accelerator processes CSR rows and computes dense output tiles.
- The datapath uses `TN = 8` parallel MAC lanes.
- MACs are explicitly mapped to FPGA DSP blocks.
- Optional ReLU is applied during output writeback.
- Runtime `INT8` mode packs CSR values and dense `B` as four signed bytes per
  32-bit word, then sign-extends to `INT32` before multiplication.
- Accumulation and output storage remain `INT32`.
- UART benchmark output is available through `simpleuart`.
- Unit and integration testbenches are included under `tb/`.

## System Architecture

The FPGA build contains:

- PicoRV32 RV32IM CPU
- 64 KB shared on-chip RAM
- SpMM accelerator RTL
- GPIO for LEDs, switches, keys, and HEX displays
- UART MMIO window for benchmark logging

The firmware loads benchmark matrices into RAM, programs accelerator registers,
starts the run, polls for completion, and compares accelerator output against a
software reference.

## Memory Map

| Address Range | Peripheral | Purpose |
|---|---|---|
| `0x0000_0000 - 0x0000_FFFF` | RAM | Firmware, matrices, output buffers |
| `0x1000_0000 - 0x1000_00FF` | Accelerator | SpMM control/status registers |
| `0x2000_0000 - 0x2000_000F` | GPIO | LEDs, switches, keys, HEX display |
| `0x2000_0100 - 0x2000_01FF` | UART | `simpleuart` registers |

## Repository Layout

| Path | Contents |
|---|---|
| `rtl/` | Accelerator RTL: controller, datapath, and top wrapper |
| `fpga/rtl/` | DE1-SoC top-level SoC integration |
| `fpga/quartus/` | Quartus project, constraints, and firmware MIF files |
| `sw/driver/` | Bare-metal PicoRV32 firmware and benchmark code |
| `tb/` | Unit and SoC integration testbenches |
| `sim/` | ModelSim/Questa simulation script |
| `ip/picorv32/` | PicoRV32 core and upstream collateral |
| `docs/my_report/` | LaTeX report source and compiled PDF |

## Build

### Firmware

Requires a RISC-V bare-metal toolchain available as
`riscv64-unknown-elf-*`.

```bash
cd sw/driver
make clean
make all mif install-mif
```

This builds `firmware.elf`, `firmware.hex`, and the Quartus memory
initialisation files. `install-mif` copies the generated MIFs into
`fpga/quartus/`.

### FPGA Bitstream

Requires Intel Quartus Prime for Cyclone V.

```bash
cd fpga/quartus
quartus_sh --flow compile de1_soc_spmm
```

Program the DE1-SoC:

```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/de1_soc_spmm.sof"
```

## Simulation

The main SoC simulation script is:

```bash
cd sim
vsim -do compile_soc.do
```

The script compiles common testbench files, PicoRV32, accelerator RTL, and the
SoC integration testbench, then runs with `sw/driver/firmware.hex`.

## Benchmark Coverage

The firmware runs 12 benchmark cases covering:

- small, medium, and larger matrix sizes
- `N = 8`, `16`, and `32`
- `50%`, `75%`, and `90%` sparsity
- uniform, row-skewed, and clustered sparse patterns
- INT32 and packed INT8 accelerator paths

In the recorded final sweep, all benchmark cases passed. The packed INT8 mode
gave the largest cycle reduction because it reduces the number of dense `B`
memory reads needed to fill the eight-lane `B` segment.

## Main Files

- Accelerator top: `rtl/accel_top.sv`
- Accelerator controller: `rtl/accel_ctrl.sv`
- Accelerator datapath: `rtl/accel_datapath.sv`
- FPGA SoC top: `fpga/rtl/soc_top.sv`
- Firmware benchmark: `sw/driver/main.c`
- Firmware driver: `sw/driver/spmm_accel.c`
- Register definitions: `sw/driver/spmm_accel.h`
- Report PDF: `docs/my_report/main.pdf`

## Notes

- The current firmware uses polling for accelerator completion.
- The accelerator is invoked through MMIO, not custom RISC-V instructions.
- The active benchmark path is SpMM only; pooling and CNN layers are not part of
  the implemented accelerator.
