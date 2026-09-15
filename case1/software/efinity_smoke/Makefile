PROJECT      ?= c1_efinity_smoke
BUILD        ?= build
RISCV_PREFIX ?= riscv-none-elf-
MARCH        ?= rv32imc
MABI         ?= ilp32

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

CFLAGS  := -std=c11 -Wall -Wextra -Werror -Os -ffreestanding -fno-builtin \
            -march=$(MARCH) -mabi=$(MABI)
CPPFLAGS := -I../include
ifneq ($(strip $(SOC_INCLUDE)),)
CPPFLAGS += -I$(SOC_INCLUDE)
endif
ifneq ($(strip $(SOC_HEADER)),)
CPPFLAGS += -include $(SOC_HEADER)
endif
ifneq ($(strip $(C1_ACCEL_MMIO_BASE)),)
CPPFLAGS += -DC1_ACCEL_MMIO_BASE=$(C1_ACCEL_MMIO_BASE)
endif
LDFLAGS := -nostdlib -Wl,-T,linker.ld,-Map,$(BUILD)/$(PROJECT).map \
           -Wl,--gc-sections -lgcc

C1_ACCEL_SRC := ../src/c1_accel.c
# Keep every generated object below BUILD.  A direct pattern substitution on
# ../src/c1_accel.c would otherwise create build/../src/c1_accel.o, which
# escapes the directory removed by `make clean`.
OBJECTS := $(BUILD)/main.o $(BUILD)/startup.o $(BUILD)/c1_accel.o

.PHONY: all clean

all: $(BUILD)/$(PROJECT).elf $(BUILD)/$(PROJECT).hex \
     $(BUILD)/$(PROJECT).bin $(BUILD)/$(PROJECT).asm

$(BUILD):
	@mkdir -p $@

$(BUILD)/%.o: %.c | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/c1_accel.o: $(C1_ACCEL_SRC) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/$(PROJECT).elf: $(OBJECTS) linker.ld | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(OBJECTS) $(LDFLAGS) -o $@

$(BUILD)/$(PROJECT).hex: $(BUILD)/$(PROJECT).elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD)/$(PROJECT).bin: $(BUILD)/$(PROJECT).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/$(PROJECT).asm: $(BUILD)/$(PROJECT).elf
	$(OBJDUMP) -S -d $< > $@

clean:
	@rm -rf $(BUILD)
