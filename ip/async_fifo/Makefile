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

# ---- Properties (M6): the white-box file the RTL includes under ASYNC_FIFO_PROPS, and the e2e
# checker. PROPS_DIR stays the real rtl/ when RTL_DIR points at patched RTL, so a planted bug is
# judged by the original properties (a patched directory must not carry its own copy).
PROPS_DIR ?= $(IP_ROOT)/rtl
PROPS_SVH  = $(PROPS_DIR)/async_fifo_props.svh
E2E_SRC    = $(IP_ROOT)/sva/async_fifo_e2e_props.sv
# Simulation only (decision D2): concurrent twins of the e2e assertions, bound into the e2e checker.
CONC_SRC   = $(IP_ROOT)/sva/async_fifo_sva_concurrent.sv
# The property blocks sample each reset level at clock edges (F01), which Verilator's -Wall style
# warning SYNCASYNCNET reports at the RTL's reset ports; property code is never synthesized.
PROPS_VLT  = +define+ASYNC_FIFO_PROPS +incdir+$(PROPS_DIR) -Wno-SYNCASYNCNET
# SVA=0 (M8): the UVM build without assertions (Verilator --no-assert via the sim layer's ASSERT=0):
# white-box, e2e and asm_ checks are gone, the scoreboard and test checks stay. This is the bug
# matrix's scoreboard-only column; it has its own build directory and is never a sign-off build.
SVA       ?= 1
# MCY=1 (M9): the UVM build for mutation testing. DUT_SRCS is then MCY's mutated netlist (Yosys
# Verilog at fixed sizes with a mutsel port, toolchain T20): tb_top drops the parameter overrides
# and drives mutsel from +mutsel=; the netlist's WIDTHEXPAND warnings are waived for that file
# only (mcy/verilator_netlist.vlt); functional coverage only (code coverage of a netlist means
# nothing, and the build is faster). Own build directory; never a sign-off build.
MCY       ?= 0
MCY_VLT    = $(IP_ROOT)/mcy/verilator_netlist.vlt

# ---- Run controls: which simulator/test/seed/clock ratio/formal task; J = parallel jobs.
SIM       ?= verilator# DEC-001 (docs/decisions.md)
TEST      ?=
SEED      ?= 1
RATIO     ?= 1:1
TASK      ?= prove
J         ?= $(shell nproc 2>/dev/null || echo 4)

# ---- Parameters: per-flow defaults (sim ASIZE=4 DSIZE=8; formal ASIZE=3 DSIZE=4; MCY ASIZE=2 DSIZE=4).
# Target-specific `?=` so a command-line ASIZE=/DSIZE= still wins.
SIM_FLOWS    := lint synth cdc smoke sva-neg sim sim-build regress cov bugs
FORMAL_FLOWS := formal formal-audit formal-signoff
$(SIM_FLOWS):    ASIZE ?= 4
$(SIM_FLOWS):    DSIZE ?= 8
$(FORMAL_FLOWS): ASIZE ?= 3
$(FORMAL_FLOWS): DSIZE ?= 4
# MCY runs at the vplan's mutation size (vplan §1: ASIZE = 2, DSIZE = 4).
mcy mcy-pick: ASIZE ?= 2
mcy mcy-pick: DSIZE ?= 4

# stub,<module>,<planned command>: placeholder recipe for targets not built yet. Prints the
# planned command, names the module that builds it, and exits 2 so it never counts as a pass.
define stub
@echo "+ $(2)"
@echo "make $@: not implemented yet — built in $(1) (docs/PROJECT_PLAN.md §6)." >&2
@exit 2
endef

.DEFAULT_GOAL := help
.PHONY: help lint synth cdc smoke sva-neg vplan sim sim-build regress cov formal formal-audit formal-signoff formal-figures bugs mcy-pick mcy results clean

# Self-documenting help: lists every rule that has a "## " description, plus variables.
help: ## [M0] List targets and variables
	@echo "async_fifo targets (run from repo root or ip/async_fifo):"
	@grep -E '^[a-z-]+: ##' $(THIS_MK) | sed -E 's/^([a-z-]+): ## /  \1\t/' | expand -t 12
	@echo ""
	@echo "Variables (current value):"
	@echo "  RTL_DIR=$(RTL_DIR)"
	@echo "  DUT_SRCS=$(DUT_SRCS)"
	@echo "  SIM=$(SIM)  TEST=$(TEST)  SEED=$(SEED)  RATIO=$(RATIO)  J=$(J)  SVA=$(SVA) (0: UVM build without assertions)  MCY=$(MCY) (1: mutated-netlist build)"
	@echo "  TASK=$(TASK) (bmc|prove|cover|pdr|audit_a0N|prove_noinv|pdr_noinv)  EXPECT=pass|fail|nopass|any  TIMEOUT=<s>"
	@echo "  ASIZE/DSIZE: sim 4/8, formal 3/4, mcy 2/4 unless set; FORMAL_SIZES=\"$(FORMAL_SIZES)\" for formal-signoff"
	@echo "  MCY_SIZE=$(MCY_SIZE) MCY_SEED=$(MCY_SEED) MCY_SLOTS=$(MCY_SLOTS) (mcy: mutations, seed, concurrent runs)"
	@echo "  OUT=$(OUT)"
	@echo "  OSS_CAD_SUITE=$(OSS_CAD_SUITE)"

# ---- Shared by the RTL flows below.
# -Werror-USERERROR keeps the RTL's parameter guards fatal in every Verilator build (toolchain T7).
VLT_GUARD  := -Werror-USERERROR
# Variables for the printed repro line: sizes, plus any RTL or OUT override given on the command
# line (an RTL variant built into its own OUT must rerun there, not over the default runs).
REPRO_VARS  = ASIZE=$(ASIZE) DSIZE=$(DSIZE)$(if $(filter command line,$(origin RTL_DIR)), RTL_DIR=$(RTL_DIR))$(if $(filter command line,$(origin DUT_SRCS)), DUT_SRCS='$(DUT_SRCS)')$(if $(filter command line,$(origin OUT)), OUT=$(OUT))$(if $(filter command line,$(origin SVA)), SVA=$(SVA))$(if $(filter 1,$(MCY)), MCY=1)
# Illegal sizes the RTL guards must reject (spec §2), as ASIZE:DSIZE:<parameter whose guard fires>.
# lint checks them in Verilator, synth in Yosys; each must fail with that guard's own message.
GUARD_CASES = 1:4:ASIZE 4:0:DSIZE

# Static checks on the RTL alone, at ASIZE:DSIZE and at the smallest formal size 2:4 (where the
# full-flag slice [ASIZE-2:0] is one bit); then every GUARD_CASES size must be rejected; then (M6)
# the properties: the RTL with ASYNC_FIFO_PROPS and the e2e checker (with its bound concurrent
# twins) under Verilator -Wall, and the RTL and e2e checker read by Yosys in formal mode (the props
# instantiate the checker under FORMAL since M7; toolchain T15; the concurrent file is simulation
# only, T6).
LINT_CFGS   = $(ASIZE):$(DSIZE) 2:4
lint: ## [M1/M6] Verilator -Wall (RTL, RTL+props, e2e checker), Yosys -formal parse; ASIZE=1, DSIZE=0 rejected
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
	@set -e; for c in $(LINT_CFGS); do a=$${c%:*}; d=$${c#*:}; \
	  cmd="verilator --lint-only -Wall $(VLT_GUARD) $(PROPS_VLT) -GASIZE=$$a -GDSIZE=$$d $(DUT_SRCS)"; \
	  echo "+ $$cmd"; $$cmd; \
	  cmd="verilator --lint-only -Wall --timing -Wno-SYNCASYNCNET -GASIZE=$$a -GDSIZE=$$d --top-module async_fifo_e2e_props $(E2E_SRC) $(CONC_SRC)"; \
	  echo "+ $$cmd"; $$cmd; \
	  y="read_verilog -sv -formal -D ASYNC_FIFO_PROPS -I $(PROPS_DIR) $(E2E_SRC) $(DUT_SRCS); chparam -set ASIZE $$a -set DSIZE $$d async_fifo; prep -top async_fifo"; \
	  echo "+ yosys -q -p '$$y'"; yosys -q -l $(OUT)/lint/yosys_props_a$${a}_d$$d.log -p "$$y" > /dev/null; \
	  y="read_verilog -sv -formal $(E2E_SRC); chparam -set ASIZE $$a -set DSIZE $$d async_fifo_e2e_props; prep -top async_fifo_e2e_props"; \
	  echo "+ yosys -q -p '$$y'"; yosys -q -l $(OUT)/lint/yosys_e2e_a$${a}_d$$d.log -p "$$y" > /dev/null; \
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

# Structural CDC check (M8 step 5): the Yosys netlist as a flop graph, checked by
# common/scripts/cdc_check.py against R1 (no logic on a crossing), R2 (stage 1 feeds only stage 2)
# and R3 (each flop reset by its own domain's reset); domains, port domains and the waiver (the
# memory read path, vplan §8) are in constraints/cdc.toml.
CDC_CFG = $(IP_ROOT)/constraints/cdc.toml
cdc: ## [M8] Structural CDC check: R1 no logic on a crossing, R2 two stages, R3 destination reset
	python3 $(COMMON)/scripts/cdc_check.py --rtl $(DUT_SRCS) --config $(CDC_CFG) --param ASIZE=$(ASIZE) \
	  --param DSIZE=$(DSIZE) --out $(OUT)/cdc --repro 'make cdc $(REPRO_VARS)'

# Directed non-UVM smoke test (tb/smoke/tb_smoke.sv), built once per ASIZE/DSIZE; the clock ratio
# is a run-time plusarg, so one build runs every ratio. Default: 1:3 and 3:1 (M1 Done-when).
# The DUT carries its white-box properties (M6). The e2e checker is not attached: this bench
# drives at falling edges and releases resets 1 ns after an edge, which the A02/A03 testbench
# checks would reject (they hold the UVM bench to the formal assumptions).
# RATIO="w:r ..." = wclk period : rclk period; TRACE=1 writes smoke.vcd next to each run log
# (VCD, not FST: this Verilator's FST writer needs lz4.h, which the host lacks — toolchain.md).
SMOKE_BLD   = $(OUT)/smoke/build_a$(ASIZE)_d$(DSIZE)
TRACE      ?= 0
smoke: RATIO = 1:3 3:1
smoke: ## [M1] Directed smoke test at RATIO="1:3 3:1" (wclk:rclk periods); TRACE=1 for VCD
	@mkdir -p $(SMOKE_BLD)
	@cmd="verilator --binary --timing -Wall $(VLT_GUARD) $(PROPS_VLT) --timescale 1ns/1ps --trace -j $(J) -GASIZE=$(ASIZE) -GDSIZE=$(DSIZE) --top-module tb_smoke -Mdir $(SMOKE_BLD) $(IP_ROOT)/tb/smoke/tb_smoke.sv $(DUT_SRCS)"; \
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

# Assertion negative tests (M6 step 4): tb/sva_neg/tb_sva_neg.sv, with the white-box properties in
# the DUT, the e2e checker on its ports and its concurrent twins bound in, built once per size;
# sva_neg.py then runs the clean case and one +BREAK=<label> case per simulation assertion of the
# vplan (error limit raised, so every label failing at the first failing time is seen), checks that
# each concurrent twin fails with its immediate twin, and writes the results page. Default
# warning set plus -Wno-MULTIDRIVEN: each `force` is a second writer of a DUT variable by design
# (make lint holds the RTL and properties to -Wall). The page is written only for the real RTL.
SVA_NEG_BLD = $(OUT)/sva_neg/build_a$(ASIZE)_d$(DSIZE)
SVA_NEG_DOC = $(if $(filter command line,$(origin RTL_DIR) $(origin DUT_SRCS)),,--doc $(IP_ROOT)/docs/sva_negative_tests.md)
sva-neg: ## [M6] Break each assertion on purpose (force or bad stimulus); each must fire
	@mkdir -p $(SVA_NEG_BLD)
	@cmd="verilator --binary --timing $(VLT_GUARD) -Wno-MULTIDRIVEN $(PROPS_VLT) --timescale 1ns/1ps --trace -j $(J) -GASIZE=$(ASIZE) -GDSIZE=$(DSIZE) --top-module tb_sva_neg -Mdir $(SVA_NEG_BLD) $(IP_ROOT)/tb/sva_neg/tb_sva_neg.sv $(DUT_SRCS) $(E2E_SRC) $(CONC_SRC)"; \
	  echo "+ $$cmd"; \
	  $$cmd > $(SVA_NEG_BLD)/build.log 2>&1 || { grep -E '%(Error|Warning)' $(SVA_NEG_BLD)/build.log | head -20; \
	    echo "sva-neg FAIL: build, see $(SVA_NEG_BLD)/build.log" >&2; exit 1; }
	python3 $(COMMON)/scripts/sva_neg.py --exe $(SVA_NEG_BLD)/Vtb_sva_neg --vplan $(VPLAN) \
	  --patterns $(COMMON)/sim/verilator.patterns --out $(OUT)/sva_neg/a$(ASIZE)_d$(DSIZE) $(SVA_NEG_DOC) \
	  --twins $(CONC_SRC) --config "ASIZE=$(ASIZE) DSIZE=$(DSIZE)" --sim-args '+verilator+error+limit+1000' \
	  --repro 'make sva-neg $(REPRO_VARS)'

# Verification-plan traceability (M2): the plan's structure must pass; the self-test proves the
# checker still fails on broken plans; --trace --strict requires every planned name in the code
# (formal labels included since M7).
VPLAN      = $(IP_ROOT)/docs/vplan.md
VPLAN_CHK  = python3 $(COMMON)/scripts/vplan_check.py --vplan $(VPLAN)
vplan: ## [M2] Check docs/vplan.md structure, self-test the checker, report code traceability
	$(VPLAN_CHK) --structure
	VPLAN=$(VPLAN) python3 -m unittest discover -s $(COMMON)/scripts/tests -q
	$(VPLAN_CHK) --trace --strict --root $(IP_ROOT) --root $(COMMON)
	@echo "vplan PASS   repro: make vplan"

# ---- UVM testbench (M3): sources in compile order (interfaces and packages, then DUT, then top);
# every testbench file is a rebuild dependency. UVM_HOME: the pinned UVM (docs/toolchain.md).
UVM_HOME   ?= $(HOME)/tools/uvm-2020-3.2/src
TB_DIR      = $(IP_ROOT)/tb/uvm
TB_PRE      = $(COMMON)/uvm/clk_rst_if.sv $(TB_DIR)/pkg/fifo_params_pkg.sv $(TB_DIR)/if/fifo_wr_if.sv \
              $(TB_DIR)/if/fifo_rd_if.sv $(TB_DIR)/pkg/fifo_tb_pkg.sv
TB_INCDIRS  = $(addprefix $(TB_DIR)/,agents/wr agents/rd env seq tests)
TB_DEPS     = $(shell find $(TB_DIR) $(COMMON)/uvm -name '*.sv' -o -name '*.svh') $(COMMON)/sim/$(SIM).mk
# One build per simulator, size, assertion setting and RTL source list, so M8/M9 builds of
# patched RTL coexist.
BUILD_TAG   = $(SIM)_a$(ASIZE)_d$(DSIZE)$(if $(filter 0,$(SVA)),_nosva)$(if $(filter 1,$(MCY)),_mcy)_$(shell echo '$(DUT_SRCS)' | md5sum | cut -c1-8)
PLUSARGS   ?=
# Code coverage (line, branch, toggle) is for the design only: no UVM, testbench, common TB or
# property code. Cover statements in the excluded property files still count (toolchain T14).
COV_EXCLUDE = $(UVM_HOME)/* $(TB_DIR)/* $(COMMON)/uvm/* $(IP_ROOT)/sva/* $(PROPS_SVH)

# Run directory name: out/.../run/<RUN>_<SEED>. RUN defaults to the test; regression entries that
# run one test with different plusargs give each its own name (regress/tests.toml `id`).
RUN        ?= $(TEST)
# Everything the simulator layer needs to build the testbench (shared by sim and sim-build).
# Assertions are always on (M6, SO-2): the RTL is built with ASYNC_FIFO_PROPS and tb_top holds the
# e2e checker; assertions and cover statements are on by default in this Verilator (toolchain T14).
SIM_BUILD_ARGS = TOP=tb_top SRCS="$(TB_PRE) $(if $(filter 1,$(MCY)),$(MCY_VLT)) $(DUT_SRCS) $(E2E_SRC) $(CONC_SRC) $(TB_DIR)/top/tb_top.sv" \
	  INCDIRS="$(TB_INCDIRS) $(PROPS_DIR)" \
	  DEFINES="FIFO_ASIZE=$(ASIZE) FIFO_DSIZE=$(DSIZE) ASYNC_FIFO_PROPS$(if $(filter 1,$(MCY)), MCY)" \
	  DEPS="$(TB_DEPS) $(DUT_SRCS) $(PROPS_SVH) $(E2E_SRC) $(CONC_SRC)" \
	  BUILD_DIR=$(OUT)/build/$(BUILD_TAG) J=$(J) UVM_HOME=$(UVM_HOME) COV_EXCLUDE="$(COV_EXCLUDE)" \
	  ASSERT=$(if $(filter 0,$(SVA)),0,1) $(if $(filter 1,$(MCY)),COV_TYPES=user)

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
# the target's exit status stays the regression's. The formal sign-off (M7) is added when its
# JSON exists; the test runs in the shell because make expands a whole recipe before running it,
# so $(wildcard) would miss a file the same recipe has just written (formal-signoff).
# Only the sign-off configuration may rewrite the committed status page: the real RTL with
# assertions at the sign-off size 4/8 in the default OUT. A regression of patched RTL
# (RTL_DIR/DUT_SRCS on the command line), of an SVA=0 build, at another size (M9 runs ASIZE=2) or
# into another OUT skips it.
REAL_RTL     = $(if $(filter command line,$(origin RTL_DIR) $(origin DUT_SRCS) $(origin SVA) $(origin OUT)),,$(if $(filter 4:8,$(ASIZE):$(DSIZE)),1))
VPLAN_STATUS = $(VPLAN_CHK) --annotate --cov $(OUT)/cov/functional.json --results $(OUT)/regress/results.json \
               `test -f $(OUT)/formal/signoff.json && echo --formal $(OUT)/formal/signoff.json`
regress: ## [M5] Parallel regression from regress/tests.toml: [N=seeds] [TESTS="id ..."] [RECHECK=k]
	@rc=0; $(REGRESS) -j $(J) $(if $(N),--seeds $(N)) $(if $(TESTS),--only $(TESTS)) \
	  $(if $(filter-out 0,$(RECHECK)),--recheck $(RECHECK)) --repro '$(REGRESS_REPRO)' || rc=$$?; \
	  if [ $$rc -ne 2 ] && [ -n "$(REAL_RTL)" ]; then $(VPLAN_STATUS) || true; fi; exit $$rc

# Merges the per-run coverage databases of the last regression into one report (sign-off SO-1),
# then rewrites docs/vplan_status.md.
cov: ## [M5] Re-merge the last regression's coverage into $(OUT)/cov/ and update docs/vplan_status.md
	@rc=0; $(REGRESS) --merge-only --repro 'make cov SIM=$(SIM) $(REPRO_VARS)' || rc=$$?; \
	  if [ $$rc -ne 2 ] && [ -n "$(REAL_RTL)" ]; then $(VPLAN_STATUS) || true; fi; exit $$rc

# ---- Formal (M7, sign-off SO-3): SymbiYosys on formal/async_fifo.sby. formal_run.py writes a
# per-size copy (out/<ip>/formal/a<ASIZE>_d<DSIZE>/) with absolute sources, so RTL_DIR/DUT_SRCS
# reach formal (one DUT file), runs SBY and judges the log: the verdict must match EXPECT, and a
# Yosys "implicitly declared" or "no driver" warning fails the run (toolchain T18).
# TIMEOUT=<s> caps each run (DEC-011 D4); SBY_OPT="<tag>: <option> <value>" replaces one [options]
# line (e.g. SBY_OPT="cover: depth 170" for ASIZE=4, whose two wraps need more steps).
FORMAL_SBY   = $(IP_ROOT)/formal/async_fifo.sby
FORMAL_SIZES ?= 2 3
EXPECT       ?= pass
FORMAL_RUN   = python3 $(COMMON)/scripts/formal_run.py --sby $(FORMAL_SBY) --out $(OUT)/formal --dsize $(DSIZE) \
               --src async_fifo.sv=$(DUT_SRCS) --src async_fifo_props.svh=$(PROPS_SVH) \
               --src async_fifo_e2e_props.sv=$(E2E_SRC) $(if $(TIMEOUT),--timeout $(TIMEOUT)) \
               $(if $(SBY_OPT),--opt "$(SBY_OPT)")
FORMAL_ONE   = $(if $(word 2,$(DUT_SRCS)),$(error formal: DUT_SRCS must name one file, got '$(DUT_SRCS)'))

# One SBY task at one size.
formal: ## [M7] SymbiYosys: TASK=<bmc|prove|cover|pdr|...> ASIZE=<n> [EXPECT=pass|fail|nopass|any] [TIMEOUT=s]
	$(FORMAL_ONE)$(FORMAL_RUN) --run $(TASK):$(ASIZE):$(EXPECT) \
	  --repro 'make formal TASK=$(TASK) EXPECT=$(EXPECT) $(REPRO_VARS)$(if $(TIMEOUT), TIMEOUT=$(TIMEOUT))$(if $(SBY_OPT), SBY_OPT="$(SBY_OPT)")'

# Assumption audit (vplan §5): each task drops one active assumption. A01 and A05 must fail (bmc,
# spec properties only, every failing label listed); A02 is recorded (k-induction without it: a
# pass means it is unnecessary, and the ledger says so for the owner to decide).
formal-audit: ## [M7] Drop each assumption in turn (A01, A05 must fail; A02 recorded) at ASIZE=<n>
	$(FORMAL_ONE)$(FORMAL_RUN) --run audit_a01:$(ASIZE):fail audit_a02:$(ASIZE):any audit_a05:$(ASIZE):fail \
	  --summary $(OUT)/formal/audit_a$(ASIZE).md --repro 'make formal-audit $(REPRO_VARS)'

# SO-3 sign-off set at every FORMAL_SIZES size: bmc, k-induction, cover, PDR; then the audit and
# the no-invariant cross-checks (recorded). Writes out/<ip>/formal/signoff.md and .json, then
# refreshes docs/vplan_status.md (SO-3) if a merged coverage database exists.
formal-signoff: ## [M7] SO-3: bmc/prove/cover/pdr at FORMAL_SIZES, audit + no-invariant checks -> signoff.md
	$(FORMAL_ONE)$(FORMAL_RUN) \
	  --run $(foreach a,$(FORMAL_SIZES),bmc:$(a) prove:$(a) cover:$(a) pdr:$(a)) \
	        $(foreach a,$(FORMAL_SIZES),audit_a01:$(a):fail audit_a02:$(a):any audit_a05:$(a):fail prove_noinv:$(a):any pdr_noinv:$(a):any) \
	  --summary $(OUT)/formal/signoff.md \
	  --repro 'make formal-signoff FORMAL_SIZES="$(FORMAL_SIZES)" $(REPRO_VARS)$(if $(TIMEOUT), TIMEOUT=$(TIMEOUT))'
	@if [ -f $(OUT)/cov/functional.json ]; then $(VPLAN_STATUS); fi

# Cover-trace figures for the README (DEC-011 D5): run cover, then draw the traces that reached
# cov_F12_empty_after_full (fill -> full -> drain) and cov_F13_two_wraps (pointer wrap) as SVG
# into docs/figures/ (committed). ASIZE=2 by default: the two-wrap trace is 74 steps at ASIZE=3.
FIG_DIR       = $(IP_ROOT)/docs/figures
FIG_SUMMARY   = $(OUT)/formal/a$(ASIZE)_d$(DSIZE)/cover/summary.json
FIG_TRACE     = $$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["workdir"]+"/"+d["cover_traces"][sys.argv[2]])' $(FIG_SUMMARY) $(1))
FIG_SIGS_FILL = async_fifo.wclk async_fifo.wrst_n async_fifo.winc async_fifo.wfull async_fifo.wbin \
                async_fifo.rclk async_fifo.rrst_n async_fifo.rinc async_fifo.rempty async_fifo.rbin p_e2e.fill
FIG_SIGS_WRAP = async_fifo.wclk async_fifo.winc async_fifo.wbin async_fifo.wptr async_fifo.rclk async_fifo.rinc \
                async_fifo.rbin async_fifo.rptr p_e2e.fill p_e2e.rd_total
VCD2SVG       = python3 $(COMMON)/scripts/vcd2svg.py
formal-figures: ASIZE ?= 2
formal-figures: DSIZE ?= 4
formal-figures: ## [M7] Cover traces (fill-full-drain, pointer wrap) as SVG in docs/figures/ (ASIZE=2)
	$(FORMAL_ONE)$(FORMAL_RUN) --run cover:$(ASIZE) --repro 'make formal-figures $(REPRO_VARS)'
	@mkdir -p $(FIG_DIR)
	$(VCD2SVG) $(call FIG_TRACE,cov_F12_empty_after_full) --step 10 --svg $(FIG_DIR)/formal_fill_full_drain_a$(ASIZE).svg \
	  --title "Formal cover cov_F12_empty_after_full: fill -> full -> drain (ASIZE=$(ASIZE), DSIZE=$(DSIZE)); one column per formal step" \
	  --label p_e2e.fill="fill (checker)" $(FIG_SIGS_FILL)
	$(VCD2SVG) $(call FIG_TRACE,cov_F13_two_wraps) --step 10 --svg $(FIG_DIR)/formal_pointer_wrap_a$(ASIZE).svg \
	  --title "Formal cover cov_F13_two_wraps: both pointers wrap twice (ASIZE=$(ASIZE), DSIZE=$(DSIZE)); one column per formal step" \
	  --label p_e2e.fill="fill (checker)" --label p_e2e.rd_total="reads (saturating)" $(FIG_SIGS_WRAP)
	@echo "formal-figures PASS: $(FIG_DIR)/formal_*_a$(ASIZE).svg   repro: make formal-figures $(REPRO_VARS)"

# Planted-bug detection matrix (M8, report Q-1): bug_matrix.py applies each bugs/*.patch to a copy
# of rtl-v1 under $(OUT)/bugs/<id>/, runs static checks (lint, synth, cdc), the bugs.toml subset of the
# regression without (SVA=0) and with assertions, and formal (bmc_bugs, prove, cover), then writes
# docs/bug_matrix.md: actual versus prediction. BUGS="base B03" picks ids, METHODS="static sim_sb
# sim_sva formal" picks parts, REPORT_ONLY=1 rebuilds the page from saved results. A full run is
# about 2.5 h (26 UVM builds); fails if the baseline is not clean, a result is missing or stale, or
# a difference from a prediction is unexplained.
BUGS        ?=
METHODS     ?=
REPORT_ONLY ?= 0
BUGS_REPRO   = make bugs$(if $(BUGS), BUGS="$(BUGS)")$(if $(METHODS), METHODS="$(METHODS)")$(if $(filter 1,$(REPORT_ONLY)), REPORT_ONLY=1)
bugs: ## [M8] Planted-bug matrix -> docs/bug_matrix.md [BUGS="base B03"] [METHODS="static sim_sb sim_sva formal"] [REPORT_ONLY=1]
	python3 $(COMMON)/scripts/bug_matrix.py --ip-root $(IP_ROOT) --out $(OUT)/bugs -j $(J) \
	  --sim-vars "ASIZE=$(ASIZE) DSIZE=$(DSIZE)" $(if $(BUGS),--only $(BUGS)) $(if $(METHODS),--methods $(METHODS)) \
	  $(if $(filter 1,$(REPORT_ONLY)),--report-only) --repro '$(BUGS_REPRO)'

# ---- Mutation testing (M9, report Q-2; DEC-014): how many automatic RTL mutations the checks
# detect. mcy/ holds the MCY template (config.mcy), the block settings (flow.toml), the miter and the
# formal harness, the simulation run list (sim_runs.toml) and the dispositions (triage.toml).
MCY_SIZE        ?= 300
MCY_SEED        ?= 1
MCY_SLOTS       ?= $(shell echo $$(( $(J) > 3 ? $(J) - 2 : 1 )))
MCY_RESUME      ?= 0
MCY_REPORT_ONLY ?= 0
MCY_BASE         = $(OUT)/mcy_base
# MCY_PROBE=<name> MCY_PROBE_VARS='SVA=0': instead of a run, re-simulate a finished project's
# mutants with those make variables and compare (e.g. what the scoreboard alone detects).
MCY_PROBE       ?=
MCY_PROBE_VARS  ?=
MCY_REPRO        = make mcy MCY_SIZE=$(MCY_SIZE) MCY_SEED=$(MCY_SEED) $(REPRO_VARS)$(if $(MCY_PROBE), MCY_PROBE=$(MCY_PROBE) MCY_PROBE_VARS='$(MCY_PROBE_VARS)')
# Only the real RTL at the planned size, seed and mutation count rewrites docs/mutation_report.md.
MCY_DOC          = $(if $(filter command line,$(origin RTL_DIR) $(origin DUT_SRCS) $(origin OUT)),,$(if $(filter 2:4:300:1,$(ASIZE):$(DSIZE):$(MCY_SIZE):$(MCY_SEED)),--doc))

# The simulation runs every mutant gets (DEC-014): a regression of the real RTL at the MCY size into
# $(MCY_BASE) (all tests.toml entries; N= changes the seed count), then cov_subset.py keeps the
# fewest runs that hit every coverage point the regression hit, at least one per entry. Writes
# mcy/sim_runs.toml (committed); the logs in $(MCY_BASE) are the baseline `make mcy` compares with.
mcy-pick: ## [M9] Regression at the MCY size, then the coverage-preserving run subset -> mcy/sim_runs.toml [N=]
	@if [ -n "$(filter command line,$(origin RTL_DIR) $(origin DUT_SRCS))" ]; then \
	  echo "mcy-pick: the run subset is picked on the real RTL only (no RTL_DIR/DUT_SRCS)" >&2; exit 2; fi
	@$(MAKE) --no-print-directory regress ASIZE=$(ASIZE) DSIZE=$(DSIZE) OUT=$(MCY_BASE) $(if $(N),N=$(N))
	python3 $(COMMON)/scripts/cov_subset.py --regress $(MCY_BASE)/regress --out $(IP_ROOT)/mcy/sim_runs.toml \
	  --repro 'make mcy-pick ASIZE=$(ASIZE) DSIZE=$(DSIZE)$(if $(N), N=$(N))'

# The MCY run (common/scripts/mcy_run.py): project under $(OUT)/mcy/, gate on the original design,
# mcy init + run, report (and docs/mutation_report.md for the planned configuration). MCY_RESUME=1
# continues an interrupted run; MCY_REPORT_ONLY=1 rebuilds the report (after editing triage.toml).
mcy: ## [M9] MCY: gate, mutants through sim/eq/formal, report [MCY_SIZE=300 MCY_SEED=1 MCY_RESUME=1 MCY_REPORT_ONLY=1]
	$(FORMAL_ONE)python3 $(COMMON)/scripts/mcy_run.py --ip-root $(IP_ROOT) --config $(IP_ROOT)/mcy/config.mcy \
	  --flow-cfg $(IP_ROOT)/mcy/flow.toml --dut $(DUT_SRCS) --asize $(ASIZE) --dsize $(DSIZE) \
	  --size $(MCY_SIZE) --seed $(MCY_SEED) --out $(OUT) -j $(J) --slots $(MCY_SLOTS) $(MCY_DOC) \
	  $(if $(filter 1,$(MCY_RESUME)),--resume) $(if $(filter 1,$(MCY_REPORT_ONLY)),--report-only) \
	  $(if $(MCY_PROBE),--probe $(MCY_PROBE) --probe-vars '$(MCY_PROBE_VARS)') --repro "$(MCY_REPRO)"

# Collects every summary under out/ into the reviewer-facing results page.
results: ## [M10] Build docs/results.md from out/
	$(call stub,M10,python3 $(COMMON)/scripts/make_results.py --ip $(IP))

# Deletes everything this block generated (all of it lives under OUT).
clean: ## [M0] Remove this block's generated output
	rm -rf $(OUT)
