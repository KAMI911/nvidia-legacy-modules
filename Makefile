SHELL   := /bin/bash
ROOT    := $(CURDIR)
COMMON  := $(ROOT)/common
BUILDDIR?= $(ROOT)/../build
SERIES  ?= 390xx
TARGET  ?= debian13
ABI     ?=
export SOURCE_DATE_EPOCH ?= $(shell git -C $(COMMON) log -1 --format=%ct 2>/dev/null || echo 0)

.PHONY: help submodule gen build test reprotest clean
help: ; @sed -n 's/^## //p' $(MAKEFILE_LIST)

## submodule : init/refresh common/
submodule: ; git submodule update --init --remote common

## gen       : expand tools/kernels.yaml -> packaging/<series>/<target>/<abi>/
gen: ; python3 tools/gen-kernel-packages.py $(if $(SERIES),--series $(SERIES)) $(if $(ABI),--abi $(ABI))

## build     : build one per-ABI package (needs SERIES TARGET ABI)
build: gen
	@test -n "$(ABI)" || { echo "set ABI=<kernel-abi>"; exit 1; }
	mkdir -p $(BUILDDIR)
	$(COMMON)/scripts/verify-run.sh $(SERIES)
	$(COMMON)/scripts/assemble-source.sh $(SERIES) $(BUILDDIR)
	cd $(BUILDDIR) && dpkg-source --no-check -b $(ROOT)/packaging/$(SERIES)/$(TARGET)/$(ABI)
	.github/scripts/sbuild-wrap.sh $(SERIES) $(TARGET) $(ABI)

## test      : no-GPU gate for one per-ABI package
test: ; tests/run-all.sh $(SERIES) $(TARGET) $(ABI)

## clean     :
clean: ; rm -rf $(BUILDDIR) packaging/*/*/*/debian
