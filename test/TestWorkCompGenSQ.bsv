import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGenSQ :: *;

(* synthesize *)
module mkTestWorkCompGenNormalCaseSQ(Empty);
    let isNormalCase = True;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

(* synthesize *)
module mkTestWorkCompGenErrFlushCaseSQ(Empty);
    let isNormalCase = False;
    let result <- mkTestWorkCompGenSQ(isNormalCase);
endmodule

module mkTestWorkCompGenSQ#(Bool isNormalCase)(Empty);
    function Bool workReqNeedDmaWriteResp(PendingWorkReq pwr);
        return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
    endfunction

    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    let cntrl <- mkSimController(qpType, pmtu);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkPendingWorkReqPipeOut(workReqPipeOutVec[0], pmtu);
    let pendingWorkReqPipeOut4Dut = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4DmaResp = existingPendingWorkReqPipeOutVec[1];
    // let pendingWorkReqPipeOut4Ref <- mkBufferN(2, existingPendingWorkReqPipeOutVec[2]);
    FIFOF#(PendingWorkReq) pendingWorkReqPipeOut4Ref <- mkFIFOF;
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        pendingWorkReqPipeOut4Dut, pendingWorkReqBuf
    );
    // PayloadConResp
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // WC requests
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4RespHandleInSQ <- mkFIFOF;

    // WC status from RQ
    FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;

    // DUT
    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        convertFifo2PipeOut(payloadConRespQ),
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
        convertFifo2PipeOut(wcGenReqQ4RespHandleInSQ),
        convertFifo2PipeOut(workCompStatusQFromRQ)
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule genPayloadConResp;
        let pendingWR = pendingWorkReqPipeOut4DmaResp.first;
        pendingWorkReqPipeOut4DmaResp.deq;

        if (workReqNeedDmaWriteResp(pendingWR)) begin
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            let payloadConResp = PayloadConResp {
                initiator: dontCareValue,
                dmaWriteResp: DmaWriteResp {
                    sqpn: cntrl.getSQPN,
                    psn : endPSN
                }
            };
            if (isNormalCase) begin
                payloadConRespQ.enq(payloadConResp);
            end
        end
    endrule

    rule filterWR;
        let pendingWR = pendingWorkReqBuf.fifoIfc.first;
        pendingWorkReqBuf.fifoIfc.deq;

        let wcWaitDmaResp = True;
        let wcReqType = isNormalCase ? WC_REQ_TYPE_SUC_FULL_ACK : WC_REQ_TYPE_ERR_FULL_ACK;
        let triggerPSN = unwrapMaybe(pendingWR.endPSN);
        let wcStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;

        let wcGenReq = WorkCompGenReqSQ {
            pendingWR: pendingWR,
            wcWaitDmaResp: wcWaitDmaResp,
            wcReqType: wcReqType,
            triggerPSN: triggerPSN,
            wcStatus: wcStatus
        };

        if (cntrl.isRTS && pendingWorkReqNeedWorkComp(pendingWR)) begin
            wcGenReqQ4RespHandleInSQ.enq(wcGenReq);
            pendingWorkReqPipeOut4Ref.enq(pendingWR);

            // $display(
            //     "time=%0d: submit to workCompGen pendingWR=",
            //     $time, fshow(pendingWR)
            // );
        end
        else if (cntrl.isERR) begin
            pendingWorkReqPipeOut4Ref.enq(pendingWR);
            // $display(
            //     "time=%0d: for reference pendingWR=",
            //     $time, fshow(pendingWR)
            // );
        end
    endrule

    rule compare;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        pendingWorkReqPipeOut4Ref.deq;

        let workCompSQ = workCompPipeOut.first;
        workCompPipeOut.deq;

        dynAssert(
            workCompMatchWorkReqInSQ(workCompSQ, pendingWR.wr),
            "workCompMatchWorkReqInSQ assertion @ mkTestWorkCompGenSQ",
            $format("WC=", fshow(workCompSQ), " not match WR=", fshow(pendingWR.wr))
        );

        let expectedWorkCompStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;
        dynAssert(
            workCompSQ.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestWorkCompGenSQ",
            $format(
                "WC=", fshow(workCompSQ), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0d: WC=", $time, fshow(workCompSQ), " not match WR=", fshow(pendingWR.wr)
        // );
    endrule
endmodule
