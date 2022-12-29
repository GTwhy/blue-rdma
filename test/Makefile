include ../Makefile.base

TESTFILE ?= TestExtractAndPrependPipeOut.bsv
TOP ?= mkTestHeaderAndDataStreamConversion

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS4TEST) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOP) $(TESTFILE)

link: compile
	bsc -sim $(BLUESIMFLAGS) $(DIRFLAGS4TEST) $(RECOMPILEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -e $(TOP) -o $(SIMEXE)

simulate: link
	$(SIMEXE)

clean:
	rm -rf $(BUILDDIR)

.PHONY: compile link simulate clean
.DEFAULT_GOAL := simulate
