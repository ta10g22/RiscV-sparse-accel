# SpMM Accelerator Firmware Makefile
# Builds bare-metal firmware for PicoRV32

# ============================================================
# Toolchain Configuration
# ============================================================
# Use riscv64 toolchain (can compile RV32 with -march=rv32im)
CROSS_PREFIX ?= riscv64-unknown-elf-
CC      = $(CROSS_PREFIX)gcc
OBJCOPY = $(CROSS_PREFIX)objcopy
OBJDUMP = $(CROSS_PREFIX)objdump
SIZE    = $(CROSS_PREFIX)size

# ============================================================
# Compiler Flags
# ============================================================
ARCH_FLAGS = -march=rv32im -mabi=ilp32

CFLAGS  = $(ARCH_FLAGS)
CFLAGS += -Os                    # Optimize for size
CFLAGS += -Wall -Wextra          # Warnings
CFLAGS += -ffreestanding         # No hosted environment
CFLAGS += -nostdlib              # No standard library
CFLAGS += -fno-builtin           # No builtins
CFLAGS += -I.                    # Include current dir

LDFLAGS = $(ARCH_FLAGS)
LDFLAGS += -nostdlib
LDFLAGS += -T linker.ld          # Linker script
LDFLAGS += -Wl,--gc-sections     # Remove unused sections

# ============================================================
# Source Files
# ============================================================
SRCS = start.S libc_stubs.c spmm_accel.c main.c
OBJS = $(SRCS:.c=.o)
OBJS := $(OBJS:.S=.o)

TARGET = firmware

# ============================================================
# Build Rules
# ============================================================
.PHONY: all clean dump

all: $(TARGET).hex $(TARGET).bin

$(TARGET).elf: $(OBJS) linker.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	$(SIZE) $@

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

$(TARGET).hex: $(TARGET).bin
	python3 bin2hex32.py $< $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

dump: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $(TARGET).dump

# Generate MIF for Quartus synthesis (4 byte-lane files for Block RAM)
mif: $(TARGET).hex
	python3 hex2mif.py $< firmware.mif --split-bytes

# Also generate single 32-bit MIF for reference
$(TARGET).mif: $(TARGET).hex
	python3 hex2mif.py $< $@

# Copy MIF files to Quartus project directory
install-mif: mif
	cp firmware0.mif firmware1.mif firmware2.mif firmware3.mif ../../fpga/quartus/

clean:
	rm -f *.o $(TARGET).elf $(TARGET).hex $(TARGET).bin $(TARGET).dump $(TARGET).mif firmware*.mif
