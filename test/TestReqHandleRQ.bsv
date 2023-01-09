// import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import ReqHandleRQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaReqAndResp :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGen :: *;

function Rules genNoPendingWorkReqOutRule(PipeOut#(PendingWorkReq) pendingWorkReqPipeOut);
    return (
        rules
            rule noPendingWorkReqOut;
                dynAssert(
                    !pendingWorkReqPipeOut.notEmpty,
                    "pendingWorkReqPipeOut empty assertion @ genNoPendingWorkReqOutRule",
                    $format(
                        "pendingWorkReqPipeOut.notEmpty=",
                        fshow(pendingWorkReqPipeOut.notEmpty),
                        " should be empty"
                    )
                );
            endrule
        endrules
    );
endfunction

(* synthesize *)
module mkTestReqHandleNormalCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4Req = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(8, existingPendingWorkReqPipeOutVec[1]);
    let pendingWorkReqPipeOut4Resp <- mkBufferN(8, existingPendingWorkReqPipeOutVec[2]);

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReqAndSendWritePayloadPipeOut(
        pendingWorkReqPipeOut4Req, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(
        genNoPendingWorkReqOutRule(simReqGen.pendingWorkReqPipeOut)
    );
    // Segment send/write payload DMA read DataStream
    let sendWriteReqPayloadPipeOutBuf <- mkBufferN(32, simReqGen.sendWriteReqPayloadPipeOut);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let sendWritePayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        sendWriteReqPayloadPipeOutBuf, pmtuPipeOut
    );

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckMR <- mkSimPermCheckMR(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrl);

    // RecvReq
    Vector#(1, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq(cntrl);
    let recvReqBuf = recvReqBufVec[0];
    // let recvReqBuf4Ref <- mkBufferN(1024, recvReqBufVec[1]);

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl,
        simDmaReadSrv,
        permCheckMR,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let sendWritePayloadPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        pktMetaDataAndPayloadPipeOut.payload,
        simDmaWriteSrv.dmaWriteSrv,
        dut.payloadConReqPipeOut
    );

    // WorkCompGenRQ
    FIFOF#(WorkCompGenReqRQ) wcGenReqQ4ReqGenInRQ <- mkFIFOF;
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrl,
        payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;

    // Vector#(2, PipeOut#(WorkComp)) workCompPipeOutVec <-
    //     mkForkVector(workCompGenRQ.workCompPipeOut);
    // let workCompPipeOut4RecvReq = workCompPipeOutVec[0];
    // let workCompPipeOut4WorkReq = workCompPipeOutVec[1];

    // PipeOut need to handle:
    // - sendWritePayloadPipeOut
    // - sendWritePayloadPipeOut4Ref
    // - pktMetaDataAndPayloadPipeOut.payload
    // - dut.payloadConReqPipeOut
    // - payloadConsumer.respPipeOut
    // - dut.workCompGenReqPipeOut
    // - pendingWorkReqPipeOut
    // - dut.rdmaRespDataStreamPipeOut
    // - workCompGenRQ.workCompPipeOut

    // let sinkSendWritePayload4Ref <- mkSink(sendWritePayloadPipeOut4Ref);
    // let sinkSendWritePayload <- mkSink(sendWritePayloadPipeOut);
    // let sinkPendingWR4WorkComp <- mkSink(pendingWorkReqPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut4WorkReq);
    // let sinkPayloadConResp <- mkSink(payloadConsumer.respPipeOut);
    // let sinkWorkCompGenReq <- mkSink(dut.workCompGenReqPipeOut);
    // let sinkPendingWR4Resp <- mkSink(pendingWorkReqPipeOut4Resp);
    // let sinkRdmaResp <- mkSink(dut.rdmaRespDataStreamPipeOut);

    rule compareSendWriteReqPayload;
        let sendWritePayloadDataStreamRef = sendWritePayloadPipeOut4Ref.first;
        sendWritePayloadPipeOut4Ref.deq;

        let sendWritePayloadDataStream = sendWritePayloadPipeOut.first;
        sendWritePayloadPipeOut.deq;

        dynAssert(
            sendWritePayloadDataStream == sendWritePayloadDataStreamRef,
            "sendWritePayloadDataStream assertion @ mkTestReqHandleNormalCase",
            $format(
                "sendWritePayloadDataStream=",
                fshow(sendWritePayloadDataStream),
                " should == sendWritePayloadDataStreamRef=",
                fshow(sendWritePayloadDataStreamRef)
            )
        );
        // $display(
        //     "time=%0d: sendWritePayloadDataStream=", $time,
        //     fshow(sendWritePayloadDataStream),
        //     " should == sendWritePayloadDataStreamRef=",
        //     fshow(sendWritePayloadDataStreamRef)
        // );
    endrule
/*
    rule show;
        let sendWritePayloadDataStreamRef = sendWritePayloadPipeOut.first;
        sendWritePayloadPipeOut.deq;

        $display(
            "time=%0d: sendWritePayloadDataStreamRef.isFirst=",
            $time, fshow(sendWritePayloadDataStreamRef.isFirst),
            ", sendWritePayloadDataStreamRef.isLast=",
            fshow(sendWritePayloadDataStreamRef.isLast),
            ", sendWritePayloadDataStreamRef.byteEn=%h",
            sendWritePayloadDataStreamRef.byteEn
        );
    endrule

    rule compareWorkCompWithRecvReq;
        let rr = recvReqBuf4Ref.first;
        recvReqBuf4Ref.deq;

        let wc = workCompPipeOut4RecvReq.first;
        workCompPipeOut4RecvReq.deq;

        dynAssert(
            wc.id == rr.id,
            "WC ID assertion @ mkTestReqHandleNormalCase",
            $format(
                "wc.id=%h should == rr.id=%h",
                wc.id, rr.id
            )
        );

        dynAssert(
            wc.status == IBV_WC_SUCCESS,
            "WC status assertion @ mkTestReqHandleNormalCase",
            $format(
                "wc.status=", fshow(wc.status),
                " should be success"
            )
        );
    endrule
*/
    rule compareWorkCompWithPendingWorkReq;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        // $display("time=%0d: pendingWR=", $time, fshow(pendingWR));

        if (workReqNeedRecvReq(pendingWR.wr.opcode)) begin
            let wc = workCompPipeOut4WorkReq.first;
            workCompPipeOut4WorkReq.deq;

            dynAssert(
                workCompMatchWorkReqInRQ(wc, pendingWR.wr),
                "workCompMatchWorkReqInRQ assertion @ mkTestReqHandleNormalCase",
                $format("WC=", fshow(wc), " not match WR=", fshow(pendingWR.wr))
            );
            // $display("time=%0d: WC=", $time, fshow(wc));

            if (workReqHasImmDt(pendingWR.wr.opcode)) begin
                dynAssert(
                    isValid(wc.immDt) && isValid(pendingWR.wr.immDt) &&
                    !isValid(wc.rkey2Inv) && !isValid(pendingWR.wr.rkey2Inv),
                    "WC has ImmDT assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.immDt=", fshow(wc.immDt),
                        " should be valid, and wc.rkey2Inv=",
                        fshow(wc.rkey2Inv), " should be invalid"
                    )
                );
                // TODO: fix this assertion
                dynAssert(
                    unwrapMaybe(pendingWR.wr.immDt) == unwrapMaybe(wc.immDt),
                    "wc.immDt equal assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.immDt=", fshow(unwrapMaybe(wc.immDt)),
                        " should == pendingWR.wr.immDt=",
                        fshow(unwrapMaybe(pendingWR.wr.immDt))
                    )
                );
            end
            else if (workReqHasInv(pendingWR.wr.opcode)) begin
                dynAssert(
                    !isValid(wc.immDt) && !isValid(pendingWR.wr.immDt) &&
                    isValid(wc.rkey2Inv) && isValid(pendingWR.wr.rkey2Inv),
                    "WC has IETH assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.rkey2Inv=", fshow(wc.rkey2Inv),
                        " should be valid, and wc.immDt=",
                        fshow(wc.immDt), " should be invalid"
                    )
                );
                dynAssert(
                    unwrapMaybe(pendingWR.wr.rkey2Inv) == unwrapMaybe(wc.rkey2Inv),
                    "wc.rkey2Inv equal assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.rkey2Inv=", fshow(unwrapMaybe(wc.rkey2Inv)),
                        " should == pendingWR.wr.rkey2Inv=",
                        fshow(unwrapMaybe(pendingWR.wr.rkey2Inv))
                    )
                );
            end
            else begin
                dynAssert(
                    !isValid(wc.immDt) &&
                    !isValid(wc.rkey2Inv),
                    "WC has no ImmDT or IETH assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "both wc.immDt=", fshow(wc.immDt),
                        " and wc.rkey2Inv=", fshow(wc.rkey2Inv),
                        " should be invalid"
                    )
                );
            end
        end
    endrule

    rule compareResp;
        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let pendingWR = pendingWorkReqPipeOut4Resp.first;

        if (rdmaRespDataStream.isFirst) begin
            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let endPSN = unwrapMaybe(pendingWR.endPSN);

            // || psnInRangeExclusive(bth.psn, endPSN, cntrl.contextRQ.getEPSN)
            if (bth.psn == endPSN) begin
                pendingWorkReqPipeOut4Resp.deq;
            end

            if (rdmaRespHasAETH(bth.opcode)) begin
                let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                dynAssert(
                    aeth.code == AETH_CODE_ACK,
                    "aeth.code assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "aeth.code=", fshow(aeth.code),
                        " should be normal ACK"
                    )
                );

                // $display(
                //     "time=%0d: response bth=", $time, fshow(bth),
                //     ", aeth=", fshow(aeth)
                // );
            end
            else begin
                // $display("time=%0d: response bth=", $time, fshow(bth));
                // $display("time=%0d: pendingWR=", $time, fshow(pendingWR));
            end
        end
    endrule

    // rule noPendingWorkReqOutFromReqGenSQ;
    //     dynAssert(
    //         !simReqGen.pendingWorkReqPipeOut.notEmpty,
    //         "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "simReqGen.pendingWorkReqPipeOut.notEmpty=",
    //             fshow(simReqGen.pendingWorkReqPipeOut.notEmpty),
    //             " should be empty"
    //         )
    //     );
    // endrule
endmodule

typedef enum {
    REQ_HANDLE_ERROR_RESP,
    REQ_HANDLE_PERM_CHECK_FAIL
} ReqHandleErrType deriving(Bits, Eq);

(* synthesize *)
module mkTestReqHandleReqErrCase(Empty);
    let errType = REQ_HANDLE_ERROR_RESP;
    let result <- mkTestReqHandleAbnormalCase(errType);
endmodule

(* synthesize *)
module mkTestReqHandlePermCheckFailCase(Empty);
    let errType = REQ_HANDLE_PERM_CHECK_FAIL;
    let result <- mkTestReqHandleAbnormalCase(errType);
endmodule

module mkTestReqHandleAbnormalCase#(ReqHandleErrType errType)(Empty);
    function Bool isIllegalAtomicWorkReq(WorkReq wr);
        let isAtomicWR = isAtomicWorkReq(wr.opcode);
        let isAlignedAddr = isAlignedAtomicAddr(wr.raddr);
        return isAtomicWR && !isAlignedAddr;
    endfunction

    let minPayloadLen = 1;
    let maxPayloadLen = 31;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);

    // WorkReq generation
    Vector#(1, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    let selectPipeOut4WorkReqGen = selectPipeOutVec[0];
    Vector#(1, PipeOut#(WorkReq)) normalWorkReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    let workReqPipeOut = case (errType)
        REQ_HANDLE_PERM_CHECK_FAIL: begin
            normalWorkReqPipeOutVec[0];
        end
        default: begin
            muxPipeOut2(
                selectPipeOut4WorkReqGen,
                normalWorkReqPipeOutVec[0],
                illegalAtomicWorkReqPipeOut
            );
        end
    endcase;
    // Pending WR generation
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut4Req = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Resp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        pendingWorkReqPipeOut4Req, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(
        genNoPendingWorkReqOutRule(simReqGen.pendingWorkReqPipeOut)
    );

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = !(errType == REQ_HANDLE_PERM_CHECK_FAIL);
    let permCheckMR <- mkSimPermCheckMR(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrl);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq(cntrl);
    let recvReqBuf = recvReqBufVec[0];
    let recvReqBuf4Ref <- mkBufferN(8, recvReqBufVec[1]);

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl,
        simDmaReadSrv,
        permCheckMR,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        pktMetaDataAndPayloadPipeOut.payload,
        simDmaWriteSrv,
        dut.payloadConReqPipeOut
    );

    // WorkCompGenRQ
    FIFOF#(WorkCompGenReqRQ) wcGenReqQ4ReqGenInRQ <- mkFIFOF;
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrl,
        payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;

    Reg#(Bool) firstErrRdmaRespGenReg <- mkReg(False);
    Reg#(Bool) firstErrWorkCompGenReg <- mkReg(False);

    // let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // let sinkPendingWR4Resp <- mkSink(pendingWorkReqPipeOut4Resp);
    // let sinkSelect4Resp <- mkSink(selectPipeOut4Resp);
    // let sinkRdmaResp <- mkSink(dut.rdmaRespDataStreamPipeOut);
    // let sinkPendingWR4WorkComp <- mkSink(pendingWorkReqPipeOut4WorkComp);
    // let sinkSelect4WorkComp <- mkSink(selectPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut4WorkReq);

    // TODO: check workCompGenRQ.wcStatusQ4SQ has exact one error WC status
/*
    rule show;
        let wc = workCompPipeOut4WorkReq.first;
        workCompPipeOut4WorkReq.deq;

        $display(
            "time=%0d: WC=", $time, fshow(wc)
        );
    endrule
*/
    rule compareRespBeforeFatalErr;
        let pendingWR = pendingWorkReqPipeOut4Resp.first;

        if (firstErrRdmaRespGenReg) begin
            pendingWorkReqPipeOut4Resp.deq;

            dynAssert(
                !dut.rdmaRespDataStreamPipeOut.notEmpty,
                "dut.rdmaRespDataStreamPipeOut.notEmpty assertion @ mkTestReqHandleAbnormalCase",
                $format(
                    "dut.rdmaRespDataStreamPipeOut.notEmpty=",
                    fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
                    " should be false, when firstErrRdmaRespGenReg=",
                    fshow(firstErrRdmaRespGenReg)
                )
            );
        end
        else begin
            let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
            dut.rdmaRespDataStreamPipeOut.deq;

            if (rdmaRespDataStream.isFirst) begin
                let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
                let endPSN = unwrapMaybe(pendingWR.endPSN);

                // Each WR set AckReq
                if (bth.psn == endPSN) begin
                    pendingWorkReqPipeOut4Resp.deq;
                end

                if (rdmaRespHasAETH(bth.opcode)) begin
                    let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                    if (aeth.code != AETH_CODE_ACK) begin
                        firstErrRdmaRespGenReg <= True;

                        dynAssert(
                            rdmaRespDataStream.isLast,
                            "rdmaRespDataStream.isLast assertion @ mkTestReqHandleAbnormalCase",
                            $format(
                                "rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                                " should be true, when pendingWR.wr.opcode=", fshow(pendingWR.wr.opcode)
                            )
                        );

                        if (errType == REQ_HANDLE_PERM_CHECK_FAIL) begin
                            dynAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_RMT_ACC)),
                                "aeth.code assertion @ mkTestReqHandleAbnormalCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_RMT_ACC"
                                )
                            );
                        end
                        else begin
                            dynAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_INV_RD)),
                                "aeth.code assertion @ mkTestReqHandleAbnormalCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_INV_RD"
                                )
                            );
                        end
                        // $display(
                        //     "time=%0d: response bth=", $time, fshow(bth),
                        //     ", aeth=", fshow(aeth)
                        // );
                    end
                end
            end
        end
    endrule

    rule compareWorkComp;
        let workComp = workCompPipeOut4WorkReq.first;
        workCompPipeOut4WorkReq.deq;

        let recvReq = recvReqBuf4Ref.first;
        recvReqBuf4Ref.deq;

        if (firstErrWorkCompGenReg) begin
            dynAssert(
                workComp.status == IBV_WC_WR_FLUSH_ERR,
                "WC status assertion @ mkTestReqHandleAbnormalCase",
                $format(
                    "workComp.status=", fshow(workComp.status),
                    " should be IBV_WC_WR_FLUSH_ERR, when firstErrWorkCompGenReg=",
                    fshow(firstErrWorkCompGenReg)
                )
            );
        end
        else if (workComp.status != IBV_WC_SUCCESS) begin
            firstErrWorkCompGenReg <= True;
        end

        dynAssert(
            workComp.id == recvReq.id,
            "WC ID assertion @ mkTestReqHandleAbnormalCase",
            $format(
                "workComp.id=%h should == recvReq.id=%h, when firstErrWorkCompGenReg=",
                workComp.id, recvReq.id, fshow(firstErrWorkCompGenReg)
            )
        );
        // $display("time=%0d: WC status=", $time, fshow(workComp.status));
    endrule
/*
    rule compareResp;
        let pendingWR = pendingWorkReqPipeOut4Resp.first;
        let selectLegalWorkReq = selectPipeOut4Resp.first;

        if (firstErrRdmaRespGenReg) begin
            pendingWorkReqPipeOut4Resp.deq;
            selectPipeOut4Resp.deq;

            dynAssert(
                !dut.rdmaRespDataStreamPipeOut.notEmpty,
                "dut.rdmaRespDataStreamPipeOut.notEmpty assertion @ mkTestReqHandleFatalErrCase",
                $format(
                    "dut.rdmaRespDataStreamPipeOut.notEmpty=",
                    fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
                    " should be false, when firstErrRdmaRespGenReg=",
                    fshow(firstErrRdmaRespGenReg)
                )
            );
        end
        else begin
            let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
            dut.rdmaRespDataStreamPipeOut.deq;

            if (rdmaRespDataStream.isFirst) begin
                let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
                let endPSN = unwrapMaybe(pendingWR.endPSN);

                // Each WR set AckReq
                if (bth.psn == endPSN) begin
                    pendingWorkReqPipeOut4Resp.deq;
                    selectPipeOut4Resp.deq;
                end

                let hasErrResp = selectLegalWorkReq;
                if (errType == REQ_HANDLE_PERM_CHECK_FAIL) begin
                    if (rdmaRespHasAETH(bth.opcode)) begin
                        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                        if (aeth.code != AETH_CODE_ACK) begin
                            hasErrResp = True;

                            dynAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_RMT_ACC)),
                                "aeth.code assertion @ mkTestReqHandleFatalErrCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_RMT_ACC"
                                )
                            );
                        end
                        // $display(
                        //     "time=%0d: response bth=", $time, fshow(bth),
                        //     ", aeth=", fshow(aeth)
                        // );
                    end
                end
                else if (selectLegalWorkReq) begin
                    if (rdmaRespHasAETH(bth.opcode)) begin
                        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                        dynAssert(
                            aeth.code == AETH_CODE_ACK,
                            "aeth.code assertion @ mkTestReqHandleFatalErrCase",
                            $format(
                                "aeth.code=", fshow(aeth.code),
                                " should be normal ACK"
                            )
                        );
                        // $display(
                        //     "time=%0d: response bth=", $time, fshow(bth),
                        //     ", aeth=", fshow(aeth)
                        // );
                    end
                end

                if (hasErrResp) begin
                    firstErrRdmaRespGenReg <= True;

                    dynAssert(
                        rdmaRespDataStream.isLast,
                        "rdmaRespDataStream.isLast assertion @ mkTestReqHandleFatalErrCase",
                        $format(
                            "rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                            " should be true, when selectLegalWorkReq=", fshow(selectLegalWorkReq),
                            " and pendingWR.wr.opcode=", fshow(pendingWR.wr.opcode)
                        )
                    );

                    let hasAETH = rdmaRespHasAETH(bth.opcode);
                    dynAssert(
                        hasAETH,
                        "hasAETH assertion @ mkTestReqHandleFatalErrCase",
                        $format(
                            "hasAETH=", fshow(hasAETH),
                            " should be true, when selectLegalWorkReq=",
                            fshow(selectLegalWorkReq)
                        )
                    );

                    let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                    dynAssert(
                        isFatalErrAETH(aeth),
                        "AETH assertion @ mkTestReqHandleFatalErrCase",
                        $format(
                            "AETH=", fshow(aeth), " should be fatal error"
                        )
                    );
                    // $display("time=%0d: response bth=", $time, fshow(bth));
                    // $display("time=%0d: pendingWR=", $time, fshow(pendingWR));
                end
            end
        end
    endrule

    rule compareWorkCompBeforeFatalErr if (!firstIllegalWorkReqReg);
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        let selectLegalWorkReq = selectPipeOut4WorkComp.first;
        selectPipeOut4WorkComp.deq;

        if (selectLegalWorkReq) begin
            if (workReqNeedRecvReq(pendingWR.wr.opcode)) begin
                let workComp = workCompPipeOut4WorkReq.first;
                workCompPipeOut4WorkReq.deq;
                let recvReq = recvReqBuf4Ref.first;
                recvReqBuf4Ref.deq;

                dynAssert(
                    workComp.status == IBV_WC_SUCCESS,
                    "WC status assertion @ mkTestReqHandleFatalErrCase",
                    $format(
                        "workComp.status=", fshow(workComp.status),
                        " should be success, when firstIllegalWorkReqReg=",
                        fshow(firstIllegalWorkReqReg)
                    )
                );
                dynAssert(
                    workComp.id == recvReq.id,
                    "WC ID assertion @ mkTestReqHandleFatalErrCase",
                    $format(
                        "workComp.id=%h should == recvReq.id=%h, when firstIllegalWorkReqReg=",
                        workComp.id, recvReq.id, fshow(firstIllegalWorkReqReg)
                    )
                );
            end
        end
        else begin
            firstIllegalWorkReqReg <= True;
        end
        // $display("time=%0d: WC status=", $time, fshow(workComp.status));
    endrule

    // TODO: flush all RR
    rule compareRecvReqAfterFatalErr if (firstIllegalWorkReqReg);
        let workComp = workCompPipeOut4WorkReq.first;
        workCompPipeOut4WorkReq.deq;

        let recvReq = recvReqBuf4Ref.first;
        recvReqBuf4Ref.deq;

        dynAssert(
            workComp.status == IBV_WC_WR_FLUSH_ERR,
            "WC status assertion @ mkTestReqHandleFatalErrCase",
            $format(
                "WC status=", fshow(workComp.status),
                " should be error flush, when firstIllegalWorkReqReg=",
                fshow(firstIllegalWorkReqReg)
            )
        );
        dynAssert(
            workComp.id == recvReq.id,
            "WC ID assertion @ mkTestReqHandleFatalErrCase",
            $format(
                "workComp.id=%h should == recvReq.id=%h, when firstIllegalWorkReqReg=",
                workComp.id, recvReq.id, fshow(firstIllegalWorkReqReg)
            )
        );

        // countDown.decr;
    endrule

    rule sinkPendingWorkReqAfterFatalErr if (firstIllegalWorkReqReg);
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        let selectLegalWorkReq = selectPipeOut4WorkComp.first;
        selectPipeOut4WorkComp.deq;
    endrule
*/
endmodule
