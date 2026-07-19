# ---------------------------------------------------------------------------
# FPGA Network Processing Engine — Build System
# ---------------------------------------------------------------------------
SHELL      := /bin/bash
SIMULATOR  ?= verilator
TOP        ?= tb_axis_fifo

# Map testbench names to Verilator top modules
TOP_MODULE_tb_axis_fifo  := axis_fifo
TOP_MODULE_tb_pipeline   := parser_pipeline
TOP_MODULE := $(TOP_MODULE_$(TOP))

WAVES      ?= 0

# Directories
RTL_DIR    := rtl
SIM_DIR    := sim
BUILD_DIR  := build

# RTL sources
RTL_CORE   := \
	$(RTL_DIR)/common/npe_pkg.sv \
	$(RTL_DIR)/interfaces/axis_register.sv \
	$(RTL_DIR)/interfaces/axis_fifo.sv

RTL_PARSERS := \
	$(RTL_DIR)/parsers/ethernet_parser.sv \
	$(RTL_DIR)/parsers/vlan_parser.sv \
	$(RTL_DIR)/parsers/ipv4_parser.sv \
	$(RTL_DIR)/parsers/udp_parser.sv \
	$(RTL_DIR)/parsers/tcp_parser.sv

RTL_TOP    := \
	$(RTL_DIR)/top/parser_pipeline.sv

RTL_SRCS   := $(RTL_CORE) $(RTL_PARSERS) $(RTL_TOP)

# Testbench sources
TB_SRCS    := $(SIM_DIR)/testbenches/$(TOP).cpp

# Verilator flags
VERILATOR ?= verilator
VFLAGS    := --cc --exe --build -j \
	-CFLAGS "-std=c++17 -I$(abspath $(SIM_DIR)/packet_generators) -I$(abspath $(SIM_DIR)/packet_monitors)" \
	--assert \
	-Wno-fatal \
	-Wno-UNUSED \
	-Wno-PINMISSING \
	-Wno-WIDTH \
	-Wno-MULTITOP

ifeq ($(WAVES),1)
VFLAGS += --trace --trace-structs
endif

TARGET    := $(BUILD_DIR)/obj_dir/$(TOP)

.PHONY: all build run clean lint

all: build

build: $(TARGET)

$(TARGET): $(RTL_SRCS) $(TB_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VFLAGS) \
		--top-module $(TOP_MODULE) \
		$(RTL_SRCS) \
		$(TB_SRCS) \
		-o $(TOP) \
		--Mdir $(BUILD_DIR)/obj_dir
	@echo "Build complete: $(TARGET)"

run: $(TARGET)
	@$(TARGET)

waves: WAVES := 1
waves: clean build
	@echo "Running with wave dump..."
	@$(TARGET)
	@echo "Waveform: $(BUILD_DIR)/waveform.vcd"

clean:
	rm -rf $(BUILD_DIR)

lint:
	$(VERILATOR) --lint-only $(RTL_SRCS) 2>&1

# Regression
REGRESSION_TESTS := tb_axis_fifo tb_pipeline

regression: $(foreach test,$(REGRESSION_TESTS),run_$(test))

run_%: TOP := $*
run_%: TOP_MODULE := $(TOP_MODULE_$*)
run_%: build
	@echo "Running $*..."
	@$(TARGET)

help:
	@echo "Usage: make [target] [TOP=test_name] [WAVES=1]"
	@echo ""
	@echo "Targets:"
	@echo "  build       Compile RTL + testbench (default)"
	@echo "  run         Build and run"
	@echo "  waves       Build with VCD tracing and run"
	@echo "  lint        Run Verilator lint only"
	@echo "  regression  Run all regression tests"
	@echo "  clean       Remove build artifacts"
	@echo "  help        Show this message"
	@echo ""
	@echo "Tests:"
	@echo "  tb_axis_fifo    FIFO infrastructure test"
	@echo "  tb_pipeline     Parser pipeline test"
