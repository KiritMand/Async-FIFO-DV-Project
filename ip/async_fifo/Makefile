# ip/async_fifo/Makefile — every flow for the async FIFO block.
#
# Each target prints the command it runs. Targets not built yet print the planned
# command and fail with exit 2, naming the module that implements them, so a stub
# can never be mistaken for a pass.
#
# All flows accept RTL_DIR= and DUT_SRCS= (used by the bug matrix in M8 and MCY in M9).

# ---- Paths: computed from this file's location so make works from any directory.
# THIS_MK must be captured before any include (MAKEFILE_LIST changes after one).
IP        := async_fifo
THIS_MK   := $(abspath $(lastword $(MAKEFILE_LIST)))
IP_ROOT   := $(patsubst %/,%,$(dir $(THIS_MK)))
REPO_ROOT := $(abspath $(IP_ROOT)/../..)
COMMON    := $(REPO_ROOT)/common
OUT       ?= $(REPO_ROOT)/out/$(IP)

# ---- Toolchain: puts the pinned OSS CAD Suite on PATH for every recipe below.
include $(COMMON)/tools.mk

# ---- Overrides used by M8/M9: point every flow at patched or mutated RTL.
RTL_DIR   ?= $(IP_ROOT)/rtl
DUT_SRCS  ?= $(RTL_DIR)/async_fifo.sv

# ---- Run controls: which simulator/test/seed/clock ratio/formal task; J = parallel jobs.
SIM       ?= verilator# DEC-001 (docs/decisions.md)
TEST      ?=
SEED      ?= 1
RATIO     ?= 1:1
TASK      ?= prove
J         ?= $(shell nproc 2>/dev/null || echo 4)

# ---- Parameters: per-flow defaults (sim ASIZE=4 DSIZE=8; formal/MCY ASIZE=3 DSIZE=4).
# Target-specific `?=` so a command-line ASIZE=/DSIZE= still wins.
SIM_FLOWS    := lint synth smoke sim regress cov bugs
FORMAL_FLOWS := formal mcy
$(SIM_FLOWS):    ASIZE ?= 4
$(SIM_FLOWS):    DSIZE ?= 8
$(FORMAL_FLOWS): ASIZE ?= 3
$(FORMAL_FLOWS): DSIZE ?= 4

# stub,<module>,<planned command>: placeholder recipe for targets not built yet. Prints the
# planned command, names the module that builds it, and exits 2 so it never counts as a pass.
define stub
@echo "+ $(2)"
@echo "make $@: not implemented yet — built in $(1) (docs/PROJECT_PLAN.md §6)." >&2
@exit 2
endef

.DEFAULT_GOAL := help
.PHONY: help lint synth smoke vplan sim sim-build regress cov formal bugs mcy results clean

# Self-documenting help: lists every rule that has a "## " description, plus variables.
help: ## [M0] List targets and variables
	@echo "async_fifo targets (run from repo root or ip/async_fifo):"
	@grep -E '^[a-z-]+: ##' $(THIS_MK) | sed -E 's/^([a-z-]+): ## /  \1\t/' | expand -t 12
	@echo ""
	@echo "Variables (current value):"
	@echo "  RTL_DIR=$(RTL_DIR)"
	@echo "  DUT_SRCS=$(DUT_SRCS)"
	@echo "  SIM=$(SIM)  TEST=$(TEST)  SEED=$(SEED)  RATIO=$(RATIO)  J=$(J)"
	@echo "  TASK=$(TASK) (bmc|prove|cover|pdr)  ASIZE/DSIZE: sim 4/8, formal+mcy 3/4 unless set"
	@echo "  OUT=$(OUT)"
	@echo "  OSS_CAD_SUITE=$(OSS_CAD_SUITE)"

# ---- Shared by the RTL flows below.
# -Werror-USERERROR keeps the RTL's parameter guards fatal in every Verilator build (toolchain T7).
VLT_GUARD  := -Werror-USERERROR
# Variables for the printed repro line: sizes, plus any RTL or OUT override given on the command
# line (an RTL variant built into its own OUT must rerun there, not over the default runs).
REPRO_VARS  = ASIZE=$(ASIZE) DSIZE=$(DSIZE)$(if $(filter command line,$(origin RTL_DIR)), RTL_DIR=$(RTL_DIR))$(if $(filter command line,$(origin DUT_SRCS)), DUT_SRCS='$(DUT_SRCS)')$(if $(filter command line,$(origin OUT)), OUT=$(OUT))
# Illegal sizes the RTL guards must reject (spec §2), as ASIZE:DSIZE:<parameter whose guard fires>.
# lint checks them in Verilator, synth in Yosys; each must fail with that guard's own message.
GUARD_CASES = 1:4:ASIZE 4:0:DSIZE

# Static checks on the RTL alone, at ASIZE:DSIZE and at the smallest formal size 2:4 (where the
# full-flag slice [ASIZE-2:0] is one bit); then every GUARD_CASES size must be rejected.
LINT_CFGS   = $(ASIZE):$(DSIZE) 2:4
lint: ## [M1] Verilator -Wall at ASIZE:DSIZE and 2:4; ASIZE=1 and DSIZE=0 must be rejected
	@mkdir -p $(OUT)/lint
	@set -e; for c in $(LINT_CFGS); do \
	  cmd="verilator --lint-only -Wall $(VLT_GUARD) -GASIZE=$${c%:*} -GDSIZE=$${c#*:} $(DUT_SRCS)"; \
	  echo "+ $$cmd"; $$cmd; \
	done
	@for c in $(GUARD_CASES); do a=$${c%%:*}; r=$${c#*:}; d=$${r%%:*}; p=$${c##*:}; \
	  log=$(OUT)/lint/reject_a$${a}_d$$d.log; \
	  cmd="verilator --lint-only -Wall $(VLT_GUARD) -GASIZE=$$a -GDSIZE=$$d $(DUT_SRCS)"; \
	  echo "+ $$cmd   # must be rejected"; \
	  if $$cmd > $$log 2>&1; then echo "lint FAIL: ASIZE=$$a DSIZE=$$d was accepted" >&2; exit 1; fi; \
	  grep -q "$$p must be >=" $$log || \
	    { echo "lint FAIL: ASIZE=$$a DSIZE=$$d rejected without the $$p guard message, see $$log" >&2; exit 1; }; \
	done
	@echo "lint PASS   repro: make lint $(REPRO_VARS)"

# Synthesizability (spec §10): the GUARD_CASES sizes must be rejected (Yosys accepted DSIZE=0
# silently before the guard existed); structural check (no undriven or multiply driven nets, no
# combinational loops); 8*(ASIZE+1)+2 async-reset flops before optimization; then synth + stat.
YOSYS_READ  = read_verilog -sv $(DUT_SRCS); chparam -set ASIZE $(ASIZE) -set DSIZE $(DSIZE) async_fifo
FLOPS       = $(shell echo $$((8 * ($(ASIZE) + 1) + 2)))
synth: ## [M1] Yosys: guards reject bad sizes, check -assert, pre-opt flop count, synth + stat
	@mkdir -p $(OUT)/synth
	@for c in $(GUARD_CASES); do a=$${c%%:*}; r=$${c#*:}; d=$${r%%:*}; p=$${c##*:}; \
	  log=$(OUT)/synth/reject_a$${a}_d$$d.log; \
	  cmd="yosys -q -p 'read_verilog -sv $(DUT_SRCS); chparam -set ASIZE $$a -set DSIZE $$d async_fifo; prep -top async_fifo'"; \
	  echo "+ $$cmd   # must be rejected"; \
	  if eval "$$cmd" > $$log 2>&1; then echo "synth FAIL: ASIZE=$$a DSIZE=$$d was accepted" >&2; exit 1; fi; \
	  grep -q "$$p must be >=" $$log || \
	    { echo "synth FAIL: ASIZE=$$a DSIZE=$$d rejected without the $$p guard message, see $$log" >&2; exit 1; }; \
	done
	yosys -q -l $(OUT)/synth/check.log -p '$(YOSYS_READ); prep -top async_fifo; check -assert'
	yosys -q -l $(OUT)/synth/flops.log -p '$(YOSYS_READ); hierarchy -top async_fifo; proc; opt_clean; simplemap t:$$adff; select -assert-count $(FLOPS) t:$$_DFF_PN0_ t:$$_DFF_PN1_'
	yosys -q -l $(OUT)/synth/synth.log -p '$(YOSYS_READ); synth -top async_fifo; tee -o $(OUT)/synth/stat.txt stat'
	@grep -E '[0-9]+ +(cells|\$$_)' $(OUT)/synth/stat.txt | sed 's/^ */  /'
	@echo "synth PASS: check -assert clean, $(FLOPS) async-reset flops before optimization   repro: make synth $(REPRO_VARS)"

# Directed non-UVM smoke test (tb/smoke/tb_smoke.sv), built once per ASIZE/DSIZE; the clock ratio
# is a run-time plusarg, so one build runs every ratio. Default: 1:3 and 3:1 (M1 Done-when).
# RATIO="w:r ..." = wclk period : rclk period; TRACE=1 writes smoke.vcd next to each run log
# (VCD, not FST: this Verilator's FST writer needs lz4.h, which the host lacks — toolchain.md).
SMOKE_BLD   = $(OUT)/smoke/build_a$(ASIZE)_d$(DSIZE)
TRACE      ?= 0
smoke: RATIO = 1:3 3:1
smoke: ## [M1] Directed smoke test at RATIO="1:3 3:1" (wclk:rclk periods); TRACE=1 for VCD
	@mkdir -p $(SMOKE_BLD)
	@cmd="verilator --binary --timing -Wall $(VLT_GUARD) --timescale 1ns/1ps --trace -j $(J) -GASIZE=$(ASIZE) -GDSIZE=$(DSIZE) --top-module tb_smoke -Mdir $(SMOKE_BLD) $(IP_ROOT)/tb/smoke/tb_smoke.sv $(DUT_SRCS)"; \
	  echo "+ $$cmd"; \
	  $$cmd > $(SMOKE_BLD)/build.log 2>&1 || { grep -E '%(Error|Warning)' $(SMOKE_BLD)/build.log | head -20; \
	    echo "smoke FAIL: build, see $(SMOKE_BLD)/build.log" >&2; exit 1; }
	@set -e; for r in $(RATIO); do \
	  d=$(OUT)/smoke/a$(ASIZE)_d$(DSIZE)_r$$(echo $$r | tr : _); mkdir -p $$d; \
	  cmd="$(SMOKE_BLD)/Vtb_smoke +RATIO=$$r$(if $(filter 1,$(TRACE)), +trace)"; \
	  echo "+ (cd $$d && $$cmd) > $$d/run.log"; \
	  rc=0; (cd $$d && $$cmd) > $$d/run.log 2>&1 || rc=$$?; \
	  grep -E '^SMOKE (config|PASS|FAIL)' $$d/run.log | sed 's/^/  /' || true; \
	  if [ $$rc -ne 0 ] || ! grep -q '^SMOKE PASS' $$d/run.log; then \
	    echo "smoke FAIL at RATIO=$$r (exit $$rc), log $$d/run.log   repro: make smoke RATIO=$$r $(REPRO_VARS) TRACE=1" >&2; \
	    exit 1; fi; \
	done
	@echo "smoke PASS at RATIO=\"$(RATIO)\"   repro: make smoke RATIO=\"$(RATIO)\" $(REPRO_VARS)"

# Verification-plan traceability (M2): the plan's structure must pass; the self-test proves the
# checker still fails on broken plans; --trace reports which planned names exist in code yet.
VPLAN      = $(IP_ROOT)/docs/vplan.md
VPLAN_CHK  = python3 $(COMMON)/scripts/vplan_check.py --vplan $(VPLAN)
vplan: ## [M2] Check docs/vplan.md structure, self-test the checker, report code traceability
	$(VPLAN_CHK) --structure
	VPLAN=$(VPLAN) python3 -m unittest discover -s $(COMMON)/scripts/tests -q
	$(VPLAN_CHK) --trace --root $(IP_ROOT) --root $(COMMON)
	@echo "vplan PASS   repro: make vplan"

# ---- UVM testbench (M3): sources in compile order (interfaces and packages, then DUT, then top);
# every testbench file is a rebuild dependency. UVM_HOME: the pinned UVM (docs/toolchain.md).
UVM_HOME   ?= $(HOME)/tools/uvm-2020-3.2/src
TB_DIR      = $(IP_ROOT)/tb/uvm
TB_PRE      = $(COMMON)/uvm/clk_rst_if.sv $(TB_DIR)/pkg/fifo_params_pkg.sv $(TB_DIR)/if/fifo_wr_if.sv \
              $(TB_DIR)/if/fifo_rd_if.sv $(TB_DIR)/pkg/fifo_tb_pkg.sv
TB_INCDIRS  = $(addprefix $(TB_DIR)/,agents/wr agents/rd env seq tests)
TB_DEPS     = $(shell find $(TB_DIR) $(COMMON)/uvm -name '*.sv' -o -name '*.svh') $(COMMON)/sim/$(SIM).mk
# One build per simulator, size and RTL source list, so M8/M9 builds of patched RTL coexist.
BUILD_TAG   = $(SIM)_a$(ASIZE)_d$(DSIZE)_$(shell echo '$(DUT_SRCS)' | md5sum | cut -c1-8)
PLUSARGS   ?=
# Code coverage (line, branch, toggle) is for the design only: no UVM, testbench or common TB code.
COV_EXCLUDE = $(UVM_HOME)/* $(TB_DIR)/* $(COMMON)/uvm/*

# Run directory name: out/.../run/<RUN>_<SEED>. RUN defaults to the test; regression entries that
# run one test with different plusargs give each its own name (regress/tests.toml `id`).
RUN        ?= $(TEST)
# Everything the simulator layer needs to build the testbench (shared by sim and sim-build).
SIM_BUILD_ARGS = TOP=tb_top SRCS="$(TB_PRE) $(DUT_SRCS) $(TB_DIR)/top/tb_top.sv" INCDIRS="$(TB_INCDIRS)" \
	  DEFINES="FIFO_ASIZE=$(ASIZE) FIFO_DSIZE=$(DSIZE)" DEPS="$(TB_DEPS) $(DUT_SRCS)" \
	  BUILD_DIR=$(OUT)/build/$(BUILD_TAG) J=$(J) UVM_HOME=$(UVM_HOME) COV_EXCLUDE="$(COV_EXCLUDE)"

# One UVM test at one seed: build once per configuration, run in out/.../run/<RUN>_<seed>/,
# judge the log, print the reproduction command. Delegates to common/sim/<SIM>.mk.
# NO_BUILD=1 (used by regress.py after its single build) runs the existing binary only.
sim: ## [M3] One UVM test: TEST=<t> SEED=<s> SIM=<sim> [PLUSARGS='+X=1 ...']; +trace for VCD
	@test -n "$(TEST)" || { echo "make sim: TEST=<test> is required, e.g. TEST=smoke_test" >&2; exit 2; }
	@test "$(SEED)" -ge 1 2>/dev/null || { echo "make sim: SEED must be an integer >= 1" >&2; exit 2; }
	@$(MAKE) --no-print-directory -f $(COMMON)/sim/$(SIM).mk run $(SIM_BUILD_ARGS) \
	  RUN_DIR=$(OUT)/run/$(RUN)_$(SEED) TEST=$(TEST) SEED=$(SEED) PLUSARGS="$(PLUSARGS)" \
	  REPRO="make sim TEST=$(TEST) SEED=$(SEED) SIM=$(SIM) $(REPRO_VARS)$(if $(PLUSARGS), PLUSARGS='$(PLUSARGS)')$(if $(filter-out $(TEST),$(RUN)), RUN=$(RUN))"

# Build the UVM testbench for this configuration without running a test (regress.py's one build).
sim-build: ## [M5] Build the UVM testbench only (SIM=, ASIZE=, DSIZE=, RTL_DIR= as for sim)
	@$(MAKE) --no-print-directory -f $(COMMON)/sim/$(SIM).mk build $(SIM_BUILD_ARGS)

# Many tests x many seeds in parallel, driven by regress/tests.toml (sign-off SO-2): one build,
# then every run; results in $(OUT)/regress/, merged coverage in $(OUT)/cov/. N= replaces the
# default seed count (entries with their own `seeds` keep it), TESTS="a b" picks entries by id,
# RECHECK=k reruns k random runs and diffs their logs.
N        ?=
TESTS    ?=
RECHECK  ?= 0
REGRESS   = python3 $(COMMON)/scripts/regress.py --tests $(IP_ROOT)/regress/tests.toml --sim $(SIM) \
            --out $(OUT) --vars "$(REPRO_VARS)"
REGRESS_REPRO = make regress SIM=$(SIM) $(REPRO_VARS)$(if $(N), N=$(N))$(if $(TESTS), TESTS="$(TESTS)")
# Afterwards docs/vplan_status.md is rewritten from the merged coverage (vplan_check --annotate);
# the target's exit status stays the regression's.
VPLAN_STATUS = $(VPLAN_CHK) --annotate --cov $(OUT)/cov/functional.json --results $(OUT)/regress/results.json
regress: ## [M5] Parallel regression from regress/tests.toml: [N=seeds] [TESTS="id ..."] [RECHECK=k]
	@rc=0; $(REGRESS) -j $(J) $(if $(N),--seeds $(N)) $(if $(TESTS),--only $(TESTS)) \
	  $(if $(filter-out 0,$(RECHECK)),--recheck $(RECHECK)) --repro '$(REGRESS_REPRO)' || rc=$$?; \
	  if [ $$rc -ne 2 ]; then $(VPLAN_STATUS) || true; fi; exit $$rc

# Merges the per-run coverage databases of the last regression into one report (sign-off SO-1),
# then rewrites docs/vplan_status.md.
cov: ## [M5] Re-merge the last regression's coverage into $(OUT)/cov/ and update docs/vplan_status.md
	@rc=0; $(REGRESS) --merge-only --repro 'make cov SIM=$(SIM) $(REPRO_VARS)' || rc=$$?; \
	  if [ $$rc -ne 2 ]; then $(VPLAN_STATUS) || true; fi; exit $$rc

# Formal verification of the RTL properties at a small ASIZE (sign-off SO-3).
formal: ## [M7] SymbiYosys: TASK=<bmc|prove|cover|pdr> ASIZE=<n>
	$(call stub,M7,sby -f -d $(OUT)/formal/$(TASK)_a$(ASIZE) $(IP_ROOT)/formal/async_fifo.sby $(TASK))

# Applies each planted bug patch and records which method catches it (report Q-1).
bugs: ## [M8] Planted-bug detection matrix -> docs/bug_matrix.md
	$(call stub,M8,python3 $(COMMON)/scripts/bug_matrix.py --bugs $(IP_ROOT)/bugs)

# Mutation testing: how many automatic RTL mutations the checks detect (report Q-2).
mcy: ## [M9] MCY mutation coverage
	$(call stub,M9,cd $(OUT)/mcy && mcy init && mcy run -j$(J) && mcy status)

# Collects every summary under out/ into the reviewer-facing results page.
results: ## [M10] Build docs/results.md from out/
	$(call stub,M10,python3 $(COMMON)/scripts/make_results.py --ip $(IP))

# Deletes everything this block generated (all of it lives under OUT).
clean: ## [M0] Remove this block's generated output
	rm -rf $(OUT)
