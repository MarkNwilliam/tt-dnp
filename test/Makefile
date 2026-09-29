# Makefile — cocotb testbench for tt_um_dnp
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
# Relative so the build also works from a symlinked/spacey checkout
SRC_DIR = ../src

# RTL source files (SystemVerilog requires -g2012 for iverilog)
PROJECT_SOURCES = tt_um_dnp.v \
                  np_core.sv \
                  np_id.sv \
                  np_toll.sv \
                  np_edr.sv \
                  np_audit.sv \
                  np_tamper.sv \
                  np_time.sv \
                  np_digest.sv

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD             = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
COMPILE_ARGS      += -g2012

else

# Gate level simulation:
SIM_BUILD             = sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

COMPILE_ARGS += -I$(SRC_DIR)

VERILOG_SOURCES += ./tb.v
TOPLEVEL = tb

COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
