# SpMM Accelerator Firmware Makefile
# Builds bare-metal firmware for PicoRV32

# ============================================================
# Toolchain Configuration
# ============================================================
CROSS_PREFIX ?= riscv32-unknown-elf-
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
SRCS = start.S spmm_accel.c main.c
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

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O verilog $< $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

dump: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $(TARGET).dump

clean:
	rm -f *.o $(TARGET).elf $(TARGET).hex $(TARGET).bin $(TARGET).dump
