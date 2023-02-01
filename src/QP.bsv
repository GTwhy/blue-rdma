import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import RetryHandleSQ :: *;
import ReqGenSQ :: *;
import RespHandleSQ :: *;
import WorkCompGenSQ :: *;
import Utils :: *;

interface SQ;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOut;
endinterface

module mkSQ#(
    Controller cntrl,
    PipeOut#(WorkReq) workReqPipeIn,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    DataStreamPipeOut rdmaRespPipeIn,
    PipeOut#(WorkCompStatus) workCompStatusPipeInFromRQ
)(SQ);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    let newPendingWorkReqPipeOut <- mkNewPendingWorkReqPipeOut(workReqPipeIn);
    // let retryPendingWorkReqPipeOut = scanQ2PipeOut(pendingWorkReqScan);

    let retryHandler <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf.scanIfc);
    let notRetrying = retryHandler.isRetryDone;

    let pendingWorkReqPipeOut = muxPipeOut(
        notRetrying,
        newPendingWorkReqPipeOut,
        retryHandler.retryWorkReqPipeOut
    );
    let reqGenSQ <- mkReqGenSQ(
        cntrl, dmaReadSrv, pendingWorkReqPipeOut, pendingWorkReqBuf.fifoIfc.notEmpty
    );

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespPipeIn
    );
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, cntrl.getPMTU
    );

    let respHandleSQ <- mkRespHandleSQ(
        cntrl,
        convertFifo2PipeOut(pendingWorkReqBuf.fifoIfc),
        pktMetaDataAndPayloadPipeOut.pktMetaData,
        retryHandler
    );

    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        pktMetaDataAndPayloadPipeOut.payload,
        dmaWriteSrv,
        respHandleSQ.payloadConReqPipeOut
    );

    let wcPipeOut <- mkWorkCompGenSQ(
        cntrl,
        payloadConsumer.respPipeOut,
        reqGenSQ.workCompGenReqPipeOut,
        respHandleSQ.workCompGenReqPipeOut,
        workCompStatusPipeInFromRQ
    );

    interface rdmaReqDataStreamPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface workCompPipeOut = wcPipeOut;
endmodule

interface QP;
    PipeOut#(WorkComp) workCompPipeOutSQ;
    PipeOut#(WorkComp) workCompPipeOutRQ;
endinterface

module mkQP#()(QP);
    // TODO: if WR queue is empty, then error flush is done
    if (!workReqPipeIn.notEmpty) begin
        // Notify controller when flush done
        cntrl.errFlushDone;
        $display(
            "time=%0d: error flush done, pendingWorkCompQ4SQ.notEmpty=",
            $time, fshow(pendingWorkCompQ4SQ.notEmpty)
        );
    end
endmodule
