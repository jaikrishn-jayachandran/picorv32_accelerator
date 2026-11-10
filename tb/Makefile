SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# Point to your FFT analysis RTL source
VERILOG_SOURCES += $(PWD)/rtl/accelerator/fft_analysis.sv

TOPLEVEL = fft_analysis
MODULE = test_fft_analysis

export PYTHONPATH := $(PWD)/tb:$(PYTHONPATH)

EXTRA_ARGS += --timing --trace --trace-fst

include $(shell cocotb-config --makefiles)/Makefile.sim