import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import Headers :: *;
import PrimUtils :: *;
import Utils :: *;
import Utils4Test :: *;

(* synthesize *)
module mkTestDupReadAtomicCache(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_1024;

    PipeOut#(ADDR) addr4ReadPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR) addr4AtomicPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Length) lenPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rKey4ReadPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rKey4AtomicPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) origPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RdmaOpCode) atomicOpCodePipeOut <- mkRandomAtomicReqRdmaOpCode;

    FIFOF#(Tuple2#(RETH, DupReadReqStartState)) readSearchReqQ <- mkFIFOF;
    FIFOF#(DupReadReqStartState) readSearchRespQ <- mkFIFOF;
    FIFOF#(AtomicCache) atomicSearchReqQ <- mkFIFOF;
    FIFOF#(AtomicCache) atomicSearchRespQ <- mkFIFOF;

    let cntrl <- mkSimController(qpType, pmtu);
    let dut <- mkDupReadAtomicCache(cntrl);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule insertReadReth;
        let addr = addr4ReadPipeOut.first;
        addr4ReadPipeOut.deq;

        let len = lenPipeOut.first;
        lenPipeOut.deq;

        let rkey = rKey4ReadPipeOut.first;
        rKey4ReadPipeOut.deq;

        let reth = RETH {
            va  : addr,
            dlen: len,
            rkey: rkey
        };
        dut.insertRead(reth);

        let twoAsPSN = 2;
        if (lenGtEqPsnMultiplyPMTU(len, twoAsPSN, pmtu)) begin
            let dupAddr = addrAddPsnMultiplyPMTU(addr, twoAsPSN, pmtu);
            let dupLen = lenSubtractPsnMultiplyPMTU(len, twoAsPSN, pmtu);
            let dupReadReth = RETH {
                va  : dupAddr,
                dlen: dupLen,
                rkey: rkey
            };
            readSearchReqQ.enq(tuple2(dupReadReth, DUP_READ_REQ_START_FROM_MIDDLE));

            // let errReadReth = RETH {
            //     va  : addr + 1,
            //     dlen: len - 1,
            //     rkey: rkey
            // };
            // let addrLenMatch = compareDupReadAddrAndLen(pmtu, dupReadReth, reth);
            // $display(
            //     "time=%0d: addrLenMatch=", $time, fshow(addrLenMatch),
            //     ", dupReadReth.va=%h, origReadReth.va=%h",
            //     dupReadReth.va, reth.va,
            //     ", dupReadReth.dlen=%h, origReadReth.dlen=%h",
            //     dupReadReth.dlen, reth.dlen
            // );
        end
        else begin
            let dupReadReth = reth;
            readSearchReqQ.enq(tuple2(dupReadReth, DUP_READ_REQ_START_FROM_FIRST));
        end
    endrule

    rule searchReadReq;
        let { dupReadReth, dupReadReqStartState } = readSearchReqQ.first;
        readSearchReqQ.deq;

        dut.searchReadReq(dupReadReth);
        readSearchRespQ.enq(dupReadReqStartState);
    endrule

    rule searchReadResp;
        let exptectedDupreadReqStartState = readSearchRespQ.first;
        readSearchRespQ.deq;

        let maybeSearchReadResp <- dut.searchReadResp;
        dynAssert(
            isValid(maybeSearchReadResp),
            "maybeSearchReadResp assertion @ mkTestDupReadAtomicCache",
            $format(
                "isValid(maybeSearchReadResp)=", fshow(isValid(maybeSearchReadResp)),
                " should be valid"
            )
        );

        let searchReadResp = unwrapMaybe(maybeSearchReadResp);
        dynAssert(
            searchReadResp == exptectedDupreadReqStartState,
            "searchReadResp assertion @ mkTestDupReadAtomicCache",
            $format(
                "searchReadResp=", fshow(searchReadResp),
                " should == exptectedDupreadReqStartState=",
                fshow(exptectedDupreadReqStartState)
            )
        );
    endrule

    rule insertAtomicCache;
        let atomicOpCode = atomicOpCodePipeOut.first;
        atomicOpCodePipeOut.deq;

        let addr = addr4AtomicPipeOut.first;
        addr4AtomicPipeOut.deq;

        let rkey = rKey4AtomicPipeOut.first;
        rKey4AtomicPipeOut.deq;

        let comp = compPipeOut.first;
        compPipeOut.deq;

        let swap = swapPipeOut.first;
        swapPipeOut.deq;

        let orig = origPipeOut.first;
        origPipeOut.deq;

        let atomicEth = AtomicEth {
            va  : addr,
            rkey: rkey,
            comp: comp,
            swap: swap
        };

        let atomicAckEth = AtomicAckEth { orig: orig };

        let atomicCache = AtomicCache {
            atomicOpCode: atomicOpCode,
            atomicEth   : atomicEth,
            atomicAckEth: atomicAckEth
        };

        dut.insertAtomic(atomicCache);
        atomicSearchReqQ.enq(atomicCache);
    endrule

    rule searchAtomicReq;
        let atomicCache = atomicSearchReqQ.first;
        atomicSearchReqQ.deq;

        dut.searchAtomicReq(atomicCache.atomicOpCode, atomicCache.atomicEth);
        atomicSearchRespQ.enq(atomicCache);
    endrule

    rule searchAtomicResp;
        countDown.decr;

        let exptectedAtomicCache = atomicSearchRespQ.first;
        atomicSearchRespQ.deq;

        let maybeSearchAtomicResp <- dut.searchAtomicResp;
        dynAssert(
            isValid(maybeSearchAtomicResp),
            "maybeSearchAtomicResp assertion @ mkTestDupReadAtomicCache",
            $format(
                "isValid(maybeSearchAtomicResp)=", fshow(isValid(maybeSearchAtomicResp)),
                " should be valid"
            )
        );

        let searchAtomicResp = unwrapMaybe(maybeSearchAtomicResp);
        let searchAtomicRespOpCode = searchAtomicResp.atomicOpCode;
        let exptectedAtomicRespOpCode = exptectedAtomicCache.atomicOpCode;
        let searchAtomicRespAddr = searchAtomicResp.atomicEth.va;
        let exptectedAtomicRespAddr = exptectedAtomicCache.atomicEth.va;
        let searchAtomicRespRKey = searchAtomicResp.atomicEth.rkey;
        let exptectedAtomicRespRKey = exptectedAtomicCache.atomicEth.rkey;
        let searchAtomicRespComp = searchAtomicResp.atomicEth.comp;
        let exptectedAtomicRespComp = exptectedAtomicCache.atomicEth.comp;
        let searchAtomicRespSwap = searchAtomicResp.atomicEth.swap;
        let exptectedAtomicRespSwap = exptectedAtomicCache.atomicEth.swap;
        let searchAtomicRespOrig = searchAtomicResp.atomicAckEth.orig;
        let exptectedAtomicRespOrig = exptectedAtomicCache.atomicAckEth.orig;
        dynAssert(
            searchAtomicRespOrig == exptectedAtomicRespOrig &&
            searchAtomicRespAddr == exptectedAtomicRespAddr &&
            searchAtomicRespRKey == exptectedAtomicRespRKey &&
            searchAtomicRespComp == exptectedAtomicRespComp &&
            searchAtomicRespSwap == exptectedAtomicRespSwap &&
            searchAtomicRespOpCode == exptectedAtomicRespOpCode,
            "searchAtomicRespOrig assertion @ mkTestDupReadAtomicCache",
            $format(
                "searchAtomicRespOrig=", fshow(searchAtomicRespOrig),
                " should == exptectedAtomicRespOrig=",
                fshow(exptectedAtomicRespOrig)
            )
        );
    endrule
endmodule
