import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import MetaData :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;
import Utils4Test :: *;

typedef enum {
    TEST_ST_FILL,
    TEST_ST_ACT,
    TEST_ST_POP
} SeqTestState deriving(Bits, Eq);

(* synthesize *)
module mkTestMetaDataPDs(Empty);
    let pdMetaDataDUT <- mkMetaDataPDs;
    Count#(Bit#(TAdd#(1, TLog#(MAX_PD)))) pdReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_PD)))          pdRespCnt <- mkCount(0);

    PipeOut#(KeyPD) pdKeyPipeOut <- mkGenericRandomPipeOut;
    Vector#(2, PipeOut#(KeyPD)) pdKeyPipeOutVec <-
        mkForkVector(pdKeyPipeOut);
    let pdKeyPipeOut4InsertReq = pdKeyPipeOutVec[0];
    let pdKeyPipeOut4InsertResp <- mkBufferN(2, pdKeyPipeOutVec[1]);
    FIFOF#(HandlerPD) pdHandlerQ4Search <- mkSizedFIFOF(valueOf(MAX_PD));
    FIFOF#(HandlerPD) pdHandlerQ4Pop <- mkSizedFIFOF(valueOf(MAX_PD));

    Reg#(SeqTestState) pdTestStateReg <- mkReg(TEST_ST_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule allocPDs if (pdTestStateReg == TEST_ST_FILL);
        if (pdReqCnt < fromInteger(valueOf(MAX_PD))) begin
            let pdKey = pdKeyPipeOut4InsertReq.first;
            pdKeyPipeOut4InsertReq.deq;

            let allocReq = ReqPD {
                allocOrNot: True,
                pdKey     : pdKey,
                pdHandler : dontCareValue
            };
            pdMetaDataDUT.srvPort.request.put(allocReq);
            pdReqCnt.incr(1);
        end
    endrule

    rule allocResp if (pdTestStateReg == TEST_ST_FILL);
        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_ST_ACT;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let allocResp <- pdMetaDataDUT.srvPort.response.get;
        immAssert(
            allocResp.successOrNot,
            "allocResp.successOrNot assertion @ mkTestMetaDataPDs",
            $format(
                "allocResp.successOrNot=", fshow(allocResp.successOrNot),
                " should be valid when pdCnt=%0d", pdRespCnt
            )
        );

        let pdHandler = allocResp.pdHandler;
        let pdKey = allocResp.pdKey;
        pdHandlerQ4Search.enq(pdHandler);
        pdHandlerQ4Pop.enq(pdHandler);

        let pdKeyRef = pdKeyPipeOut4InsertResp.first;
        pdKeyPipeOut4InsertResp.deq;

        immAssert(
            pdKey == truncate(pdHandler) && pdKey == pdKeyRef,
            "pdKey assertion @ mkTestMetaDataPDs",
            $format(
                "pdKey=%h should match pdHandler=%h and pdKeyRef=%h",
                pdKey, pdHandler, pdKeyRef
            )
        );
        // $display(
        //     "time=%0t: pdKey=%h, pdHandler=%h, pdRespCnt=%0d when allocate MetaDataPDs, pdMetaDataDUT.notFull=",
        //     $time, pdKey, pdHandler, pdRespCnt, fshow(pdMetaDataDUT.notFull)
        // );
    endrule

    rule compareSearch if (pdTestStateReg == TEST_ST_ACT);
        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_ST_POP;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let pdHandler2Search = pdHandlerQ4Search.first;
        pdHandlerQ4Search.deq;

        let isValidPD = pdMetaDataDUT.isValidPD(pdHandler2Search);
        immAssert(
            isValidPD,
            "isValidPD assertion @ mkTestMetaDataPDs",
            $format(
                "isValidPD=", fshow(isValidPD),
                " should be valid when pdHandler2Search=%h and pdRespCnt=%0d",
                pdHandler2Search, pdRespCnt
            )
        );

        let maybeMRs = pdMetaDataDUT.getMRs4PD(pdHandler2Search);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestMetaDataPDs",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid when pdHandler2Search=%h and pdRespCnt=%0d",
                pdHandler2Search, pdRespCnt
            )
        );
        // $display(
        //     "time=%0t: isValid(maybeMRs)=", $time, fshow(isValid(maybeMRs)),
        //     " should be valid when pdHandler2Search=%0d and pdRespCnt=%0d",
        //     pdHandler2Search, pdRespCnt
        // );
    endrule

    rule deAllocPDs if (pdTestStateReg == TEST_ST_POP);
        if (pdReqCnt < fromInteger(valueOf(MAX_PD))) begin
            let pdHandler2Remove = pdHandlerQ4Pop.first;
            pdHandlerQ4Pop.deq;

            let deAllocReq = ReqPD {
                allocOrNot: False,
                pdKey     : dontCareValue,
                pdHandler : pdHandler2Remove
            };
            pdMetaDataDUT.srvPort.request.put(deAllocReq);
            pdReqCnt.incr(1);
        end
    endrule

    rule deAllocResp if (pdTestStateReg == TEST_ST_POP);
        countDown.decr;

        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_ST_FILL;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let deAllocResp <- pdMetaDataDUT.srvPort.response.get;
        let pdHandler = deAllocResp.pdHandler;
        let pdKey = deAllocResp.pdKey;
        immAssert(
            deAllocResp.successOrNot,
            "deAllocResp.successOrNot assertion @ mkTestMetaDataPDs",
            $format(
                "deAllocResp.successOrNot=", fshow(deAllocResp.successOrNot),
                " should be true when pdRespCnt=%0d", pdRespCnt
            )
        );
        immAssert(
            pdKey == truncate(pdHandler),
            "pdKey assertion @ mkTestMetaDataPDs",
            $format(
                "pdKey=%h should match pdHandler=%h",
                pdKey, pdHandler
            )
        );
        // $display(
        //     "time=%0t: deAllocResp=", $time, fshow(deAllocResp),
        //     " should be true when pdRespCnt=%0d", pdRespCnt
        // );
    endrule
endmodule

(* synthesize *)
module mkTestMetaDataMRs(Empty);
    let mrMetaDataDUT <- mkMetaDataMRs;

    Count#(Bit#(TAdd#(1, TLog#(MAX_MR_PER_PD)))) mrReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD))) mrRespCnt <- mkCount(0);

    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;
    Vector#(2, PipeOut#(KeyPartMR)) mrKeyPipeOutVec <-
        mkForkVector(mrKeyPipeOut);
    let mrKeyPipeOut4InsertReq = mrKeyPipeOutVec[0];
    let mrKeyPipeOut4InsertResp <- mkBufferN(2, mrKeyPipeOutVec[1]);
    FIFOF#(LKEY) lkeyQ4Search <- mkSizedFIFOF(valueOf(MAX_MR_PER_PD));
    FIFOF#(RKEY) rkeyQ4Pop <- mkSizedFIFOF(valueOf(MAX_MR_PER_PD));
    FIFOF#(RKEY) rkeyQ4Comp <- mkFIFOF;

    Reg#(SeqTestState) mrTestStateReg <- mkReg(TEST_ST_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule allocMRs if (mrTestStateReg == TEST_ST_FILL);
        if (mrReqCnt < fromInteger(valueOf(MAX_MR_PER_PD))) begin
            let curMrKey = mrKeyPipeOut4InsertReq.first;
            mrKeyPipeOut4InsertReq.deq;

            let allocReq = ReqMR {
                allocOrNot   : True,
                mr           : MemRegion {
                    laddr    : dontCareValue,
                    len      : dontCareValue,
                    accType  : dontCareValue,
                    pdHandler: dontCareValue,
                    lkeyPart : curMrKey,
                    rkeyPart : curMrKey
                },
                lkeyOrNot    : False,
                lkey         : dontCareValue,
                rkey         : dontCareValue
            };

            mrMetaDataDUT.srvPort.request.put(allocReq);
            mrReqCnt.incr(1);
        end
    endrule

    rule allocResp if (mrTestStateReg == TEST_ST_FILL);
        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_ST_ACT;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let allocResp <- mrMetaDataDUT.srvPort.response.get;
        immAssert(
            allocResp.successOrNot,
            "allocResp.successOrNot assertion @ mkTestMetaDataMRs",
            $format(
                "allocResp.successOrNot=", fshow(allocResp.successOrNot),
                " should be valid"
            )
        );
        let lkey = allocResp.lkey;
        let rkey = allocResp.rkey;
        lkeyQ4Search.enq(lkey);
        rkeyQ4Pop.enq(rkey);

        let mrKeyPart = mrKeyPipeOut4InsertResp.first;
        mrKeyPipeOut4InsertResp.deq;

        immAssert(
            mrKeyPart == truncate(lkey),
            "lkey assertion @ mkTestMetaDataMRs",
            $format(
                "lkey=%h should match mrKeyPart=%h",
                lkey, mrKeyPart
            )
        );
        immAssert(
            mrKeyPart == truncate(rkey),
            "rkey assertion @ mkTestMetaDataMRs",
            $format(
                "rkey=%h should match mrKeyPart=%h",
                rkey, mrKeyPart
            )
        );

        IndexMR mrIndex = unpack(truncateLSB(lkey));
        // $display(
        //     "time=%0t: mrIndex=%h, lkey=%h, rkey=%h, mrRespCnt=%0d when allocate MetaDataMRs, mrMetaDataDUT.notFull=",
        //     $time, mrIndex, lkey, rkey, mrRespCnt, fshow(mrMetaDataDUT.notFull)
        // );
    endrule

    rule compareSearch if (mrTestStateReg == TEST_ST_ACT);
        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_ST_POP;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let lkey2Search = lkeyQ4Search.first;
        lkeyQ4Search.deq;

        let maybeMR = mrMetaDataDUT.getMemRegionByLKey(lkey2Search);
        immAssert(
            isValid(maybeMR),
            "maybeMR assertion @ mkTestMetaDataMRs",
            $format(
                "maybeMR=", fshow(maybeMR),
                " should be valid when lkey2Search=%h and mrReqCnt=%0d",
                lkey2Search, mrReqCnt
            )
        );
        // $display(
        //     "time=%0t: maybeMR=", $time, fshow(maybeMR),
        //     " should be valid when lkey2Search=%h and mrReqCnt=%0d",
        //     lkey2Search, mrReqCnt
        // );
    endrule

    rule deAllocMRs if (mrTestStateReg == TEST_ST_POP);
        if (mrReqCnt < fromInteger(valueOf(MAX_MR_PER_PD))) begin
            let rkey2Remove = rkeyQ4Pop.first;
            rkeyQ4Pop.deq;

            let deAllocReq = ReqMR {
                allocOrNot   : False,
                mr           : dontCareValue,
                lkeyOrNot    : False,
                lkey         : dontCareValue,
                rkey         : rkey2Remove
            };

            mrMetaDataDUT.srvPort.request.put(deAllocReq);
            rkeyQ4Comp.enq(rkey2Remove);
            mrReqCnt.incr(1);

            // $display(
            //     "time=%0t: deAllocReq=", $time, fshow(deAllocReq),
            //     " should be true when rkey2Remove=%h and mrReqCnt=%0d",
            //     rkey2Remove, mrReqCnt
            // );
        end
    endrule

    rule deAllocResp if (mrTestStateReg == TEST_ST_POP);
        countDown.decr;

        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_ST_FILL;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let rkey2Remove = rkeyQ4Comp.first;
        rkeyQ4Comp.deq;

        let deAllocResp <- mrMetaDataDUT.srvPort.response.get;
        immAssert(
            deAllocResp.successOrNot,
            "deAllocResp.successOrNot assertion @ mkTestMetaDataMRs",
            $format(
                "deAllocResp.successOrNot=", fshow(deAllocResp.successOrNot),
                " should be true when mrRespCnt=%0d", mrRespCnt
            )
        );
        immAssert(
            rkey2Remove == deAllocResp.rkey,
            "rkey assertion @ mkTestMetaDataMRs",
            $format(
                "rkey2Remove=%h should == deAllocResp.rkey=%h",
                rkey2Remove, deAllocResp.rkey
            )
        );

        // $display(
        //     "time=%0t: deAllocResp=", $time, fshow(deAllocResp),
        //     " should be true when rkey2Remove=%h and mrRespCnt=%0d",
        //     rkey2Remove, mrRespCnt
        // );
    endrule
endmodule

(* synthesize *)
module mkTestMetaDataQPs(Empty);
    let qpMetaDataDUT <- mkMetaDataQPs;
    Count#(Bit#(TAdd#(1, TLog#(MAX_QP)))) qpReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_QP)))          qpRespCnt <- mkCount(0);

    PipeOut#(HandlerPD) pdHandlerPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(HandlerPD)) pdHandlerPipeOutVec <-
        mkForkVector(pdHandlerPipeOut);
    let pdHandlerPipeOut4InsertReq = pdHandlerPipeOutVec[0];
    let pdHandlerPipeOut4InsertResp <- mkBufferN(2, pdHandlerPipeOutVec[1]);
    let pdHandlerPipeOut4Search <- mkBufferN(valueOf(MAX_QP), pdHandlerPipeOutVec[2]);
    FIFOF#(QPN) qpnQ4Search <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(QPN) qpnQ4Pop <- mkSizedFIFOF(valueOf(MAX_QP));

    Reg#(SeqTestState) qpTestStateReg <- mkReg(TEST_ST_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule createQPs if (qpTestStateReg == TEST_ST_FILL);
        if (qpReqCnt < fromInteger(valueOf(MAX_QP))) begin
            qpReqCnt.incr(1);
            let curPdHandler = pdHandlerPipeOut4InsertReq.first;
            pdHandlerPipeOut4InsertReq.deq;

            let createReq = ReqQP {
                createOrNot: True,
                pdHandler  : curPdHandler,
                qpn        : dontCareValue
            };
            qpMetaDataDUT.srvPort.request.put(createReq);
        end
    endrule

    rule createResp if (qpTestStateReg == TEST_ST_FILL);
        if (qpRespCnt == fromInteger(valueOf(MAX_QP) - 1)) begin
            qpReqCnt  <= 0;
            qpRespCnt <= 0;
            qpTestStateReg <= TEST_ST_ACT;
        end
        else begin
            qpRespCnt.incr(1);
        end

        let createResp <- qpMetaDataDUT.srvPort.response.get;
        let qpn = createResp.qpn;
        let pdHandler = createResp.pdHandler;
        qpnQ4Search.enq(qpn);
        qpnQ4Pop.enq(qpn);

        let refPdHandler = pdHandlerPipeOut4InsertResp.first;
        pdHandlerPipeOut4InsertResp.deq;

        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH)) refPart = truncateLSB(refPdHandler);
        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH)) qpnPart = truncate(qpn);
        immAssert(
            qpnPart == refPart && pdHandler == refPdHandler,
            "qpnPart assertion @ mkTestMetaDataQPs",
            $format(
                "qpnPart=%h should == refPart=%h",
                qpnPart, refPart,
                " and pdHandler=%h should == refPdHandler=%h",
                pdHandler, refPdHandler
            )
        );

        // $display(
        //     "time=%0t: qpn=%h should match refPdHandler=%h and pdHandler=%h",
        //     $time, qpn, refPdHandler, pdHandler
        // );
    endrule

    rule compareSearch if (qpTestStateReg == TEST_ST_ACT);
        if (qpRespCnt == fromInteger(valueOf(MAX_QP) - 1)) begin
            qpReqCnt  <= 0;
            qpRespCnt <= 0;
            qpTestStateReg <= TEST_ST_POP;
        end
        else begin
            qpRespCnt.incr(1);
        end

        let qpn2Search = qpnQ4Search.first;
        qpnQ4Search.deq;

        let isValidQP = qpMetaDataDUT.isValidQP(qpn2Search);
        immAssert(
            isValidQP,
            "isValidQP assertion @ mkTestMetaDataQPs",
            $format(
                "isValidQP=", fshow(isValidQP),
                " should be valid when qpn2Search=%h and qpRespCnt=%0d",
                qpn2Search, qpRespCnt
            )
        );

        let maybePD = qpMetaDataDUT.getPD(qpn2Search);
        immAssert(
            isValid(maybePD),
            "maybePD assertion @ mkTestMetaDataQPs",
            $format(
                "maybePD=", fshow(isValid(maybePD)),
                " should be valid"
            )
        );

        let pdHandler = unwrapMaybe(maybePD);
        let refPdHandler = pdHandlerPipeOut4Search.first;
        pdHandlerPipeOut4Search.deq;

        immAssert(
            pdHandler == refPdHandler,
            "pdHandler assertion @ mkTestMetaDataQPs",
            $format(
                "pdHandler=%h should match refPdHandler=%h",
                pdHandler, refPdHandler
            )
        );

        let qpCntrl = qpMetaDataDUT.getCntrlByQPN(qpn2Search);
        immAssert(
            qpCntrl.isReset,
            "qpCntrl assertion @ mkTestMetaDataQPs",
            $format(
                "qpCntrl.isReset=", fshow(qpCntrl.isReset),
                " should be true"
            )
        );

        // $display(
        //     "time=%0t: isValidQP=", $time, fshow(isValidQP),
        //     " should be valid when qpn2Search=%h and qpCnt=%0d",
        //     qpn2Search, qpCnt
        // );
    endrule

    rule destroyQPs if (qpTestStateReg == TEST_ST_POP);
        if (qpReqCnt < fromInteger(valueOf(MAX_QP))) begin
            qpReqCnt.incr(1);
            let qpn2Remove = qpnQ4Pop.first;
            qpnQ4Pop.deq;

            let removeReq = ReqQP {
                createOrNot: False,
                pdHandler  : dontCareValue,
                qpn        : qpn2Remove
            };
            qpMetaDataDUT.srvPort.request.put(removeReq);
        end
    endrule

    rule destroyResp if (qpTestStateReg == TEST_ST_POP);
        countDown.decr;

        if (qpRespCnt == fromInteger(valueOf(MAX_QP) - 1)) begin
            qpReqCnt  <= 0;
            qpRespCnt <= 0;
            qpTestStateReg <= TEST_ST_FILL;
        end
        else begin
            qpRespCnt.incr(1);
        end

        let removeResp <- qpMetaDataDUT.srvPort.response.get;
        let pdHandler = removeResp.pdHandler;
        let qpn = removeResp.qpn;
        immAssert(
            removeResp.successOrNot,
            "removeResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "removeResp.successOrNot=", fshow(removeResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );

        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH))  pdPart = truncateLSB(pdHandler);
        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH)) qpnPart = truncate(qpn);
        immAssert(
            qpnPart == pdPart,
            "qpnPart assertion @ mkTestMetaDataQPs",
            $format(
                "qpnPart=%h should == pdPart=%h",
                qpnPart, pdPart
            )
        );
        // $display(
        //     "time=%0t: removeResp=", $time, fshow(removeResp),
        //     " should be true when qpRespCnt=%0d", qpRespCnt
        // );
    endrule
endmodule

(* synthesize *)
module mkTestPermCheckMR(Empty);
    let pdMetaData  <- mkMetaDataPDs;
    let permCheckMR <- mkPermCheckMR(pdMetaData);

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))  pdReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD)))) pdRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))     mrReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))    mrRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, TMul#(MAX_PD, MAX_MR_PER_PD))))) mrTotalReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(MAX_PD, MAX_MR_PER_PD))))          mrTotalRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(MAX_PD, MAX_MR_PER_PD))))            searchReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(2, TMul#(MAX_PD, MAX_MR_PER_PD))))) searchRespCnt <- mkCount(0);

    let pdNum = valueOf(MAX_PD);
    let mrNumPerPD = valueOf(MAX_MR_PER_PD);
    let mrTotalNum = valueOf(TMul#(MAX_PD, MAX_MR_PER_PD));
    let totalSearchNum = valueOf(TMul#(2, TMul#(MAX_PD, MAX_MR_PER_PD)));

    PipeOut#(KeyPD)     pdKeyPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(HandlerPD)  pdHandlerQ4FillMR <- mkFIFOF;
    FIFOF#(HandlerPD) pdHandlerQ4CheckMR <- mkFIFOF;
    FIFOF#(Tuple2#(HandlerPD, LKEY)) lKeyQ4Search <- mkSizedFIFOF(valueOf(TMul#(MAX_PD, MAX_MR_PER_PD)));
    FIFOF#(Tuple2#(HandlerPD, RKEY)) rKeyQ4Search <- mkSizedFIFOF(valueOf(TMul#(MAX_PD, MAX_MR_PER_PD)));

    Reg#(SeqTestState) mrCheckStateReg <- mkReg(TEST_ST_FILL);
    Reg#(Bool) rkeySearchReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    ADDR defaultAddr   = fromInteger(0);
    Length defaultLen  = fromInteger(valueOf(RDMA_MAX_LEN));
    let defaultAccPerm = IBV_ACCESS_REMOTE_WRITE;

    rule allocPDs if (pdReqCnt < fromInteger(pdNum) && mrCheckStateReg == TEST_ST_FILL);
        pdReqCnt.incr(1);
        let pdKey = pdKeyPipeOut.first;
        pdKeyPipeOut.deq;

        let allocReqPD = ReqPD {
            allocOrNot: True,
            pdKey     : pdKey,
            pdHandler : dontCareValue
        };
        pdMetaData.srvPort.request.put(allocReqPD);

        // $display("time=%0t: pdKey=%h", $time, pdKey);
    endrule

    rule allocRespPDs if (pdRespCnt < fromInteger(pdNum) && mrCheckStateReg == TEST_ST_FILL);
        pdRespCnt.incr(1);
        let allocRespPD <- pdMetaData.srvPort.response.get;
        immAssert(
            allocRespPD.successOrNot,
            "allocRespPD.successOrNot assertion @ mkTestPermCheckMR",
            $format(
                "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                " should be true when pdRespCnt=%0d", pdRespCnt
            )
        );

        pdHandlerQ4FillMR.enq(allocRespPD.pdHandler);
        pdHandlerQ4CheckMR.enq(allocRespPD.pdHandler);
        // $display("time=%0t: pdHandler=%h", $time, pdHandler);
    endrule

    rule allocMRs if (mrTotalReqCnt < fromInteger(mrTotalNum) && mrCheckStateReg == TEST_ST_FILL);
        let pdHandler = pdHandlerQ4FillMR.first;

        if (mrReqCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt <= 0;
            pdHandlerQ4FillMR.deq;
        end
        else begin
            mrReqCnt.incr(1);
        end
        mrTotalReqCnt.incr(1);

        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestPermCheckMR",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid for pdHandler=%h", pdHandler
            )
        );

        // let mrMetaData = unwrapMaybe(maybeMRs);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            let mrKey = mrKeyPipeOut.first;
            mrKeyPipeOut.deq;

            let allocReqMR = ReqMR {
                allocOrNot: True,
                mr: MemRegion {
                    laddr    : defaultAddr,
                    len      : defaultLen,
                    accType  : defaultAccPerm,
                    pdHandler: pdHandler,
                    lkeyPart : mrKey,
                    rkeyPart : mrKey
                },
                lkeyOrNot: False,
                rkey     : dontCareValue,
                lkey     : dontCareValue
            };
            mrMetaData.srvPort.request.put(allocReqMR);

            // $display("time=%0t: mrKey=%h", $time, mrKey);
        end
    endrule

    rule allocRespMRs if (mrCheckStateReg == TEST_ST_FILL);
        if (mrTotalRespCnt == fromInteger(mrTotalNum - 1)) begin
            mrTotalRespCnt <= 0;
            mrCheckStateReg <= TEST_ST_ACT;
        end
        else begin
            mrTotalRespCnt.incr(1);
        end

        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrRespCnt <= 0;
            pdHandlerQ4CheckMR.deq;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let pdHandler = pdHandlerQ4CheckMR.first;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestPermCheckMR",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid for pdHandler=%h", pdHandler
            )
        );

        // let mrMetaData = unwrapMaybe(maybeMRs);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            let allocRespMR <- mrMetaData.srvPort.response.get;
            immAssert(
                allocRespMR.successOrNot,
                "allocRespMR.successOrNot assertion @ mkTestMetaDataMRs",
                $format(
                    "allocRespMR.successOrNot=", fshow(allocRespMR.successOrNot),
                    " should be valid"
                )
            );

            let lkey = allocRespMR.lkey;
            let rkey = allocRespMR.rkey;
            // immAssert(
            //     isValid(rkey),
            //     "rkey assertion @ mkTestPermCheckMR",
            //     $format("rkey=", rkey, " should be valid")
            // );

            lKeyQ4Search.enq(tuple2(pdHandler, lkey));
            rKeyQ4Search.enq(tuple2(pdHandler, rkey));

            // $display("time=%0t: lkey=%h, rkey=%h", $time, lkey, rkey);
        end
        // $display(
        //     "time=%0t: mrTotalRespCnt=%0d, mrRespCnt=%0d",
        //     $time, mrTotalRespCnt, mrRespCnt
        // );
    endrule

    rule checkReqByLKey if (!rkeySearchReg && mrCheckStateReg == TEST_ST_ACT);
        if (searchReqCnt == fromInteger(mrTotalNum - 1)) begin
            rkeySearchReg <= True;
            searchReqCnt <= 0;
        end
        else begin
            searchReqCnt.incr(1);
        end

        let { pdHandler, lkey } = lKeyQ4Search.first;
        lKeyQ4Search.deq;

        let permCheckInfo = PermCheckInfo {
            wrID         : tagged Invalid,
            lkey         : lkey,
            rkey         : dontCareValue,
            localOrRmtKey: True,
            laddr        : defaultAddr,
            totalLen     : defaultLen,
            pdHandler    : pdHandler,
            isZeroDmaLen : isZero(defaultLen),
            accType      : defaultAccPerm
        };

        permCheckMR.request.put(permCheckInfo);
        // $display(
        //     "time=%0t: checkReqByLKey permCheckInfo=", $time, fshow(permCheckInfo)
        // );
    endrule

    rule checkReqByRKey if (rkeySearchReg && mrCheckStateReg == TEST_ST_ACT);
        if (searchReqCnt == fromInteger(mrTotalNum - 1)) begin
            rkeySearchReg <= False;
            searchReqCnt <= 0;
        end
        else begin
            searchReqCnt.incr(1);
        end

        let { pdHandler, rkey } = rKeyQ4Search.first;
        rKeyQ4Search.deq;

        let permCheckInfo = PermCheckInfo {
            wrID         : tagged Invalid,
            lkey         : dontCareValue,
            rkey         : rkey,
            localOrRmtKey: False,
            laddr        : defaultAddr,
            totalLen     : defaultLen,
            pdHandler    : pdHandler,
            isZeroDmaLen : isZero(defaultLen),
            accType      : defaultAccPerm
        };

        permCheckMR.request.put(permCheckInfo);
        // $display(
        //     "time=%0t: checkReqByRKey permCheckInfo=", $time, fshow(permCheckInfo)
        // );
    endrule

    rule checkResp if (mrCheckStateReg == TEST_ST_ACT);
        if (searchRespCnt == fromInteger(totalSearchNum - 1)) begin
            searchRespCnt <= 0;
            mrCheckStateReg <= TEST_ST_POP;
        end
        else begin
            searchRespCnt.incr(1);
        end

        let checkResp <- permCheckMR.response.get;
        immAssert(
            checkResp,
            "checkResp @ mkTestPermCheckMR",
            $format(
                "checkResp=", fshow(checkResp), " should be true"
            )
        );

        // if (lKeyPermCheckInfoQ.notEmpty) begin
        //     let lKeyCheckResp <- permCheckMR.response.get;
        //     immAssert(
        //         lKeyCheckResp,
        //         "lKeyCheckResp @ mkTestPermCheckMR",
        //         $format(
        //             "lKeyCheckResp=", fshow(lKeyCheckResp),
        //             " should be true"
        //         )
        //     );
        //     searchCnt.decr(1);

        //     $display(
        //         "time=%0t: lKeyCheckResp=", $time, fshow(lKeyCheckResp), " should be true"
        //     );
        // end
        // else if (rKeyPermCheckInfoQ.notEmpty) begin
        //     let rKeyCheckResp <- permCheckMR.response.get;
        //     immAssert(
        //         rKeyCheckResp,
        //         "rKeyCheckResp @ mkTestPermCheckMR",
        //         $format(
        //             "rKeyCheckResp=", fshow(rKeyCheckResp),
        //             " should be true"
        //         )
        //     );
        //     searchCnt.decr(1);

        //     $display(
        //         "time=%0t: rKeyCheckResp=", $time, fshow(rKeyCheckResp), " should be true"
        //     );
        // end

        countDown.decr;
        // $display(
        //     "time=%0t: searchRespCnt=%0d, checkResp=",
        //     $time, searchRespCnt, fshow(checkResp),
        //     " should be true"
        // );
    endrule

    rule clear if (mrCheckStateReg == TEST_ST_POP);
        pdReqCnt  <= 0;
        pdRespCnt <= 0;
        mrReqCnt  <= 0;
        mrRespCnt <= 0;
        mrTotalReqCnt  <= 0;
        mrTotalRespCnt <= 0;
        searchReqCnt   <= 0;
        searchRespCnt  <= 0;

        pdHandlerQ4FillMR.clear;
        pdHandlerQ4CheckMR.clear;
        lKeyQ4Search.clear;
        rKeyQ4Search.clear;

        pdMetaData.clear;

        mrCheckStateReg <= TEST_ST_FILL;

        // $display("time=%0t: clear", $time);
    endrule
endmodule

(* synthesize *)
module mkTestBramCache(Empty);
    let dut <- mkBramCache;

    // Use address counter to avoid write address conflict
    Count#(BramCacheAddr)       bramCacheAddrReg <- mkCount(0);
    PipeOut#(BramCacheData) bramCacheDataPipeOut <- mkGenericRandomPipeOut;
    // PipeOut#(BramCacheAddr) bramCacheAddrPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(BramCacheAddr) bramCacheAddrQ <- mkFIFOF;
    FIFOF#(BramCacheData) bramCacheDataQ <- mkFIFOF;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule writeBramCache;
        // let bramCacheAddr = bramCacheAddrPipeOut.first;
        // bramCacheAddrPipeOut.deq;
        let bramCacheAddr = bramCacheAddrReg;
        bramCacheAddrReg.incr(1);
        let bramCacheData = bramCacheDataPipeOut.first;
        bramCacheDataPipeOut.deq;

        dut.write(bramCacheAddr, bramCacheData);
        bramCacheAddrQ.enq(bramCacheAddr);
        bramCacheDataQ.enq(bramCacheData);
        // $display(
        //     "time=%0t:", $time,
        //     " write bramCacheAddr=%h, bramCacheData=%h",
        //     bramCacheAddr, bramCacheData
        // );
    endrule

    rule readBramCache;
        let bramCacheAddr = bramCacheAddrQ.first;
        bramCacheAddrQ.deq;

        // dut.readReq(bramCacheAddr);
        dut.read.request.put(bramCacheAddr);
        // $display(
        //     "time=%0t:", $time,
        //     " read request bramCacheAddr=%h", bramCacheAddr
        // );
    endrule

    rule checkReadResp;
        let bramCacheReadData <- dut.read.response.get;
        // let bramCacheReadData <- dut.readResp;
        let bramCacheReadDataRef = bramCacheDataQ.first;
        bramCacheDataQ.deq;

        immAssert(
            bramCacheReadData == bramCacheReadDataRef,
            "bramCacheReadData assertion @ mkTestBramCache",
            $format(
                "bramCacheReadData=%h should == bramCacheReadDataRef=%h",
                bramCacheReadData, bramCacheReadDataRef
            )
        );
        countDown.decr;
        // $display(
        //     "bramCacheReadData=%h should == bramCacheReadDataRef=%h",
        //     bramCacheReadData, bramCacheReadDataRef
        // );
    endrule
endmodule

(* synthesize *)
module mkTestTLB(Empty);
    let dut <- mkTLB;

    PipeOut#(ADDR)                             virtAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Bit#(TLB_CACHE_PA_DATA_WIDTH)) phyAddrDataPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(ADDR)                             virtAddrQ <- mkFIFOF;
    FIFOF#(ADDR)                         virtAddrQ4Ref <- mkFIFOF;
    FIFOF#(Bit#(TLB_CACHE_PA_DATA_WIDTH)) phyAddrDataQ <- mkFIFOF;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule insert2TLB;
        let virtAddr = virtAddrPipeOut.first;
        virtAddrPipeOut.deq;
        let phyAddrData = phyAddrDataPipeOut.first;
        phyAddrDataPipeOut.deq;

        let pageOffset = getPageOffset(virtAddr);
        let phyAddr = restorePA(phyAddrData, pageOffset);

        dut.insert(virtAddr, phyAddr);
        virtAddrQ.enq(virtAddr);
        phyAddrDataQ.enq(phyAddrData);
    endrule

    rule findInTLB;
        let virtAddr = virtAddrQ.first;
        virtAddrQ.deq;

        dut.find.request.put(virtAddr);
        // dut.findReq(virtAddr);
        virtAddrQ4Ref.enq(virtAddr);
    endrule

    rule checkFindResp;
        let { foundOrNot, phyAddr } <- dut.find.response.get;
        // let { foundOrNot, phyAddr } <- dut.findResp;
        let phyAddrData = getData4PA(phyAddr);
        let phyAddrDataRef = phyAddrDataQ.first;
        phyAddrDataQ.deq;
        let virtAddrRef = virtAddrQ4Ref.first;
        virtAddrQ4Ref.deq;

        immAssert(
            foundOrNot,
            "foundOrNot assertion @ mkTestTLB",
            $format(
                "foundOrNot=", fshow(foundOrNot), " should be true"
            )
        );

        immAssert(
            phyAddrData == phyAddrDataRef,
            "phyAddrData assertion @ mkTestTLB",
            $format(
                "phyAddrData=%h should == phyAddrDataRef=%h",
                phyAddrData, phyAddrDataRef
            )
        );
        countDown.decr;
        // $display(
        //     "time=%0t:", $time,
        //     " foundOrNot=", fshow(foundOrNot),
        //     ", virtAddr=%h v.s. phyAddr=%h",
        //     virtAddrRef, phyAddr,
        //     ", phyAddrData=%h should == phyAddrDataRef=%h",
        //     phyAddrData, phyAddrDataRef
        // );
    endrule
endmodule
