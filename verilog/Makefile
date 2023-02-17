include ../Makefile.base

TARGETFILE ?= ../src/QP.bsv
TOP ?= mkTransportLayerRDMA

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS4TEST) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOP) $(TARGETFILE)

link: compile
	bsc -sim $(BLUESIMFLAGS) $(DIRFLAGS4TEST) $(RECOMPILEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -e $(TOP) -o $(SIMEXE)

verilog: link
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(RECOMPILEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)

clean:
	rm -rf $(BUILDDIR)

.PHONY: compile link verilog clean
.DEFAULT_GOAL := verilog
