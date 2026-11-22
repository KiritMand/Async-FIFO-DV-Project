# Root Makefile — delegates every target to ip/$(IP)/Makefile.
# Command-line variables (SIM=, SEED=, RTL_DIR=, ...) pass through automatically.

# Which block to drive (future projects add ip/<name>/), and the targets every block offers.
IP      ?= async_fifo
IPS     := $(notdir $(wildcard ip/*))
TARGETS := help lint synth smoke sim regress cov formal bugs mcy results clean

.DEFAULT_GOAL := help
.PHONY: $(TARGETS) clean-all tools-smoke

# Forward any block target to that block's Makefile; fail clearly if IP= names no block.
$(TARGETS):
	@test -f ip/$(IP)/Makefile || { echo "No such block: ip/$(IP) (have: $(IPS))" >&2; exit 2; }
	@$(MAKE) --no-print-directory -C ip/$(IP) $@

# `make help` prints this repo-level banner first, then the block's own help.
help: _help_banner
_help_banner:
	@echo "Block: IP=$(IP)   (available: $(IPS))"
	@echo "Repo targets:"
	@echo "  tools-smoke   rerun toolchain experiments tools_smoke/T1..T7 (T=\"T1 T3\" for a subset)"
	@echo "  clean-all     remove all of out/"
	@echo ""
.PHONY: _help_banner

# Toolchain regression: rerun the M0 capability experiments (required after any tool upgrade).
tools-smoke:
	tools_smoke/run_all.sh $(T)

# Remove all generated output for every block.
clean-all:
	rm -rf out
