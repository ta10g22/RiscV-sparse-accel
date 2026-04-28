

CROSS_PREFIX ?= riscv64-unknown-elf-
CC      = $(CROSS_PREFIX)gcc
OBJCOPY = $(CROSS_PREFIX)objcopy
OBJDUMP = $(CROSS_PREFIX)objdump
SIZE    = $(CROSS_PREFIX)size


ARCH_FLAGS = -march=rv32im -mabi=ilp32

CFLAGS  = $(ARCH_FLAGS)
CFLAGS += -Os
CFLAGS += -Wall -Wextra
CFLAGS += -ffreestanding
CFLAGS += -nostdlib
CFLAGS += -fno-builtin
CFLAGS += -I.

LDFLAGS = $(ARCH_FLAGS)
LDFLAGS += -nostdlib
LDFLAGS += -T linker.ld
LDFLAGS += -Wl,--gc-sections


SRCS = start.S libc_stubs.c spmm_accel.c main.c
OBJS = $(SRCS:.c=.o)
OBJS := $(OBJS:.S=.o)

TARGET = firmware


.PHONY: all clean dump mif install-mif

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


mif: $(TARGET).mif
	python3 hex2mif.py $(TARGET).hex $(TARGET).mif --split-bytes


$(TARGET).mif: $(TARGET).hex
	python3 hex2mif.py $< $@


install-mif: mif
	cp firmware.mif firmware0.mif firmware1.mif firmware2.mif firmware3.mif ../../fpga/quartus/

clean:
	rm -f *.o $(TARGET).elf $(TARGET).hex $(TARGET).bin $(TARGET).dump $(TARGET).mif firmware*.mif
