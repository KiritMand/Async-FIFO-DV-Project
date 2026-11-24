# common/sim/verilator.mk — Verilator simulator layer: build a UVM testbench once per
# configuration, run one test at one seed in a fresh directory, judge the log.
# Block Makefiles call it as `make -f common/sim/verilator.mk run VAR=...`. Nothing here is
# specific to one block; another simulator gets its own <sim>.mk with the same targets/inputs.
#
# Inputs:  TOP (top module)  SRCS (ordered sources)  INCDIRS  DEFINES (NAME=VALUE list)
#          DEPS (rebuild when any is newer)  BUILD_DIR  RUN_DIR (wiped per run; must be under out/)
#          TEST  SEED  PLUSARGS  J  UVM_HOME  REPRO (the make command printed for reproduction)

# ---- Paths and toolchain (pinned OSS CAD Suite on PATH).
SIM_MK   := $(abspath $(lastword $(MAKEFILE_LIST)))
COMMON   := $(abspath $(dir $(SIM_MK))/..)
include $(COMMON)/tools.mk
UVM_HOME ?= $(HOME)/tools/uvm-2020-3.2/src
J        ?= $(shell nproc 2>/dev/null || echo 4)
# C++ compile jobs: each of Verilator's unity files for a UVM testbench peaks near 1.2 GB, so the
# job count follows free memory (1.5 GB per job, at most J). Eight jobs on this 8 GB host swapped
# and took 96 min instead of ~5 (docs/toolchain.md, M3).
BUILD_J  ?= $(shell awk -v j=$(J) '/MemAvailable/ { n = int($$2 / 1500000); print (n < 1) ? 1 : (n > j) ? j : n }' /proc/meminfo)
EXE       = $(BUILD_DIR)/V$(TOP)
PATTERNS  = $(COMMON)/sim/verilator.patterns

# ---- Build command. --timing: delays and clocking blocks; --vpi: UVM's DPI layer; --trace:
# allows +trace dumps; 1 ps resolution; random initial values chosen per seed at run time
# (toolchain T9); -Werror-USERERROR keeps the RTL parameter guards fatal (T7). Default warning
# set, all fatal (not -Wall: false positives on clocking blocks, T8). Verilation uses J threads,
# the C++ compile BUILD_J jobs.
VLT_FLAGS = --binary --timing --vpi --trace --verilate-jobs $(J) --build-jobs $(BUILD_J) --timescale 1ps/1ps \
            --x-assign unique --x-initial unique -Werror-USERERROR \
            --top-module $(TOP) -Mdir $(BUILD_DIR)
# `env -u MAKEFLAGS ...`: our command-line variables would otherwise reach Verilator's own
# generated makefile, where DEPS is an internal variable (overriding it breaks the build).
VLT_CMD   = env -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS \
            verilator $(VLT_FLAGS) $(addprefix +define+,$(DEFINES)) \
            +incdir+$(UVM_HOME) $(addprefix +incdir+,$(INCDIRS)) \
            $(UVM_HOME)/uvm_pkg.sv $(UVM_HOME)/dpi/uvm_dpi.cc $(SRCS)

# ---- Run command: the UVM test; the seed (also seeds the random register init); no
# end-of-run statistics (wall time would make identical runs' logs differ).
RUN_CMD   = $(EXE) +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) +verilator+rand+reset+2 \
            +verilator+quiet +UVM_NO_RELNOTES $(PLUSARGS)

.PHONY: build run
build: $(EXE)

# Build only when a dependency changed (a UVM build takes minutes). On failure show the first
# diagnostics; the full output stays in build.log.
$(EXE): $(DEPS)
	@mkdir -p $(BUILD_DIR)
	@echo "+ $(VLT_CMD)"
	@start=$$(date +%s); \
	  $(VLT_CMD) > $(BUILD_DIR)/build.log 2>&1 || { grep -E '%(Error|Warning)' $(BUILD_DIR)/build.log | head -20; \
	    echo "sim FAIL: build, see $(BUILD_DIR)/build.log" >&2; exit 1; }; \
	  echo "  built in $$(( $$(date +%s) - start )) s: $(EXE)"

# One run in a fresh directory (the guard refuses to wipe anything outside out/), then the log
# verdict; simlog.py exits non-zero on FAIL. The reproduction command is printed either way.
run: build
	@case "$(RUN_DIR)" in */out/*) ;; *) echo "sim: RUN_DIR must be under out/ (got '$(RUN_DIR)')" >&2; exit 2;; esac
	@rm -rf -- "$(RUN_DIR)" && mkdir -p "$(RUN_DIR)"
	@echo "+ (cd $(RUN_DIR) && $(RUN_CMD)) > $(RUN_DIR)/sim.log 2>&1"
	@rc=0; (cd $(RUN_DIR) && $(RUN_CMD)) > $(RUN_DIR)/sim.log 2>&1 || rc=$$?; \
	  st=0; python3 $(COMMON)/scripts/simlog.py --patterns $(PATTERNS) --exit-code $$rc $(RUN_DIR)/sim.log || st=$$?; \
	  echo "  repro: $(REPRO)"; exit $$st
