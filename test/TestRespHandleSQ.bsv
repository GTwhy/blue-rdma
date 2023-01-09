import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut::*;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import RespHandleSQ :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaReqAndResp :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGen :: *;

(* synthesize *)
module mkTestRespHandleNormalCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);
    // let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkPendingWorkReqPipeOut(workReqPipeOutVec[0], pmtu);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[1];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[2]);
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        pendingWorkReqPipeOut4PendingQ, pendingWorkReqBuf
    );
    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(32, simDmaReadSrv.dataStream);
    let pmtuPipeOut <- mkConstantPipeOut(cntrl.getPMTU);
    let segSimDmaReadSrvDataStreamPipeOut <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrvDataStreamPipeOut, pmtuPipeOut
    );
    // Generate RDMA responses
    let rdmaRespAndHeaderPipeOut <- mkSimGenRdmaRespHeaderAndDataStream(
        cntrl, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeOut4RespGen
    );
    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespAndHeaderPipeOut.rdmaResp
    );
    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    // Retry handler
    let retryHandler <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf.scanIfc);

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckMR <- mkSimPermCheckMR(mrCheckPassOrFail);

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl,
        retryHandler,
        permCheckMR,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        pktMetaDataAndPayloadPipeOut.pktMetaData
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
    FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;
    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        payloadConsumer.respPipeOut,
        // convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut,
        convertFifo2PipeOut(workCompStatusQFromRQ)
    );

    // PipeOut need to handle:
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

        if (workReqNeedWorkCompSQ(pendingWR.wr)) begin
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
        else if (isAtomicRespRdmaOpCode(bth.opcode)) begin
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

function DataStreamPipeOut muxDataStreamPipeOut(
    PipeOut#(Bool) selectPipeIn,
    DataStreamPipeOut pipeIn1,
    DataStreamPipeOut pipeIn2
);
    DataStreamPipeOut resultPipeOut = interface PipeOut;
        method DataStream first();
            return selectPipeIn.first ? pipeIn1.first : pipeIn2.first;
        endmethod

        method Action deq();
            let sel = selectPipeIn.first;
            if (sel) begin
                if (pipeIn1.first.isLast) begin
                    selectPipeIn.deq;
                end
            end
            else begin
                if (pipeIn2.first.isLast) begin
                    selectPipeIn.deq;
                end
            end

            if (sel) begin
                pipeIn1.deq;
            end
            else begin
                pipeIn2.deq;
            end
            // $display("time=%0d: sel=", $time, fshow(sel));
        endmethod

        method Bool notEmpty();
            return selectPipeIn.first ? pipeIn1.notEmpty : pipeIn2.notEmpty;
        endmethod
    endinterface;

    return resultPipeOut;
endfunction

typedef enum {
    RESP_HANDLE_ERROR_RESP,
    RESP_HANDLE_RETRY_LIMIT_EXC,
    RESP_HANDLE_PERM_CHECK_FAIL
} RespHandleErrType deriving(Bits, Eq);

module mkGenNormalOrErrOrRetryRdmaResp#(
    RespHandleErrType errType,
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(DataStreamPipeOut);
    Vector#(2, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    case (errType)
        // If RESP_HANDLE_PERM_CHECK_FAIL, then just generate normal responses
        RESP_HANDLE_PERM_CHECK_FAIL: begin
            let rdmaNormalRespPipeOut <- mkSimGenRdmaRespDataStream(
                cntrl, dmaReadSrv, pendingWorkReqPipeIn
            );
            return rdmaNormalRespPipeOut;
        end
        default: begin
            let selectPipeOut4WorkReqSel = selectPipeOutVec[0];
            let selectPipeOut4RdmaRespSel =  selectPipeOutVec[1];

            let {
                pendingWorkReqPipeOut4NormalRespGen,
                pendingWorkReqPipeOut4ErrRespGen
            } = deMuxPipeOut2(
                selectPipeOut4WorkReqSel, pendingWorkReqPipeIn
            );

            let rdmaNormalRespPipeOut <- mkSimGenRdmaRespDataStream(
                cntrl, dmaReadSrv, pendingWorkReqPipeOut4NormalRespGen
            );
            let errOrRetryResp = errType == RESP_HANDLE_ERROR_RESP;
            let rdmaErrRespPipeOut <- mkGenErrOrRetryRdmaResp(
                errOrRetryResp, cntrl, pendingWorkReqPipeOut4ErrRespGen
            );

            let rdmaRespDataStreamPipeOut = muxDataStreamPipeOut(
                selectPipeOut4RdmaRespSel, rdmaNormalRespPipeOut, rdmaErrRespPipeOut
            );

            return rdmaRespDataStreamPipeOut;
        end
    endcase
endmodule

(* synthesize *)
module mkTestRespHandleRespErrCase(Empty);
    let errType = RESP_HANDLE_ERROR_RESP;
    let result <- mkTestRespHandleAbnormalCase(errType);
endmodule

(* synthesize *)
module mkTestRespHandleRetryErrCase(Empty);
    let errType = RESP_HANDLE_RETRY_LIMIT_EXC;
    let result <- mkTestRespHandleAbnormalCase(errType);
endmodule

(* synthesize *)
module mkTestRespHandlePermCheckFailCase(Empty);
    let errType = RESP_HANDLE_PERM_CHECK_FAIL;
    let result <- mkTestRespHandleAbnormalCase(errType);
    // let result <- mkTestRespHandleNormalOrLocalErrCase(errType);
endmodule

module mkTestRespHandleAbnormalCase#(RespHandleErrType errType)(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 31;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let workReqPipeOut = workReqPipeOutVec[0];
    // let workReqPipeOut <- mkRandomReadOrAtomicWorkReq(minDmaLength, maxDmaLength);
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[2];
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        pendingWorkReqPipeOut4PendingQ, pendingWorkReqBuf
    );
    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;
    // Generate RDMA responses
    let rdmaRespDataStreamPipeOut <- mkGenNormalOrErrOrRetryRdmaResp(
        errType, cntrl, simDmaReadSrv, pendingWorkReqPipeOut4RespGen
    );

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespDataStreamPipeOut
    );
    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    // Retry handler
    let retryHandler <- mkSimRetryHandlerWithLimitExcErr;

    // MR permission check
    let mrCheckPassOrFail = !(errType == RESP_HANDLE_PERM_CHECK_FAIL);
    let permCheckMR <- mkSimPermCheckMR(mrCheckPassOrFail);

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl,
        retryHandler,
        permCheckMR,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        pktMetaDataAndPayloadPipeOut.pktMetaData
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        pktMetaDataAndPayloadPipeOut.payload,
        simDmaWriteSrv,
        dut.payloadConReqPipeOut
    );

    // WorkCompGenSQ
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;
    // This controller will be set to error state,
    // since it cannot generate WR when error state,
    // so use a dedicated controller for WC.
    let cntrl4WorkComp <- mkSimController(qpType, pmtu);
    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl4WorkComp,
        payloadConsumer.respPipeOut,
        convertFifo2PipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut,
        convertFifo2PipeOut(workCompStatusQFromRQ)
    );

    Reg#(Bool) firstErrWorkCompGenReg <- mkReg(False);

    // let sinkPendingWR4PendingQ <- mkSink(pendingWorkReqPipeOut4PendingQ);
    // let sinkPendingWorkReqBuf <- mkSink(convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc));
    // let sinkRdmaResp <- mkSink(rdmaRespDataStreamPipeOut);
    // let sinkPktMetaData <- mkSink(pktMetaDataAndPayloadPipeOut.pktMetaData);
    // let sinkPayload <- mkSink(pktMetaDataAndPayloadPipeOut.payload);
    // let sinkPayloadConReq <- mkSink(dut.payloadConReqPipeOut);
    // let sinkWorkCompGenReq <- mkSink(dut.workCompGenReqPipeOut);
    // let sinkPayloadConResp <- mkSink(payloadConsumer.respPipeOut);
    // let sinkSleect <- mkSink(selectPipeOut4WorkComp);
    // let sinkPendingWR4WorkComp <- mkSink(pendingWorkReqPipeOut4WorkComp);
    // let sinkWorkComp <- mkSink(workCompPipeOut);

    rule compareWorkReqAndWorkComp;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        if (workReqNeedWorkCompSQ(pendingWR.wr)) begin
            let workComp = workCompPipeOut.first;
            workCompPipeOut.deq;

            if (workComp.status != IBV_WC_SUCCESS && !firstErrWorkCompGenReg) begin
                firstErrWorkCompGenReg <= True;
            end

            dynAssert(
                workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
                "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleAbnormalCase",
                $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
            );
            // $display(
            //     "time=%0d: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
            // );
        end
    endrule
endmodule
