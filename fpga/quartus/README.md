# DE1-SoC SpMM Accelerator - Quartus Project

## Overview

This Quartus project implements a System-on-Chip with:
- **PicoRV32** - Lightweight RISC-V CPU (RV32IM)
- **SpMM Accelerator** - Sparse Matrix-Matrix Multiply hardware accelerator
- **64KB On-Chip RAM** - For firmware and data
- **GPIO** - LEDs, switches, 7-segment displays
- **UART** - `simpleuart` exposed on GPIO header pins for external USB-TTL

## Target Device

- **Board**: Terasic DE1-SoC
- **FPGA**: Cyclone V 5CSEMA5F31C6
- **Clock**: 50 MHz (from on-board oscillator)

## Memory Map

| Address Range           | Peripheral      | Description               |
|------------------------|-----------------|---------------------------|
| `0x0000_0000 - 0x0000_FFFF` | RAM         | 64KB on-chip RAM          |
| `0x1000_0000 - 0x1000_00FF` | Accelerator | SpMM MMIO registers       |
| `0x2000_0000 - 0x2000_000F` | GPIO        | LEDs, Switches, Keys      |
| `0x2000_0100 - 0x2000_01FF` | UART        | `simpleuart` MMIO window  |

### GPIO Registers

| Offset | Name      | Description                        |
|--------|-----------|-------------------------------------|
| `0x00` | GPIO_OUT  | Write to LEDs[5:0], read back      |
| `0x04` | GPIO_IN   | Read switches (SW[9:0])            |
| `0x08` | GPIO_KEY  | Read push buttons (KEY[3:0])       |

### UART Registers

| Offset | Name      | Description                                |
|--------|-----------|--------------------------------------------|
| `0x04` | UART_DIV  | Baud divider (`50MHz/115200 ~= 434`)       |
| `0x08` | UART_DATA | TX write / RX read register (`simpleuart`) |

### External UART Wiring (FTDI C232HM or equivalent)

- FPGA `uart_tx` on `GPIO_0[0]` (`PIN_AC18`) -> adapter RXD
- FPGA `uart_rx` on `GPIO_0[1]` (`PIN_Y17`) -> adapter TXD
- FPGA GND -> adapter GND
- Use 3.3V TTL levels

## Building

### Prerequisites

1. **Quartus Prime** 20.1 or later (Lite Edition works)
2. **RISC-V Toolchain** for firmware compilation

### Compile Firmware

```bash
cd ../../sw/driver
make clean
make

# Convert to MIF format for Quartus
python3 hex2mif.py firmware.hex firmware.mif
cp firmware.mif ../../fpga/quartus/
```

### Synthesize in Quartus

1. Open Quartus Prime
2. File → Open Project → `de1_soc_spmm.qpf`
3. Processing → Start Compilation
4. Or use command line:

```bash
quartus_sh --flow compile de1_soc_spmm
```

### Program FPGA

```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/de1_soc_spmm.sof"
```

## Resource Estimates

| Resource    | Used (Est.) | Available | Utilization |
|-------------|-------------|-----------|-------------|
| ALMs        | ~5,000      | 32,070    | ~16%        |
| M10K Blocks | ~20         | 397       | ~5%         |
| DSP Blocks  | ~4          | 87        | ~5%         |

## LED Assignments

| LED   | Function                    |
|-------|----------------------------|
| LED[0-5] | GPIO controlled          |
| LED[6]   | Accelerator FSM[0]       |
| LED[7]   | Accelerator FSM[1]       |
| LED[8]   | Accelerator FSM[2]       |
| LED[9]   | Accelerator Busy         |

## Testing

1. Program the FPGA with the bitstream
2. Firmware runs automatically from RAM
3. Watch LEDs for status:
   - LED[9] lit = Accelerator busy
   - LED[0-5] = Test status/result
4. Use HEX displays to see result codes

## Troubleshooting

### Timing Failures
If you get timing failures at 50 MHz:
1. Enable Physical Synthesis options in QSF
2. Try FITTER_EFFORT = "AGGRESSIVE"
3. Consider using 25 MHz clock (modify SDC)

### Memory Initialization
Make sure `firmware.mif` is in the Quartus project directory before synthesis.

## File Structure

```
fpga/quartus/
├── de1_soc_spmm.qpf      # Project file
├── de1_soc_spmm.qsf      # Settings (pins, options)
├── de1_soc_spmm.sdc      # Timing constraints
├── firmware.mif          # Compiled firmware (generated)
└── output_files/         # Synthesis outputs
    └── de1_soc_spmm.sof  # Bitstream

fpga/rtl/
└── soc_top.sv            # Synthesizable SoC top
```
