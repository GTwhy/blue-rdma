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
import WorkCompGenRQ :: *;

(* synthesize *)
module mkTestReqHandleNormalCase(Empty);
    function Bool workReqNeedDmaWriteResp(PendingWorkReq pwr);
        return !isZero(pwr.wr.len) && isReadOrAtomicWorkReq(pwr.wr.opcode);
    endfunction

    let minPayloadLen = 1;
    let maxPayloadLen = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);
    // let cntrl <- mkSimController(qpType, pmtu);

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
    let permCheckMR <- mkSimPermCheckMR;

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
        recvReqBuf,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;
    // Vector#(2, PipeOut#(WorkComp)) workCompPipeOutVec <-
    //     mkForkVector(workCompGenRQ.workCompPipeOut);
    // let workCompPipeOut4RecvReq = workCompPipeOutVec[0];
    // let workCompPipeOut4WorkReq = workCompPipeOutVec[1];

    // PipeOut need to handle:
    // sendWritePayloadPipeOut
    // sendWritePayloadPipeOut4Ref
    // pktMetaDataAndPayloadPipeOut.payload
    // dut.payloadConReqPipeOut
    // payloadConsumer.respPipeOut
    // dut.workCompGenReqPipeOut
    // pendingWorkReqPipeOut
    // dut.rdmaRespDataStreamPipeOut
    // workCompGenRQ.workCompPipeOut

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

            // $display("time=%0d: WC=", $time, fshow(wc));

            if (workReqHasImmDt(pendingWR.wr.opcode)) begin
                dynAssert(
                    isValid(wc.immDt) &&
                    !isValid(wc.rkey2Inv),
                    "WC has ImmDT assertion @ ",
                    $format(
                        "wc.immDt=", fshow(wc.immDt),
                        " should be valid, and wc.rkey2Inv=",
                        fshow(wc.rkey2Inv), " should be invalid"
                    )
                );
            end
            else if (workReqHasInv(pendingWR.wr.opcode)) begin
                dynAssert(
                    !isValid(wc.immDt) &&
                    isValid(wc.rkey2Inv),
                    "WC has IETH assertion @ ",
                    $format(
                        "wc.rkey2Inv=", fshow(wc.rkey2Inv),
                        " should be valid, and wc.immDt=",
                        fshow(wc.immDt), " should be invalid"
                    )
                );
            end
            else begin
                dynAssert(
                    !isValid(wc.immDt) &&
                    !isValid(wc.rkey2Inv),
                    "WC has no ImmDT or IETH assertion @ ",
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

    rule noPendingWorkReqOutFromReqGenSQ;
        dynAssert(
            !simReqGen.pendingWorkReqPipeOut.notEmpty,
            "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleNormalCase",
            $format(
                "simReqGen.pendingWorkReqPipeOut.notEmpty=",
                fshow(simReqGen.pendingWorkReqPipeOut.notEmpty),
                " should be empty"
            )
        );
    endrule
endmodule
