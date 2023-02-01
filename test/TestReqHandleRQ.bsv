// import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

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
/*
(* synthesize *)
module mkTestReqHandleNormalCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
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
    let sendWriteReqPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
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
    let sendWriteReqPayloadPipeOut = simDmaWriteSrv.dataStream;
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
    // - sendWriteReqPayloadPipeOut
    // - sendWriteReqPayloadPipeOut4Ref
    // - pktMetaDataAndPayloadPipeOut.payload
    // - dut.payloadConReqPipeOut
    // - payloadConsumer.respPipeOut
    // - dut.workCompGenReqPipeOut
    // - pendingWorkReqPipeOut
    // - dut.rdmaRespDataStreamPipeOut
    // - workCompGenRQ.workCompPipeOut

    // let sinkSendWritePayload4Ref <- mkSink(sendWriteReqPayloadPipeOut4Ref);
    // let sinkSendWritePayload <- mkSink(sendWriteReqPayloadPipeOut);
    // let sinkPendingWR4WorkComp <- mkSink(pendingWorkReqPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut4WorkReq);
    // let sinkPayloadConResp <- mkSink(payloadConsumer.respPipeOut);
    // let sinkWorkCompGenReq <- mkSink(dut.workCompGenReqPipeOut);
    // let sinkPendingWR4Resp <- mkSink(pendingWorkReqPipeOut4Resp);
    // let sinkRdmaResp <- mkSink(dut.rdmaRespDataStreamPipeOut);

    rule compareSendWriteReqPayload;
        let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut4Ref.first;
        sendWriteReqPayloadPipeOut4Ref.deq;

        let sendWritePayloadDataStream = sendWriteReqPayloadPipeOut.first;
        sendWriteReqPayloadPipeOut.deq;

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

    // rule show;
    //     let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut.first;
    //     sendWriteReqPayloadPipeOut.deq;

    //     $display(
    //         "time=%0d: sendWritePayloadDataStreamRef.isFirst=",
    //         $time, fshow(sendWritePayloadDataStreamRef.isFirst),
    //         ", sendWritePayloadDataStreamRef.isLast=",
    //         fshow(sendWritePayloadDataStreamRef.isLast),
    //         ", sendWritePayloadDataStreamRef.byteEn=%h",
    //         sendWritePayloadDataStreamRef.byteEn
    //     );
    // endrule

    // rule compareWorkCompWithRecvReq;
    //     let rr = recvReqBuf4Ref.first;
    //     recvReqBuf4Ref.deq;

    //     let wc = workCompPipeOut4RecvReq.first;
    //     workCompPipeOut4RecvReq.deq;

    //     dynAssert(
    //         wc.id == rr.id,
    //         "WC ID assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.id=%h should == rr.id=%h",
    //             wc.id, rr.id
    //         )
    //     );

    //     dynAssert(
    //         wc.status == IBV_WC_SUCCESS,
    //         "WC status assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.status=", fshow(wc.status),
    //             " should be success"
    //         )
    //     );
    // endrule

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

                let wrImmDt = unwrapMaybe(pendingWR.wr.immDt);
                let wcImmDt = unwrapMaybe(wc.immDt);
                dynAssert(
                    wrImmDt == wcImmDt,
                    "wc.immDt equal assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.immDt=", fshow(wcImmDt),
                        " should == pendingWR.wr.immDt=",
                        fshow(wrImmDt)
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
endmodule
*/
(* synthesize *)
module mkTestReqHandleNormalReqCase(Empty);
    let normalOrDupReq = True;
    let result <- mkTestReqHandleNormalAndDupReqCase(normalOrDupReq);
endmodule

(* synthesize *)
module mkTestReqHandleDupReqCase(Empty);
    let normalOrDupReq = False;
    let result <- mkTestReqHandleNormalAndDupReqCase(normalOrDupReq);
endmodule

module mkNonZeroSendWriteReqPayloadPipeOut#(
    PipeOut#(Bool) filterPipeIn,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeOut,
    DataStreamPipeOut dataStreamPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) dataStreamOutQ <- mkFIFOF;

    rule filterDataStream;
        let select = filterPipeIn.first;
        let pendingWR = pendingWorkReqPipeOut.first;
        let isNonZeroSendWriteWR = workReqNeedDmaReadSQ(pendingWR.wr);

        if (isNonZeroSendWriteWR) begin
            let dataStream = dataStreamPipeIn.first;
            dataStreamPipeIn.deq;

            if (select) begin
                dataStreamOutQ.enq(dataStream);
            end

            if (dataStream.isLast) begin
                filterPipeIn.deq;
                pendingWorkReqPipeOut.deq;
            end
        end
        else begin
            filterPipeIn.deq;
            pendingWorkReqPipeOut.deq;
        end
    endrule

    return convertFifo2PipeOut(dataStreamOutQ);
endmodule

module mkTestReqHandleNormalAndDupReqCase#(Bool normalOrDupReq)(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let workReqPipeOut = workReqPipeOutVec[0];
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let { normalOrDupReqSelPipeOut, normalOrDupPendingWorkReqPipeOut } <- mkGenNormalOrDupWorkReq(
        normalOrDupReq, existingPendingWorkReqPipeOutVec[0]
    );
    Vector#(3, PipeOut#(Bool)) normalOrDupReqSelPipeOutVec <-
        mkForkVector(normalOrDupReqSelPipeOut);
    let normalOrDupReqSelPipeOut4WorkComp <- mkBufferN(8, normalOrDupReqSelPipeOutVec[0]);
    let normalOrDupReqSelPipeOut4Resp <- mkBufferN(8, normalOrDupReqSelPipeOutVec[1]);
    let normalOrDupReqSelPipeOut4SendWriteReq <- mkBufferN(8, normalOrDupReqSelPipeOutVec[2]);
    Vector#(4, PipeOut#(PendingWorkReq)) normalOrDupPendingWorkReqPipeOutVec <-
        mkForkVector(normalOrDupPendingWorkReqPipeOut);
    let normalOrDupPendingWorkReqPipeOut4ReqGen = normalOrDupPendingWorkReqPipeOutVec[0];
    let normalOrDupPendingWorkReqPipeOut4WorkComp <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[1]);
    let normalOrDupPendingWorkReqPipeOut4Resp <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[2]);
    let normalOrDupPendingWorkReqPipeOut4SendWriteReq <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[3]);

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;
    // TODO: check read response payload
    // let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // let readRespPayloadPipeOutBuf <- mkBufferN(32, simDmaReadSrv.dataStream);
    // let pmtuPipeOut4ReadResp <- mkConstantPipeOut(pmtu);
    // let readRespPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
    //     readRespPayloadPipeOutBuf, pmtuPipeOut4ReadResp
    // );

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReqAndSendWritePayloadPipeOut(
        normalOrDupPendingWorkReqPipeOut4ReqGen, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(
        genNoPendingWorkReqOutRule(simReqGen.pendingWorkReqPipeOut)
    );
    // Segment send/write payload DMA read DataStream
    let normalSendWriteReqPayloadPipeOut <- mkNonZeroSendWriteReqPayloadPipeOut(
        normalOrDupReqSelPipeOut4SendWriteReq,
        normalOrDupPendingWorkReqPipeOut4SendWriteReq,
        simReqGen.sendWriteReqPayloadPipeOut
    );
    let sendWriteReqPayloadPipeOutBuf <- mkBufferN(32, normalSendWriteReqPayloadPipeOut);
    let pmtuPipeOut4SendWriteReq <- mkConstantPipeOut(pmtu);
    let sendWriteReqPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        sendWriteReqPayloadPipeOutBuf, pmtuPipeOut4SendWriteReq
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
    let sendWriteReqPayloadPipeOut = simDmaWriteSrv.dataStream;
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

    Reg#(Long) normalAtomicRespOrigReg <- mkRegU;

    // PipeOut need to handle:
    // let sinkNormalOrDupReqSel4SendWriteReq <- mkSink(normalOrDupReqSelPipeOut4SendWriteReq);
    // let sinkNormalOrDupPendingWorkReq4SendWriteReq <- mkSink(normalOrDupPendingWorkReqPipeOut4SendWriteReq);
    // let sinkSendWritePayloadOrig <- mkSink(simReqGen.sendWriteReqPayloadPipeOut);
    // let sinkSendWritePayload4Ref <- mkSink(sendWriteReqPayloadPipeOut4Ref);
    // let sinkSendWritePayload <- mkSink(sendWriteReqPayloadPipeOut);
    // let sinkNormalOrDupReqSel4WorkComp <- mkSink(normalOrDupReqSelPipeOut4WorkComp)
    // let sinkPendingWR4WorkComp <- mkSink(normalOrDupPendingWorkReqPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut4WorkReq);
    // let sinkPayloadConResp <- mkSink(payloadConsumer.respPipeOut);
    // let sinkWorkCompGenReq <- mkSink(dut.workCompGenReqPipeOut);
    // let sinkPendingWR4Resp <- mkSink(normalOrDupPendingWorkReqPipeOut4Resp);
    // let sinkRdmaResp <- mkSink(dut.rdmaRespDataStreamPipeOut);
    // let sink <- mkSink(normalOrDupReqSelPipeOut4Resp);

    // rule show;
    //     let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut.first;
    //     sendWriteReqPayloadPipeOut.deq;

    //     $display(
    //         "time=%0d: sendWritePayloadDataStreamRef.isFirst=",
    //         $time, fshow(sendWritePayloadDataStreamRef.isFirst),
    //         ", sendWritePayloadDataStreamRef.isLast=",
    //         fshow(sendWritePayloadDataStreamRef.isLast),
    //         ", sendWritePayloadDataStreamRef.byteEn=%h",
    //         sendWritePayloadDataStreamRef.byteEn
    //     );
    // endrule

    // TODO: compare RR and WC
    // rule compareWorkCompWithRecvReq;
    //     let rr = recvReqBuf4Ref.first;
    //     recvReqBuf4Ref.deq;

    //     let wc = workCompPipeOut4RecvReq.first;
    //     workCompPipeOut4RecvReq.deq;

    //     dynAssert(
    //         wc.id == rr.id,
    //         "WC ID assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.id=%h should == rr.id=%h",
    //             wc.id, rr.id
    //         )
    //     );

    //     dynAssert(
    //         wc.status == IBV_WC_SUCCESS,
    //         "WC status assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.status=", fshow(wc.status),
    //             " should be success"
    //         )
    //     );
    // endrule

    rule compareSendWriteReqPayload;
        let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut4Ref.first;
        sendWriteReqPayloadPipeOut4Ref.deq;

        let sendWritePayloadDataStream = sendWriteReqPayloadPipeOut.first;
        sendWriteReqPayloadPipeOut.deq;

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

    rule compareWorkCompWithPendingWorkReq;
        let pendingWR = normalOrDupPendingWorkReqPipeOut4WorkComp.first;
        normalOrDupPendingWorkReqPipeOut4WorkComp.deq;
        let isNormalReq = normalOrDupReqSelPipeOut4WorkComp.first;
        normalOrDupReqSelPipeOut4WorkComp.deq;

        // $display("time=%0d: pendingWR=", $time, fshow(pendingWR));

        if (isNormalReq && workReqNeedRecvReq(pendingWR.wr.opcode)) begin
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

                let wrImmDt = unwrapMaybe(pendingWR.wr.immDt);
                let wcImmDt = unwrapMaybe(wc.immDt);
                dynAssert(
                    wrImmDt == wcImmDt,
                    "wc.immDt equal assertion @ mkTestReqHandleNormalCase",
                    $format(
                        "wc.immDt=", fshow(wcImmDt),
                        " should == pendingWR.wr.immDt=",
                        fshow(wrImmDt)
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

    rule compareRespAETH;
        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let pendingWR = normalOrDupPendingWorkReqPipeOut4Resp.first;
        let isNormalReq = normalOrDupReqSelPipeOut4Resp.first;
        let isAtomicWR = isAtomicWorkReq(pendingWR.wr.opcode);

        if (rdmaRespDataStream.isFirst) begin
            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let endPSN = unwrapMaybe(pendingWR.endPSN);

            if (bth.psn == endPSN) begin
                normalOrDupPendingWorkReqPipeOut4Resp.deq;
                normalOrDupReqSelPipeOut4Resp.deq;
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

            if (isAtomicWR) begin
                let atomicAckEth = extractAtomicAckEth(zeroExtendLSB(rdmaRespDataStream.data));
                if (isNormalReq) begin
                    normalAtomicRespOrigReg <= atomicAckEth.orig;
                end
                else begin
                    dynAssert(
                        atomicAckEth.orig == normalAtomicRespOrigReg,
                        "atomicAckEth.orig assertion @ mkTestReqHandleNormalCase",
                        $format(
                            "atomicAckEth.orig=%h", atomicAckEth.orig,
                            " should == normalAtomicRespOrigReg=%h", normalAtomicRespOrigReg
                        )
                    );
                    // $display(
                    //     "time=%0d:", $time,
                    //     " atomicAckEth.orig=%h", atomicAckEth.orig,
                    //     " should == normalAtomicRespOrigReg=%h", normalAtomicRespOrigReg
                    // );
                end
            end
        end
    endrule
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

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
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
    let recvReqBuf4Ref <- mkBufferN(32, recvReqBufVec[1]);

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
endmodule

typedef enum {
    TEST_REQ_HANDLE_RETRY_REQ_GEN,
    TEST_REQ_HANDLE_RETRY_RESP_CHECK,
    TEST_REQ_HANDLE_RETRY_RNR_WAIT,
    TEST_REQ_HANDLE_RETRY_REQ_AGAIN,
    TEST_REQ_HANDLE_RETRY_CLEAR,
    TEST_REQ_HANDLE_RETRY_DONE_CHECK
} TestReqHandleRetryState deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestReqHandleRnrCase(Empty);
    let rnrOrSeqErr = True;
    let result <- mkTestReqHandleRetryCase(rnrOrSeqErr);
endmodule

(* synthesize *)
module mkTestReqHandleSeqErrCase(Empty);
    let rnrOrSeqErr = False;
    let result <- mkTestReqHandleRetryCase(rnrOrSeqErr);
endmodule

module mkTestReqHandleRetryCase#(Bool rnrOrSeqErr)(Empty);
    // Retry case need multi-packet requests, at least two packets
    let minPayloadLen = 512;
    let maxPayloadLen = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);

    // WorkReq generation
    Vector#(1, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    let selectPipeOut4WorkReqGen = selectPipeOutVec[0];
    Vector#(1, PipeOut#(WorkReq)) sendWorkReqPipeOutVec <- mkRandomSendWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let workReqPipeOut = sendWorkReqPipeOutVec[0];

    // Pending WR generation
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut = existingPendingWorkReqPipeOutVec[0];
    FIFOF#(PendingWorkReq)  origPendingWorkReqQ <- mkFIFOF;
    FIFOF#(PendingWorkReq) retryPendingWorkReqQ <- mkFIFOF;

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        convertFifo2PipeOut(origPendingWorkReqQ), qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(
        genNoPendingWorkReqOutRule(simReqGen.pendingWorkReqPipeOut)
    );
    FIFOF#(DataStream) rdmaReqDataStreamQ <- mkFIFOF;

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        convertFifo2PipeOut(rdmaReqDataStreamQ)
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
    Vector#(1, PipeOut#(RecvReq)) recvReqPipeOutVec <- mkSimGenRecvReq(cntrl);
    let recvReqPipeOut = recvReqPipeOutVec[0];
    FIFOF#(RecvReq) recvReqQ4Retry <- mkFIFOF;
    FIFOF#(RecvReq)   recvReqQ4Cmp <- mkFIFOF;

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl,
        simDmaReadSrv,
        permCheckMR,
        dupReadAtomicCache,
        convertFifo2PipeOut(recvReqQ4Retry),
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
    let workCompPipeOut4RecvReq = workCompGenRQ.workCompPipeOut;

    Reg#(RnrWaitCycleCnt)      rnrTestWaitCntReg <- mkRegU;
    Reg#(Bool)             discardFirstReqPktReg <- mkReg(False);
    Reg#(TestReqHandleRetryState) retryTestState <- mkReg(TEST_REQ_HANDLE_RETRY_REQ_GEN);

    // let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // let sinkPendingWR4Resp <- mkSink(pendingWorkReqPipeOut4Resp);
    // let sinkSelect4Resp <- mkSink(selectPipeOut4Resp);
    // let sinkRdmaResp <- mkSink(dut.rdmaRespDataStreamPipeOut);
    // let sinkPendingWR4WorkComp <- mkSink(pendingWorkReqPipeOut4WorkComp);
    // let sinkSelect4WorkComp <- mkSink(selectPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut4WorkReq);

    rule noErrWorkComp;
        let hasWorkCompErrStatusRQ = workCompGenRQ.workCompStatusPipeOutRQ.notEmpty;
        // Check workCompGenRQ.wcStatusQ4SQ has no error WC status
        dynAssert(
            !hasWorkCompErrStatusRQ,
            "hasWorkCompErrStatusRQ assertion @ mkTestReqHandleRetryCase",
            $format(
                "hasWorkCompErrStatusRQ=", fshow(hasWorkCompErrStatusRQ),
                " should be false"
            )
        );
    endrule

    rule genWorkReq if (retryTestState == TEST_REQ_HANDLE_RETRY_REQ_GEN);
        let pendingWR = pendingWorkReqPipeOut.first;
        pendingWorkReqPipeOut.deq;

        let startPSN = unwrapMaybe(pendingWR.startPSN);
        let endPSN   = unwrapMaybe(pendingWR.endPSN);
        dynAssert(
            startPSN != endPSN,
            "Pending WR PSN assertion @ mkTestReqHandleRetryCase",
            $format(
                "startPSN=%h should != endPSN=%h",
                startPSN, endPSN
            )
        );

        origPendingWorkReqQ.enq(pendingWR);
        retryPendingWorkReqQ.enq(pendingWR);

        discardFirstReqPktReg <= !rnrOrSeqErr;
        retryTestState <= TEST_REQ_HANDLE_RETRY_RESP_CHECK;
        // $display("time=%0d: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule filterReqPkt4SeqErr if (retryTestState != TEST_REQ_HANDLE_RETRY_REQ_GEN);
        let rdmaReqDataStream = rdmaReqPipeOut.first;
        rdmaReqPipeOut.deq;

        if (discardFirstReqPktReg) begin
            discardFirstReqPktReg <= !rdmaReqDataStream.isLast;
        end
        else begin
            rdmaReqDataStreamQ.enq(rdmaReqDataStream);
        end
    endrule

    rule checkRetryResp if (retryTestState == TEST_REQ_HANDLE_RETRY_RESP_CHECK);
        let pendingWR = retryPendingWorkReqQ.first;
        let startPSN = unwrapMaybe(pendingWR.startPSN);

        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
        dynAssert(
            bth.psn == startPSN,
            "bth.psn assertion @ mkTestReqHandleRetryCase",
            $format(
                "bth.psn=%h should == startPSN=%h",
                bth.psn, startPSN
            )
        );

        dynAssert(
            rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
            "rdmaRespDataStream assertion @ mkTestReqHandleRetryCase",
            $format(
                "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                ", rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                " should both be true, when bth.opcode=", fshow(bth.opcode)
            )
        );

        let hasAETH = rdmaRespHasAETH(bth.opcode);
        dynAssert(
            hasAETH,
            "hasAETH assertion @ mkTestReqHandleRetryCase",
            $format(
                "hasAETH=", fshow(hasAETH),
                " should be true, when retryTestState=", fshow(retryTestState),
                " and bth.opcode=", fshow(bth.opcode)
            )
        );

        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
        if (rnrOrSeqErr) begin
            rnrTestWaitCntReg <= fromInteger(getRnrTimeOutValue(aeth.value));
            retryTestState      <= TEST_REQ_HANDLE_RETRY_RNR_WAIT;

            dynAssert(
                aeth.code == AETH_CODE_RNR,
                "aeth.code assertion @ mkTestReqHandleRetryCase",
                $format(
                    "aeth.code=", fshow(aeth.code),
                    " should be AETH_CODE_RNR"
                )
            );
        end
        else begin
            retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_AGAIN;

            dynAssert(
                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                "aeth.code assertion @ mkTestReqHandleRetryCase",
                $format(
                    "aeth.code=", fshow(aeth.code),
                    " should be AETH_NAK_SEQ_ERR"
                )
            );
        end

        // $display(
        //     "time=%0d:", $time,
        //     " retryTestState=", fshow(retryTestState),
        //     ", response bth=", fshow(bth),
        //     ", aeth=", fshow(aeth)
        // );
    endrule

    rule waitRnrTimer if (retryTestState == TEST_REQ_HANDLE_RETRY_RNR_WAIT);
        if (isZero(rnrTestWaitCntReg)) begin
            retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_AGAIN;
        end
        else begin
            rnrTestWaitCntReg <= rnrTestWaitCntReg - 1;
        end
        // $display("time=%0d: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule retryReq if (retryTestState == TEST_REQ_HANDLE_RETRY_REQ_AGAIN);
        let pendingWR = retryPendingWorkReqQ.first;
        origPendingWorkReqQ.enq(pendingWR);

        let recvReq = recvReqPipeOut.first;
        recvReqPipeOut.deq;
        recvReqQ4Retry.enq(recvReq);
        recvReqQ4Cmp.enq(recvReq);

        retryTestState <= TEST_REQ_HANDLE_RETRY_CLEAR;
        // $display("time=%0d: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule retryClear if (retryTestState == TEST_REQ_HANDLE_RETRY_CLEAR);
        let pendingWR = retryPendingWorkReqQ.first;
        retryPendingWorkReqQ.deq;
        let endPSN = unwrapMaybe(pendingWR.endPSN);

        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
        dynAssert(
            bth.psn == endPSN,
            "bth.psn assertion @ mkTestReqHandleRetryCase",
            $format(
                "bth.psn=%h should == endPSN=%h",
                bth.psn, endPSN
            )
        );

        dynAssert(
            rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
            "rdmaRespDataStream assertion @ mkTestReqHandleRetryCase",
            $format(
                "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                ", rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                " should both be true, when bth.opcode=", fshow(bth.opcode)
            )
        );

        let hasAETH = rdmaRespHasAETH(bth.opcode);
        dynAssert(
            hasAETH,
            "hasAETH assertion @ mkTestReqHandleRetryCase",
            $format(
                "hasAETH=", fshow(hasAETH),
                " should be true, when retryTestState=", fshow(retryTestState),
                " and bth.opcode=", fshow(bth.opcode)
            )
        );

        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
        dynAssert(
            aeth.code == AETH_CODE_ACK,
            "aeth.code assertion @ mkTestReqHandleRetryCase",
            $format(
                "aeth.code=", fshow(aeth.code),
                " should be AETH_CODE_ACK"
            )
        );

        retryTestState <= TEST_REQ_HANDLE_RETRY_DONE_CHECK;
        // $display(
        //     "time=%0d:", $time,
        //     " retryTestState=", fshow(retryTestState),
        //     ", response bth=", fshow(bth),
        //     ", aeth=", fshow(aeth)
        // );
    endrule

    rule cmpWorkComp if (retryTestState == TEST_REQ_HANDLE_RETRY_DONE_CHECK);
        let workComp = workCompPipeOut4RecvReq.first;
        workCompPipeOut4RecvReq.deq;

        let recvReq = recvReqQ4Cmp.first;
        recvReqQ4Cmp.deq;

        dynAssert(
            workComp.id == recvReq.id,
            "WC ID assertion @ mkTestReqHandleRetryCase",
            $format(
                "workComp.id=%h should == recvReq.id=%h",
                workComp.id, recvReq.id
            )
        );

        retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_GEN;
        // $display("time=%0d: retryTestState=", $time, fshow(retryTestState));
    endrule
endmodule
