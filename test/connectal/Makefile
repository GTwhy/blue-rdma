CONNECTALDIR ?= $(abspath ../../../connectal)
BSVBASEDIR = $(abspath ../../src)
BASEDIR = $(abspath .)
export DUMP_VCD=dump.vcd

S2H_INTERFACES = CntrlRequest:ControllerWrapper.cntrlRequest
H2S_INTERFACES = ControllerWrapper:CntrlIndication

# FILES
CPPFILES = test_cntrl.cpp
BSVFILES = ControllerWrapper.bsv WrapperDataTypes.bsv

BSVDIR = $(BSVBASEDIR):$(abspath ../)
export SOFTWARE_SOCKET_NAME=/tmp/connectal$(USER)

# Connectal Flags
CONNECTALFLAGS += -D TRACE_PORTAL --bsvpath $(BSVDIR) --nonstrict
CONNECTALFLAGS += --bscflags " -u -keep-fires -aggressive-conditions -show-schedule "
CONNECTALFLAGS += --cxxflags=-fpermissive


include $(CONNECTALDIR)/Makefile.connectal

.PHONY: clean run build
.DEFAULT_GOAL := build

run:
	$(MAKE) run.bluesim

build:
	rm -rf $(BASEDIR)/bluesim
	make -j32 build.bluesim

clean:
	rm -rf bluesim program
