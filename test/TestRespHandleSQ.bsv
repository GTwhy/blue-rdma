import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import PayloadConAndGen :: *;
import RespHandleSQ :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaResp :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGenSQ :: *;

import ExtractAndPrependPipeOut::*;
(* synthesize *)
module mkTestRespHandleNormalCase(Empty);
    let minDmaLength = 64;
    let maxDmaLength = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    // PipeOut#(WorkReqOpCode) constReadWorkReqPipeOut <-
    //     mkConstantPipeOut(IBV_WR_RDMA_READ);
    // Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
    //     mkSimGenWorkReqByOpCode(constReadWorkReqPipeOut, minDmaLength, maxDmaLength);
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkPendingWorkReqPipeOut(workReqPipeOutVec[0], pmtu);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[1];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(4, existingPendingWorkReqPipeOutVec[2]);
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        pendingWorkReqPipeOut4PendingQ, pendingWorkReqBuf
    );
    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(4, simDmaReadSrv.dataStream);
    let segSimDmaReadSrvDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        simDmaReadSrvDataStreamPipeOut,
        cntrl.getPMTU
    );
    // Generate RDMA responses
    let rdmaRespAndHeaderPipeOut <- mkSimGenRdmaResp(
        cntrl, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeOut4RespGen
    );
    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespAndHeaderPipeOut.rdmaResp
    );
    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, pmtu
    );

    let retryHandler <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf.scanIfc);

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        pktMetaDataAndPayloadPipeOut.pktMetaData,
        retryHandler
    );
    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        pktMetaDataAndPayloadPipeOut.payload,
        simDmaWriteSrv.dmaWriteSrv,
        dut.payloadConReqPipeOut
    );
    // WorkCompGenSQ
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(WorkComp) workCompQFromRQ <- mkFIFOF;
    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        payloadConsumer.respPipeOut,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut,
        convertFifo2PipeOut(workCompQFromRQ)
    );

    // PipeOut need handle:
    // - pendingWorkReqPipeOut4WorkComp
    // - pendingWorkReqPipeOut4RespGen
    // - convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc)
    // - segSimDmaReadSrvDataStreamPipeOut
    // - rdmaRespAndHeaderPipeOut.respHeader
    // - rdmaRespAndHeaderPipeOut.rdmaResp
    // - headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream
    // - headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    // - headerAndMetaDataAndPayloadPipeOut.payload
    // - pktMetaDataAndPayloadPipeOut.pktMetaData
    // - pktMetaDataAndPayloadPipeOut.payload
    // - dut.payloadConReqPipeOut
    // - dut.workCompGenReqPipeOut
    // - simDmaWriteSrvDataStreamPipeOut
    // - payloadConsumer.respPipeOut
    // - workCompPipeOut

    rule compareWorkReqAndWorkComp;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        if (pendingWorkReqNeedWorkComp(pendingWR)) begin
            let workComp = workCompPipeOut.first;
            workCompPipeOut.deq;

            dynAssert(
                workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
                "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleSQ",
                $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
            );
            // $display(
            //     "time=%0d: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
            // );
        end
    endrule

    rule compareReadRespPayloadDataStream;
        let respHeader = rdmaRespAndHeaderPipeOut.respHeader.first;
        let bth = extractBTH(respHeader.headerData);

        if (isReadRespRdmaOpCode(bth.opcode)) begin // Read responses
            let payloadDataStream = simDmaWriteSrvDataStreamPipeOut.first;
            simDmaWriteSrvDataStreamPipeOut.deq;

            let refDataStream = segSimDmaReadSrvDataStreamPipeOut.first;
            segSimDmaReadSrvDataStreamPipeOut.deq;
            if (refDataStream.isLast) begin
                let lastFragByteEnWithPadding = addPadding2LastFragByteEn(refDataStream.byteEn);
                // $display(
                //     "time=%0d: refDataStream.byteEn=%h, padCnt=%0d",
                //     $time, refDataStream.byteEn, padCnt
                // );
                refDataStream.byteEn = lastFragByteEnWithPadding;
            end

            dynAssert(
                payloadDataStream == refDataStream,
                "payloadDataStream assertion @ mkTestRespHandleNormalCase",
                $format(
                    "payloadDataStream=", fshow(payloadDataStream),
                    " should == refDataStream=", fshow(refDataStream)
                )
            );

            if (payloadDataStream.isLast) begin
                rdmaRespAndHeaderPipeOut.respHeader.deq;
            end
        end
        else if (rdmaRespHasAtomicAckEth(bth.opcode)) begin
            // No DMA read when generate atomic responses
            rdmaRespAndHeaderPipeOut.respHeader.deq;
            simDmaWriteSrvDataStreamPipeOut.deq;
        end
        else begin
            // No DMA read or write when generate send/write/zero-length read responses
            rdmaRespAndHeaderPipeOut.respHeader.deq;
        end
        // $display("time=%0d: respHeader=", $time, fshow(respHeader));
    endrule
endmodule
