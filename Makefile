
# ============================================================
# RISC-V TOOLCHAIN
# ============================================================

RISCV_PREFIX ?= riscv64-unknown-elf-

CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy

# ============================================================
# SIMULATION
# ============================================================

SIM = verilator

TOPLEVEL_LANG = verilog
TOPLEVEL = top
COCOTB_TEST_MODULES = full_test

# Make `make` build the firmware first and then run the SoC test.
# (cocotb's Makefile.sim defines `all: sim`, which would otherwise
# become the default goal and run the simulator without firmware.)
.DEFAULT_GOAL := test

# ============================================================
# FIRMWARE
# ============================================================

FW_DIR = sw

FW_ELF = firmware.elf
FW_HEX = firmware.hex

FW_SRCS = \
    $(FW_DIR)/start.s \
    $(FW_DIR)/firmware.c

LINKER_SCRIPT = $(FW_DIR)/sections.ld

# The CPU is configured with ENABLE_MUL/ENABLE_DIV, and the firmware
# uses 32-bit division/modulo, so build for RV32IM.  With RV32I these
# operations would require libgcc helpers (__udivsi3/__umodsi3), which
# are not linked because of -nostdlib.
FW_FLAGS = \
    -march=rv32im \
    -mabi=ilp32 \
    -O2 \
    -nostdlib \
    -nostartfiles \
    -ffreestanding \
    -T $(LINKER_SCRIPT) \
    -Wl,--build-id=none

# ============================================================
# RTL SOURCES
# ============================================================

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Only compile the RTL that is actually used by the SoC.  Do not glob
# all of rtl/: that also picks up testbenches, formal properties and the
# unused iDMA tree, which cannot be compiled as part of `top`.
RTL_PACKAGES := \
    $(PROJECT_ROOT)/rtl/axi/src/axi_pkg.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_pkg.sv

RTL_DESIGN := \
    $(PROJECT_ROOT)/rtl/axi/src/axi_atop_filter.sv \
    $(PROJECT_ROOT)/rtl/axi/src/axi_err_slv.sv \
    $(PROJECT_ROOT)/rtl/axi/src/axi_lite_to_axi.sv \
    $(PROJECT_ROOT)/rtl/axi/src/axi_lite_demux.sv \
    $(PROJECT_ROOT)/rtl/axi/src/axi_lite_mux.sv \
    $(PROJECT_ROOT)/rtl/axi/src/axi_lite_xbar.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_addr_decode.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_addr_decode_dync.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_counter.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_delta_counter.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_fifo.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_lzc.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_rr_arb_tree.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_spill_register.sv \
    $(PROJECT_ROOT)/rtl/common_cells/src/cc_spill_register_flushable.sv \
    $(PROJECT_ROOT)/rtl/cpu/picorv32.v \
    $(PROJECT_ROOT)/rtl/memory/ram.sv \
    $(PROJECT_ROOT)/rtl/accelerator/fft_analysis.sv \
    $(PROJECT_ROOT)/rtl/top.sv

VERILOG_SOURCES := $(RTL_PACKAGES) $(RTL_DESIGN)

# ============================================================
# VERILATOR FLAGS
# ============================================================

COMPILE_ARGS += --timing
COMPILE_ARGS += --assert
COMPILE_ARGS += --public-flat-rw
COMPILE_ARGS += -Wno-fatal

COMPILE_ARGS += -I$(PROJECT_ROOT)/rtl/axi/include
COMPILE_ARGS += -I$(PROJECT_ROOT)/rtl/common_cells/include

# ============================================================
# COCOTB
# ============================================================

# The cocotb test module lives in tb/, not in the project root.
export PYTHONPATH := $(PROJECT_ROOT)/tb:$(PYTHONPATH)

SIM_BUILD = sim_build

include $(shell cocotb-config --makefiles)/Makefile.sim

# ============================================================
# BUILD FIRMWARE
# ============================================================

.PHONY: all firmware verilate run test clean prepare

# Make cocotb's `all`/`sim` targets depend on the firmware as well.
sim: prepare

$(FW_ELF): $(FW_SRCS) $(LINKER_SCRIPT)
	$(CC) $(FW_FLAGS) $(FW_SRCS) -o $@

$(FW_HEX): $(FW_ELF)
	$(OBJCOPY) -O verilog --verilog-data-width=4 $< $@

firmware: $(FW_HEX)

# ============================================================
# RTL SIMULATION
# ============================================================

verilate:
	@echo "[BUILD] Preparing RTL simulation"

# ============================================================
# RUN SIMULATION
# ============================================================

prepare: $(FW_HEX)
	@echo "[BUILD] Firmware HEX generated"
	mkdir -p $(SIM_BUILD)
	cp $(FW_HEX) $(SIM_BUILD)/firmware.hex

test: prepare
	$(MAKE) sim

run: test

# ============================================================
# CLEAN
# ============================================================

clean::
	rm -rf $(FW_ELF) $(FW_HEX)
	rm -rf $(SIM_BUILD)
