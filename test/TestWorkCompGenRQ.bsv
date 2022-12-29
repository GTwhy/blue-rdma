import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import Settings :: *;
import SimGenRdmaReqAndResp :: *;
import SpecialFIFOF :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGenRQ :: *;

(* synthesize *)
module mkTestWorkCompGenNormalCaseRQ(Empty);
    let isNormalCase = True;
    let result <- mkTestWorkCompGenRQ(isNormalCase);
endmodule

(* synthesize *)
module mkTestWorkCompGenErrFlushCaseRQ(Empty);
    let isNormalCase = False;
    let result <- mkTestWorkCompGenRQ(isNormalCase);
endmodule

module mkTestWorkCompGenRQ#(Bool isNormalCase)(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);
    // let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);

    // Generate RDMA requests
    let reqGenSQ <- mkSimGenRdmaReq(
        newPendingWorkReqPipeOut, qpType, pmtu
    );
    let sinkPendingWorkReq <- mkSink(reqGenSQ.pendingWorkReqPipeOut);
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let pktMetaDataPipeOut = pktMetaDataAndPayloadPipeOut.pktMetaData;
    let sinkReqPayload <- mkSink(pktMetaDataAndPayloadPipeOut.payload);

    // RecvReq
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;

    // PayloadConResp
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // WC requests
    FIFOF#(WorkCompGenReqRQ) workCompGenReqQ4RQ <- mkFIFOF;

    // DUT
    let dut <- mkWorkCompGenRQ(
        cntrl,
        convertFifo2PipeOut(payloadConRespQ),
        convertFifo2PipeOut(recvReqQ),
        convertFifo2PipeOut(workCompGenReqQ4RQ)
    );

    // RecvReq ID
    PipeOut#(WorkReqID) recvReqIdPipeOut <- mkGenericRandomPipeOut;

    // Expected WC
    FIFOF#(Tuple5#(
        WorkReqID, WorkCompOpCode, WorkCompFlags, Maybe#(IMM), Maybe#(RKEY)
    )) expectedWorkCompQ <- mkFIFOF;

    Reg#(WorkReqID) recvReqIdReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule genRecvReq4Flush if (cntrl.isERR);
        let rrID = recvReqIdPipeOut.first;
        recvReqIdPipeOut.deq;
        let rr = RecvReq {
            id   : rrID,
            len  : dontCareValue,
            laddr: dontCareValue,
            lkey : dontCareValue,
            sqpn : cntrl.getSQPN
        };
        recvReqQ.enq(rr);

        let noImmDt = tagged Invalid;
        let noRKey2Inv = tagged Invalid;
        expectedWorkCompQ.enq(tuple5(
            rrID, IBV_WC_RECV, IBV_WC_NO_FLAGS, noImmDt, noRKey2Inv
        ));
    endrule

    rule setCntrlErrState if (cntrl.isRTS);
        let wcStatus = dut.workCompStatusPipeOutRQ.first;
        dut.workCompStatusPipeOutRQ.deq;

        dynAssert(
            wcStatus != IBV_WC_SUCCESS,
            "wcStatus assertion @ mkTestWorkCompGenRQ",
            $format("wcStatus=", fshow(wcStatus), " should not be success")
        );
        cntrl.setStateErr;
    endrule

    rule genWorkCompReq4RQ if (cntrl.isNonErr);
        let pktMetaData = pktMetaDataPipeOut.first;
        pktMetaDataPipeOut.deq;

        let rdmaHeader = pktMetaData.pktHeader;
        let bth        = extractBTH(rdmaHeader.headerData);
        let isSendReq  = isSendReqRdmaOpCode(bth.opcode);
        let isWriteReq = isWriteReqRdmaOpCode(bth.opcode);
        let immDt      = extractImmDt(rdmaHeader.headerData, bth.trans);
        let ieth       = extractIETH(rdmaHeader.headerData, bth.trans);
        let hasImmDt   = rdmaReqHasImmDt(bth.opcode);
        let hasIETH    = rdmaReqHasIETH(bth.opcode);
        let payloadLen = pktMetaData.pktPayloadLen;
        let isZeroLen  = isZero(payloadLen);

        let isFirstOrOnlyReq = isFirstOrOnlyRdmaOpCode(bth.opcode);
        let isLastOrOnlyReq  = isLastOrOnlyRdmaOpCode(bth.opcode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);

        let maybeImmDt     = hasImmDt ? (tagged Valid immDt.data) : (tagged Invalid);
        let maybeRKey2Inv  = hasIETH ? (tagged Valid ieth.rkey) : (tagged Invalid);

        if (!isZeroLen && (isSendReq || isWriteReq)) begin
            let payloadConResp = PayloadConResp {
                initiator: dontCareValue,
                dmaWriteResp: DmaWriteResp {
                    sqpn: cntrl.getSQPN,
                    psn : bth.psn
                }
            };
            if (isNormalCase) begin
                payloadConRespQ.enq(payloadConResp);
            end
        end

        let maybeRecvReqID = tagged Invalid;
        let recvReqID = recvReqIdReg;
        if (isSendReq) begin
            if (isFirstOrOnlyReq) begin
                recvReqID = recvReqIdPipeOut.first;
                recvReqIdPipeOut.deq;
                recvReqIdReg <= recvReqID;
            end
            maybeRecvReqID = tagged Valid recvReqID;

            if (isLastOrOnlyReq) begin
                let wcFlags = hasImmDt ? IBV_WC_WITH_IMM : (hasIETH ? IBV_WC_WITH_INV : IBV_WC_NO_FLAGS);
                expectedWorkCompQ.enq(tuple5(recvReqID, IBV_WC_RECV, wcFlags, maybeImmDt, maybeRKey2Inv));
            end
        end
        else if (isWriteImmReq) begin
            recvReqID = recvReqIdPipeOut.first;
            recvReqIdPipeOut.deq;
            maybeRecvReqID = tagged Valid recvReqID;

            let noRKey2Inv = tagged Invalid;
            expectedWorkCompQ.enq(tuple5(
                recvReqID, IBV_WC_RECV_RDMA_WITH_IMM, IBV_WC_WITH_IMM, maybeImmDt, noRKey2Inv
            ));
        end

        let workCompReq = WorkCompGenReqRQ {
            rrID        : maybeRecvReqID,
            len         : zeroExtend(payloadLen),
            sqpn        : cntrl.getSQPN,
            reqPSN      : bth.psn,
            isZeroDmaLen: isZeroLen,
            wcStatus    : isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR,
            reqOpCode   : bth.opcode,
            immDt       : maybeImmDt,
            rkey2Inv    : maybeRKey2Inv
        };

        workCompGenReqQ4RQ.enq(workCompReq);

        // $display("time=%0d: workCompReq=", $time, fshow(workCompReq));
    endrule

    rule compare;
        let { recvReqID, wcOpCode, wcFlags, maybeImmDt, maybeRKey2Inv } = expectedWorkCompQ.first;
        expectedWorkCompQ.deq;

        let workCompRQ = dut.workCompPipeOut.first;
        dut.workCompPipeOut.deq;

        dynAssert(
            workCompRQ.id == recvReqID,
            "workCompRQ.id assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC id=", fshow(workCompRQ.id),
                " not match expected WC recvReqID=", fshow(recvReqID))
        );

        dynAssert(
            workCompRQ.opcode == wcOpCode,
            "workCompRQ.opcode assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC opcode=", fshow(workCompRQ.opcode),
                " not match expected WC opcode=", fshow(wcOpCode))
        );

        dynAssert(
            workCompRQ.flags == wcFlags,
            "workCompRQ.flags assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC flags=", fshow(workCompRQ.flags),
                " not match expected WC flags=", fshow(wcFlags))
        );

        dynAssert(
            workCompRQ.immDt == maybeImmDt,
            "workCompRQ.immDt assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC immDt=", fshow(workCompRQ.immDt),
                " not match expected WC immDt=", fshow(maybeImmDt))
        );

        dynAssert(
            workCompRQ.rkey2Inv == maybeRKey2Inv,
            "workCompRQ.rkey2Inv assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC rkey2Inv=", fshow(workCompRQ.rkey2Inv),
                " not match expected WC rkey2Inv=", fshow(maybeRKey2Inv))
        );

        let expectedWorkCompStatus = isNormalCase ? IBV_WC_SUCCESS : IBV_WC_WR_FLUSH_ERR;
        dynAssert(
            workCompRQ.status == expectedWorkCompStatus,
            "workCompRQ.status assertion @ mkTestWorkCompGenRQ",
            $format(
                "WC status=", fshow(workCompRQ.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display("time=%0d: WC=", $time, fshow(workCompRQ));
    endrule
endmodule
