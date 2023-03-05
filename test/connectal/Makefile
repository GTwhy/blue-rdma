CONNECTALDIR ?= $(abspath ../../../connectal)
BSVBASEDIR = $(abspath ../../src)
BASEDIR = $(abspath .)

S2H_INTERFACES = \
	CntrlRequest:Controller.cntrlRequest
H2S_INTERFACES = \
	Controller:CntrlIndication

# FILES
CPPFILES = test_cntrl.cpp
BSVFILES = $(BSVBASEDIR)/Controller.bsv
BSVDIR = $(BSVBASEDIR)

export SOFTWARE_SOCKET_NAME=/tmp/connectal$(USER)

# Connectal Flags
CONNECTALFLAGS += -D TRACE_PORTAL --bsvpath $(BSVDIR)
CONNECTALFLAGS += --bscflags " -u -keep-fires -aggressive-conditions -show-schedule "


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
