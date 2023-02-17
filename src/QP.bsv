import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import InputPktHandle :: *;
import Headers :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import RetryHandleSQ :: *;
import ReqGenSQ :: *;
import ReqHandleRQ :: *;
import RespHandleSQ :: *;
import Settings :: *;
import SpecialFIFOF :: *;
import WorkCompGen :: *;
import Utils :: *;

interface SQ;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkSQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheckMR,
    PipeOut#(WorkReq) workReqPipeIn,
    RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut,
    PipeOut#(WorkCompStatus) workCompStatusPipeInFromRQ
)(SQ);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    let newPendingWorkReqPipeOut <- mkNewPendingWorkReqPipeOut(workReqPipeIn);
    // let retryPendingWorkReqPipeOut = scanQ2PipeOut(pendingWorkReqScan);

    let retryHandler <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf.scanIfc);

    // TODO: fix isRetryDone bug
    let pendingWorkReqPipeOut = muxPipeOut(
        retryHandler.isRetryDone,
        newPendingWorkReqPipeOut,
        retryHandler.retryWorkReqPipeOut
    );
    let reqGenSQ <- mkReqGenSQ(
        cntrl, dmaReadSrv, pendingWorkReqPipeOut, pendingWorkReqBuf.fifoIfc.notEmpty
    );

    let respHandleSQ <- mkRespHandleSQ(
        cntrl,
        retryHandler,
        permCheckMR,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        respPktPipeOut.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        respPktPipeOut.payload,
        dmaWriteSrv,
        respHandleSQ.payloadConReqPipeOut
    );

    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        payloadConsumer.respPipeOut,
        reqGenSQ.workCompGenReqPipeOut,
        respHandleSQ.workCompGenReqPipeOut,
        workCompStatusPipeInFromRQ
    );

    interface rdmaReqDataStreamPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface workCompPipeOutSQ = workCompPipeOut;
endmodule

interface RQ;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkRQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheckMR,
    RecvReqBuf recvReqBuf,
    RdmaPktMetaDataAndPayloadPipeOut reqPktPipeIn
)(RQ);
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrl);

    let reqHandlerRQ <- mkReqHandleRQ(
        cntrl,
        dmaReadSrv,
        permCheckMR,
        dupReadAtomicCache,
        recvReqBuf,
        reqPktPipeIn.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        reqPktPipeIn.payload,
        dmaWriteSrv,
        reqHandlerRQ.payloadConReqPipeOut
    );

    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrl,
        payloadConsumer.respPipeOut,
        reqHandlerRQ.workCompGenReqPipeOut
    );

    interface rdmaRespDataStreamPipeOut = reqHandlerRQ.rdmaRespDataStreamPipeOut;
    interface workCompPipeOutRQ = workCompGenRQ.workCompPipeOut;
    interface workCompStatusPipeOutRQ = workCompGenRQ.workCompStatusPipeOutRQ;
endmodule

interface QP;
    interface Put#(RecvReq) putRecvReq;
    interface Put#(WorkReq) putWorkReq;
    interface DataStreamPipeOut rdmaReqRespPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkQP#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheckMR,
    RdmaPktMetaDataAndPayloadPipeOut reqPktPipeIn,
    RdmaPktMetaDataAndPayloadPipeOut respPktPipeIn
)(QP);
    function DataStreamPipeOut arbitrateDataStreamInsideQP(
        DataStreamPipeOut rdmaRespPipeOut,
        DataStreamPipeOut rdmaReqPipeOut
    );
        let notEmpty = rdmaRespPipeOut.notEmpty || rdmaReqPipeOut.notEmpty;
        let resultIfc = interface DataStreamPipeOut;
            method DataStream first() if (notEmpty);
                if (rdmaRespPipeOut.notEmpty) begin
                    return rdmaRespPipeOut.first;
                end
                else begin
                    return rdmaReqPipeOut.first;
                end
            endmethod

            method Action deq() if (notEmpty);
                if (rdmaRespPipeOut.notEmpty) begin
                    rdmaRespPipeOut.deq;
                end
                else begin
                    rdmaReqPipeOut.deq;
                end
            endmethod

            method Bool notEmpty() = notEmpty;
        endinterface;

        return resultIfc;
    endfunction

    // TODO: change WR and RR queues to mkSizedFIFOF
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;
    FIFOF#(WorkReq) workReqQ <- mkFIFOF;
    let recvReqBuf = convertFifo2PipeOut(recvReqQ);
    let workReqPipeIn = convertFifo2PipeOut(workReqQ);

    let dmaArbiter <- mkDmaArbiterInsideQP(
        dmaReadSrv, dmaWriteSrv
    );

    let rq <- mkRQ(
        cntrl,
        dmaArbiter.dmaReadSrv4RQ,
        dmaArbiter.dmaWriteSrv4RQ,
        permCheckMR,
        recvReqBuf,
        reqPktPipeIn
    );

    let sq <- mkSQ(
        cntrl,
        dmaArbiter.dmaReadSrv4SQ,
        dmaArbiter.dmaWriteSrv4SQ,
        permCheckMR,
        workReqPipeIn,
        respPktPipeIn,
        rq.workCompStatusPipeOutRQ
    );

    rule errFlush if (cntrl.isERR);
        // TODO: if pending WR queue is empty, then error flush is done
        if (!workReqQ.notEmpty && !recvReqQ.notEmpty) begin
            // Notify controller when flush done
            cntrl.errFlushDone;
            $display(
                "time=%0t:", $time,
                " error flush done, workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
                ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty)
            );
        end
    endrule

    interface putRecvReq = toPut(recvReqQ);
    interface putWorkReq = toPut(workReqQ);
    interface rdmaReqRespPipeOut = arbitrateDataStreamInsideQP(
        rq.rdmaRespDataStreamPipeOut,
        sq.rdmaReqDataStreamPipeOut
    );
    interface workCompPipeOutRQ = rq.workCompPipeOutRQ;
    interface workCompPipeOutSQ = sq.workCompPipeOutSQ;
endmodule

interface TransportLayerRDMA;
    interface DmaReadClt dmaReadClt;
    interface DmaWriteClt dmaWriteClt;
    interface Put#(DataStream) rdmaDataStreamInput;
    interface DataStreamPipeOut rdmaDataStreamPipeOut;
    interface Put#(RecvReq) putRecvReq;
    interface Put#(WorkReq) putWorkReq;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

(* synthesize *)
module mkTransportLayerRDMA(TransportLayerRDMA);
    FIFOF#(DataStream) inputDataStreamQ <- mkFIFOF;
    let rdmaReqRespPipeIn = convertFifo2PipeOut(inputDataStreamQ);

    let pdMetaData <- mkMetaDataPDs;
    let permCheckMR <- mkPermCheckMR(pdMetaData);
    let tlb <- mkTLB;
    let qpMetaData <- mkMetaDataQPs;

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqRespPipeIn
    );
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );

    // TODO: support CNP
    let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        pktMetaDataAndPayloadPipeOut.cnpPipeOut,
        "cnpPipeOut empty assertion @ mkQP"
    ));

    ServerProxy#(DmaReadReq, DmaReadResp) dmaReadProxy <- mkServerProxy;
    ServerProxy#(DmaWriteReq, DmaWriteResp) dmaWriteProxy <- mkServerProxy;

    let qpn = 0;
    let cntrl = qpMetaData.getCntrl(qpn);
    let singleQP <- mkQP(
        cntrl,
        dmaReadProxy.server,
        dmaWriteProxy.server,
        permCheckMR,
        pktMetaDataAndPayloadPipeOut.reqPktPipeOut,
        pktMetaDataAndPayloadPipeOut.respPktPipeOut
    );

    interface dmaReadClt            = dmaReadProxy.client;
    interface dmaWriteClt           = dmaWriteProxy.client;
    interface rdmaDataStreamInput   = toPut(inputDataStreamQ);
    interface rdmaDataStreamPipeOut = singleQP.rdmaReqRespPipeOut;
    interface putRecvReq            = singleQP.putRecvReq;
    interface putWorkReq            = singleQP.putWorkReq;
    interface workCompPipeOutRQ     = singleQP.workCompPipeOutRQ;
    interface workCompPipeOutSQ     = singleQP.workCompPipeOutSQ;
endmodule
