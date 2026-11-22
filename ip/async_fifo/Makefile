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
.PHONY: help lint synth smoke sim regress cov formal bugs mcy results clean

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

# Static checks on the RTL alone: catches width/latch/unused-signal mistakes before simulating.
lint: ## [M1] Lint the RTL (Verilator -Wall)
	$(call stub,M1,verilator --lint-only -Wall -GASIZE=$(ASIZE) -GDSIZE=$(DSIZE) $(DUT_SRCS))

# Proves the RTL is synthesizable and shows its flop/gate count.
synth: ## [M1] Yosys synthesis + stat (checks synthesizability)
	$(call stub,M1,yosys -p 'read_verilog -sv $(DUT_SRCS); chparam -set ASIZE $(ASIZE) async_fifo; synth -top async_fifo; stat')

# Quick directed test without UVM, for first bring-up of the RTL at a given clock ratio.
smoke: ## [M1] Directed non-UVM smoke test (RATIO=w:r)
	$(call stub,M1,<sim> tb/smoke/tb_smoke.sv $(DUT_SRCS) +RATIO=$(RATIO) -> $(OUT)/smoke/)

# One UVM test at one seed; delegates to the simulator layer in common/sim/<SIM>.mk.
sim: ## [M3] One UVM test: TEST=<t> SEED=<s> SIM=<sim>
	$(call stub,M3,make -f $(COMMON)/sim/$(SIM).mk TEST=$(TEST) SEED=$(SEED) -> $(OUT)/run/$(TEST)_$(SEED)/)

# Many tests x many seeds in parallel, driven by regress/tests.toml (sign-off SO-2).
regress: ## [M5] Parallel regression from regress/tests.toml
	$(call stub,M5,python3 $(COMMON)/scripts/regress.py --tests $(IP_ROOT)/regress/tests.toml --sim $(SIM) -j $(J))

# Merges per-run coverage databases into one report (sign-off SO-1).
cov: ## [M5] Merge coverage databases and write the report
	$(call stub,M5,python3 $(COMMON)/scripts/regress.py --merge-only --sim $(SIM) -> $(OUT)/cov/)

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
