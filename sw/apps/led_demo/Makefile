# Makefile for led_demo
#
# Run from sw/apps/led_demo/
#
#   make            build led_demo.elf
#   make verify     check symbol placement and size
#   make coe        build and install the COE where the Vivado Tcl reads it
#   make clean

APP         := led_demo

# Paths relative to this directory (sw/apps/<app>/)
BSP_DIR     := ../../bsp/genesys2
TOOLS_DIR   := ../../tools
REPO_ROOT   := ../../..
MEM_INIT    := $(REPO_ROOT)/fpga/genesys2/mem_init_file

CROSS       := riscv32-unknown-elf-
CC          := $(CROSS)gcc
OBJDUMP     := $(CROSS)objdump
NM          := $(CROSS)nm
SIZE        := $(CROSS)size

# Must match the wrapper parameters. B_EXT is B_NONE, so no bitmanip.
ARCH_FLAGS  := -march=rv32imc_zicsr_zifencei -mabi=ilp32 -mcmodel=medlow

CFLAGS      := $(ARCH_FLAGS) -O2 -Wall -Wextra \
               -ffunction-sections -fdata-sections

LDFLAGS     := $(ARCH_FLAGS) -nostartfiles -nodefaultlibs \
               -Wl,--gc-sections -Wl,-Map=$(APP).map \
               -T $(BSP_DIR)/link.ld

SRCS        := $(BSP_DIR)/crt0.S main.c

.PHONY: all verify coe clean

all: $(APP).elf

$(APP).elf: $(SRCS) $(BSP_DIR)/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@

# _start must be at 80000000, trap_handler on a 128-byte boundary,
# and the image must fit in 64 KB.
verify: $(APP).elf
	@echo "--- symbols ---"
	@$(NM) $< | grep -E "_start|trap_handler|__stack_top|__bss"
	@echo "--- first instructions ---"
	@$(OBJDUMP) -d $< | head -20
	@echo "--- size ---"
	@$(SIZE) $<

coe: $(APP).elf
	python3 $(TOOLS_DIR)/elf2coe.py $< $(MEM_INIT)/$(APP).coe
	@echo "wrote $(MEM_INIT)/$(APP).coe"

clean:
	rm -f $(APP).elf $(APP).map
