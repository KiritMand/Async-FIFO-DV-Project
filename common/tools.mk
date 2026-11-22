# common/tools.mk — toolchain location, shared by every block Makefile.
# Pinned release and versions: docs/toolchain.md. Override OSS_CAD_SUITE for CI or
# another install; set it empty to use whatever is already on PATH.

# Prepend the suite's bin/ to PATH for all recipes, but only if the install really exists
# (so a machine without it falls back to tools already on PATH instead of breaking).
OSS_CAD_SUITE ?= $(HOME)/tools/oss-cad-suite
ifneq ($(OSS_CAD_SUITE),)
ifneq ($(wildcard $(OSS_CAD_SUITE)/bin/yosys),)
export PATH := $(OSS_CAD_SUITE)/bin:$(PATH)
endif
endif
