import Arbitration :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import InputPktHandle :: *;
import Headers :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
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
    let retryPendingWorkReqPipeOut = scanOut2PipeOut(pendingWorkReqBuf);

    let retryHandler <- mkRetryHandleSQ(
        cntrl, pendingWorkReqBuf.fifoIfc.notEmpty, pendingWorkReqBuf.scanCntrlIfc
    );

    let pendingWorkReqPipeOut = muxPipeOut(
        pendingWorkReqBuf.scanCntrlIfc.isScanDone,
        newPendingWorkReqPipeOut,
        retryPendingWorkReqPipeOut
    );
    let reqGenSQ <- mkReqGenSQ(
        cntrl, dmaReadSrv, pendingWorkReqPipeOut, pendingWorkReqBuf.fifoIfc.notEmpty
    );
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        reqGenSQ.pendingWorkReqPipeOut, pendingWorkReqBuf.fifoIfc
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
    // interface Put#(RecvReq) putRecvReq;
    // interface Put#(WorkReq) putWorkReq;
    interface DataStreamPipeOut rdmaReqRespPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkQP#(
    Controller cntrl,
    PipeOut#(RecvReq) recvReqPipeIn,
    PipeOut#(WorkReq) workReqPipeIn,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheck4RQ,
    PermCheckMR permCheck4SQ,
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
    mkConnection(toGet(recvReqPipeIn), toPut(recvReqQ));
    mkConnection(toGet(workReqPipeIn), toPut(workReqQ));
    let recvReqBufPipeOut = convertFifo2PipeOut(recvReqQ);
    let workReqBufPipeOut = convertFifo2PipeOut(workReqQ);

    let dmaArbiter <- mkDmaArbiterInsideQP(
        dmaReadSrv, dmaWriteSrv
    );

    let rq <- mkRQ(
        cntrl,
        dmaArbiter.dmaReadSrv4RQ,
        dmaArbiter.dmaWriteSrv4RQ,
        permCheck4RQ,
        recvReqBufPipeOut,
        reqPktPipeIn
    );

    let sq <- mkSQ(
        cntrl,
        dmaArbiter.dmaReadSrv4SQ,
        dmaArbiter.dmaWriteSrv4SQ,
        permCheck4SQ,
        workReqBufPipeOut,
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

    // interface putRecvReq = toPut(recvReqQ);
    // interface putWorkReq = toPut(workReqQ);
    interface rdmaReqRespPipeOut = arbitrateDataStreamInsideQP(
        rq.rdmaRespDataStreamPipeOut,
        sq.rdmaReqDataStreamPipeOut
    );
    interface workCompPipeOutRQ = rq.workCompPipeOutRQ;
    interface workCompPipeOutSQ = sq.workCompPipeOutSQ;
endmodule

// TODO: check QP state when dispatching WR and RR
module mkWorkReqAndRecvReqDispatcher#(
    PipeOut#(WorkReq) workReqPipeIn,
    PipeOut#(RecvReq) recvReqPipeIn
)(Tuple2#(Vector#(MAX_QP, PipeOut#(WorkReq)), Vector#(MAX_QP, PipeOut#(RecvReq))));
    Vector#(MAX_QP, FIFOF#(WorkReq)) workReqOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RecvReq)) recvReqOutVec <- replicateM(mkFIFOF);

    rule dispatchWR;
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let qpIndex = getIndexQP(wr.sqpn);
        workReqOutVec[qpIndex].enq(wr);
    endrule

    rule displatchRR;
        let rr = recvReqPipeIn.first;
        recvReqPipeIn.deq;

        let qpIndex = getIndexQP(rr.sqpn);
        recvReqOutVec[qpIndex].enq(rr);
    endrule

    return tuple2(
        map(convertFifo2PipeOut, workReqOutVec),
        map(convertFifo2PipeOut, recvReqOutVec)
    );
endmodule

interface TransportLayerRDMA;
    interface Put#(DataStream) rdmaDataStreamInput;
    interface DataStreamPipeOut rdmaDataStreamPipeOut;
    interface Put#(RecvReq) putRecvReq;
    interface Put#(WorkReq) putWorkReq;
    // interface PipeOut#(WorkComp) workCompPipeOutRQ;
    // interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

(* synthesize *)
module mkTransportLayerRDMA(TransportLayerRDMA);
    FIFOF#(DataStream) inputDataStreamQ <- mkFIFOF;
    let rdmaReqRespPipeIn = convertFifo2PipeOut(inputDataStreamQ);

    FIFOF#(WorkReq) inputWorkReqQ <- mkFIFOF;
    FIFOF#(RecvReq) inputRecvReqQ <- mkFIFOF;

    let pdMetaData <- mkMetaDataPDs;
    let permCheckMR <- mkPermCheckMR(pdMetaData);
    let tlb <- mkTLB;
    let qpMetaData <- mkMetaDataQPs;

    let { workReqPipeOutVec, recvPipeOutVec } <- mkWorkReqAndRecvReqDispatcher(
        convertFifo2PipeOut(inputWorkReqQ),
        convertFifo2PipeOut(inputRecvReqQ)
    );

    PermCheckArbiter#(TMul#(2, MAX_QP)) permCheckArbiter <- mkPermCheckAribter(permCheckMR);

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqRespPipeIn
    );
    let pktMetaDataAndPayloadPipeOutVec <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );

    let dmaReadSrv  <- mkDmaReadSrv;
    let dmaWriteSrv <- mkDmaWriteSrv;
    DmaReadArbiter#(MAX_QP)   dmaReadSrvVec <- mkDmaReadAribter(dmaReadSrv);
    DmaWriteArbiter#(MAX_QP) dmaWriteSrvVec <- mkDmaWriteAribter(dmaWriteSrv);

    Vector#(MAX_QP, DataStreamPipeOut) qpDataStreamPipeOutVec = newVector;
    for (Integer idx = 0; idx < valueOf(MAX_QP); idx = idx + 1) begin
        let permCheck4RQ = permCheckArbiter[2 * idx];
        let permCheck4SQ = permCheckArbiter[2 * idx + 1];

        IndexQP qpIndex = fromInteger(idx);
        let cntrl = qpMetaData.getCntrlByIdxQP(qpIndex);
        let qp <- mkQP(
            cntrl,
            recvPipeOutVec[qpIndex],
            workReqPipeOutVec[qpIndex],
            dmaReadSrvVec[qpIndex],
            dmaWriteSrvVec[qpIndex],
            permCheck4RQ,
            permCheck4SQ,
            pktMetaDataAndPayloadPipeOutVec[idx].reqPktPipeOut,
            pktMetaDataAndPayloadPipeOutVec[idx].respPktPipeOut
        );
        qpDataStreamPipeOutVec[idx] = qp.rdmaReqRespPipeOut;

        // TODO: support CNP
        let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
            pktMetaDataAndPayloadPipeOutVec[idx].cnpPipeOut,
            "pktMetaDataAndPayloadPipeOutVec[" + integerToString(idx) +
            "].cnpPipeOut empty assertion @ mkTransportLayerRDMA"
        ));
        // TODO: support CQ
        mkSink(qp.workCompPipeOutRQ);
        mkSink(qp.workCompPipeOutSQ);
    end

    function Bool dataStreamHasLockFunc(DataStream ds) = !ds.isLast;
    let arbitratedPipeOut <- mkPipeOutArbiter(qpDataStreamPipeOutVec, dataStreamHasLockFunc);
    // TODO: connect to UDP
    // mkSink(arbitratedPipeOut);

    interface rdmaDataStreamInput   = toPut(inputDataStreamQ);
    interface rdmaDataStreamPipeOut = arbitratedPipeOut;
    interface putRecvReq            = toPut(inputRecvReqQ);
    interface putWorkReq            = toPut(inputWorkReqQ);
    // interface workCompPipeOutRQ     = singleQP.workCompPipeOutRQ;
    // interface workCompPipeOutSQ     = singleQP.workCompPipeOutSQ;
endmodule

// TODO: connect to DMA IP

// This function should be used in simulation only
function Tuple3#(TotalFragNum, ByteEn, ByteEnBitNum) calcTotalFragNumByLength(Length dmaLen);
    let shiftAmt = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    TotalFragNum fragNum = truncate(dmaLen >> shiftAmt);
    BusByteWidthMask busByteWidthMask = maxBound;
    let lastFragSize = truncate(dmaLen) & busByteWidthMask;
    Bool lastFragEmpty = isZero(lastFragSize);
    if (!lastFragEmpty) begin
        fragNum = fragNum + 1;
    end

    ByteEnBitNum lastFragValidByteNum = lastFragEmpty ?
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) :
        zeroExtend(lastFragSize);
    ByteEn lastFragByteEn = genByteEn(lastFragValidByteNum);
    return tuple3(fragNum, lastFragByteEn, lastFragValidByteNum);
endfunction

module mkDmaReadSrv(DmaReadSrv);
    FIFOF#(DmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;

    Reg#(TotalFragNum) totalFragCntReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) isFirstReg <- mkRegU;
    Reg#(ByteEn) lastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) lastFragInvalidBitNumReg <- mkRegU;
    Reg#(DmaReadReq) curReqReg <- mkRegU;

    Bool isFragCntZero = isZero(totalFragCntReg);

    rule acceptReq if (!busyReg);
        let curReq = dmaReadReqQ.first;
        dmaReadReqQ.deq;

        let isZeroLen = isZero(curReq.len);
        immAssert(
            !isZeroLen,
            "dmaReadReq.len non-zero assrtion",
            $format("curReq.len=%h should not be zero", curReq.len)
        );

        let { totalFragCnt, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(curReq.len);
        let { lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum } =
            calcFragBitNumAndByteNum(lastFragValidByteNum);

        totalFragCntReg <= isZeroLen ? 0 : totalFragCnt - 1;
        lastFragByteEnReg <= lastFragByteEn;
        lastFragInvalidBitNumReg <= lastFragInvalidBitNum;

        immAssert(
            !isZero(lastFragByteEn),
            "lastFragByteEn non-zero assertion",
            $format(
                "lastFragByteEn=%h should not have zero ByteEn, curReq.len=%h",
                lastFragByteEn, curReq.len
            )
        );

        curReqReg <= curReq;
        busyReg <= True;
        isFirstReg <= True;

        // $display(
        //     "time=%0t: curReq.len=%0d, totalFragCnt=%0d",
        //     $time, curReq.len, totalFragCnt
        // );
    endrule

    rule genResp if (busyReg);
        totalFragCntReg <= totalFragCntReg - 1;
        DataStream dataStream = dontCareValue;
        dataStream.isFirst = isFirstReg;
        isFirstReg <= False;
        dataStream.isLast = isFragCntZero;
        dataStream.byteEn = maxBound;

        if (isFragCntZero) begin
            busyReg <= False;
            dataStream.byteEn = lastFragByteEnReg;
            DATA tmpData = dataStream.data >> lastFragInvalidBitNumReg;
            dataStream.data = truncate(tmpData << lastFragInvalidBitNumReg);
        end

        let resp = DmaReadResp {
            initiator : curReqReg.initiator,
            sqpn      : curReqReg.sqpn,
            wrID      : curReqReg.wrID,
            isRespErr : False,
            dataStream: dataStream
        };
        dmaReadRespQ.enq(resp);

        immAssert(
            !isZero(dataStream.byteEn),
            "dmaReadResp.data.byteEn non-zero assertion",
            $format("dmaReadResp.data should not have zero ByteEn, ", fshow(dataStream))
        );
        // $display(
        //     "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut response, totalFragNum=%h, dataStream=",
        //     $time, totalFragCntReg, fshow(dataStream)
        // );
    endrule

    return toGPServer(dmaReadReqQ, dmaReadRespQ);
endmodule

module mkDmaWriteSrv(DmaWriteSrv);
    FIFOF#(DmaWriteReq) dmaWriteReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ <- mkFIFOF;

    function Action genDmaWriteResp(DmaWriteMetaData metaData);
        action
            let dmaWriteResp = DmaWriteResp {
                initiator: metaData.initiator,
                sqpn     : metaData.sqpn,
                psn      : metaData.psn,
                isRespErr: False
            };
            // $display("time=%0t: dmaWriteResp=", $time, fshow(dmaWriteResp));

            dmaWriteRespQ.enq(dmaWriteResp);
        endaction
    endfunction

    rule write;
        let dmaWriteReq = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;

        // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));

        if (dmaWriteReq.dataStream.isLast) begin
            genDmaWriteResp(dmaWriteReq.metaData);
        end
    endrule

    return toGPServer(dmaWriteReqQ, dmaWriteRespQ);
endmodule
