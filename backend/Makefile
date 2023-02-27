include ../Makefile.base

XDCDIR ?= xdc
VLOGDIR ?= verilog
OUTPUTDIR ?= output
ONLYSYNTH ?= 1
TARGETFILE ?= ../src/QP.bsv
TOPMODULE ?= mkTransportLayerRDMA
export TOP = $(TOPMODULE)
export RTL = $(VLOGDIR)
export XDC = $(XDCDIR)
export OUTPUT = $(OUTPUTDIR)
export SYNTHONLY = $(ONLYSYNTH)

verilog:
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)
	mkdir -p $(VLOGDIR)
	bluetcl listVlogFiles.tcl -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(TOPMODULE) $(TOPMODULE) | grep -i '\.v' | xargs -I {} cp {} $(VLOGDIR)

vivado: verilog
	vivado -mode batch -source non_project_build.tcl 2>&1 | tee ./run.log

clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR) $(VLOGDIR) .Xil *.jou *.log

.PHONY: verilog vivado clean
.DEFAULT_GOAL := verilog
