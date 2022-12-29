include ../Makefile.base

SRCFILE ?= QP.bsv
TOP ?= mkQP

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS4SRC) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOP) $(SRCFILE)

link: compile
	bsc -sim $(BLUESIMFLAGS) $(DIRFLAGS4SRC) $(RECOMPILEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -e $(TOP) -o $(SIMEXE)

verilog: link
	bsc $(VERILOGFLAGS) $(RECOMPILEFLAGS) -e $(TOP)

clean:
	rm -rf $(BUILDDIR)

.PHONY: compile link verilog clean
.DEFAULT_GOAL := verilog
