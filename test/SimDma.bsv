import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

function DataStream getDmaReadRespData(
    DmaReadResp dmaReadResp
) = dmaReadResp.dataStream;

function DataStream getDmaWriteReqData(
    DmaWriteReq dmaWriteReq
) = dmaWriteReq.dataStream;

// DmaReadResp 2 PipeOut
module mkPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(PipeOut#(DmaReadResp));
    PipeOut#(DmaReadResp) ret <- mkSource_from_fav(resp.get);
    return ret;
endmodule

module mkDataStreamPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(DataStreamPipeOut);
    PipeOut#(DmaReadResp) dmaReadRespPipeOut <- mkPipeOutFromDmaReadResp(resp);
    // DataStreamPipeOut ret <- mkDataStreamFromDmaReadResp(dmaReadRespPipeOut);
    DataStreamPipeOut ret <- mkFunc2Pipe(getDmaReadRespData, dmaReadRespPipeOut);
    // rule display;
    //     $display(
    //         "Before segment: time=%0t, isFirst=%b, isLast=%b, byteEn=%h",
    //         $time, ret.first.isFirst, ret.first.isLast, ret.first.byteEn
    //     );
    // endrule

    return ret;
endmodule

interface DmaReadSrvAndReqRespPipeOut;
    interface DmaReadSrv dmaReadSrv;
    interface PipeOut#(DmaReadReq) dmaReadReq;
    interface PipeOut#(DmaReadResp) dmaReadResp;
endinterface

module mkSimDmaReadSrvAndReqRespPipeOut(DmaReadSrvAndReqRespPipeOut);
    FIFOF#(DmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;
    FIFOF#(DmaReadReq) dmaReadReqOutQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespOutQ <- mkFIFOF;

    Reg#(TotalFragNum) totalFragCntReg <- mkRegU;
    Randomize#(DataStream) randomDataStream <- mkGenericRandomizer;
    Reg#(Bool) initializedReg <- mkReg(False);
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) isFirstReg <- mkRegU;
    Reg#(ByteEn) lastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) lastFragInvalidBitNumReg <- mkRegU;
    Reg#(DmaReadReq) curReqReg <- mkRegU;

    Bool isFragCntZero = isZero(totalFragCntReg);

    rule init if (!initializedReg);
        randomDataStream.cntrl.init;
        initializedReg <= True;
    endrule

    rule acceptReq if (!busyReg && initializedReg);
        let curReq = dmaReadReqQ.first;
        dmaReadReqQ.deq;
        dmaReadReqOutQ.enq(curReq);

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

    rule genResp if (busyReg && initializedReg);
        totalFragCntReg <= totalFragCntReg - 1;
        let dataStream <- randomDataStream.next;
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
        dmaReadRespOutQ.enq(resp);

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

    interface dmaReadSrv  = toGPServer(dmaReadReqQ, dmaReadRespQ);
    interface dmaReadReq  = convertFifo2PipeOut(dmaReadReqOutQ);
    interface dmaReadResp = convertFifo2PipeOut(dmaReadRespOutQ);
endmodule

interface DmaReadSrvAndDataStreamPipeOut;
    interface DmaReadSrv dmaReadSrv;
    interface DataStreamPipeOut dataStream;
endinterface

module mkSimDmaReadSrvAndDataStreamPipeOut(DmaReadSrvAndDataStreamPipeOut);
    let simDmaReadSrv <- mkSimDmaReadSrvAndReqRespPipeOut;
    let dmaReadReqSink <- mkSink(simDmaReadSrv.dmaReadReq);
    DataStreamPipeOut dataStreamPipeOut <- mkFunc2Pipe(
        getDmaReadRespData, simDmaReadSrv.dmaReadResp
    );

    interface dmaReadSrv = simDmaReadSrv.dmaReadSrv;
    interface dataStream = dataStreamPipeOut;
endmodule

module mkSimDmaReadSrv(DmaReadSrv);
    let simDmaReadSrv   <- mkSimDmaReadSrvAndReqRespPipeOut;
    let dmaReadReqSink  <- mkSink(simDmaReadSrv.dmaReadReq);
    let dmaReadRespSink <- mkSink(simDmaReadSrv.dmaReadResp);
    return simDmaReadSrv.dmaReadSrv;
endmodule

module mkSimDmaReadSrvWithErr#(
    Bool hasRespErr, Length minErrLen, Length maxErrLen
)(DmaReadSrv);
    let simDmaReadSrv   <- mkSimDmaReadSrvAndReqRespPipeOut;
    let dmaReadReqSink  <- mkSink(simDmaReadSrv.dmaReadReq);
    let dmaReadRespSink <- mkSink(simDmaReadSrv.dmaReadResp);

    let errLenPipeOut <- mkRandomLenPipeOut(minErrLen, maxErrLen);
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;
    Count#(Length) payloadLenCnt <- mkCount(0);
    Reg#(Bool) errRespGenReg <- mkReg(False);

    rule genErrDmaReadRespIfNeeded;
        let dmaReadResp <- simDmaReadSrv.dmaReadSrv.response.get;
        let curFragLen = calcByteEnBitNumInSim(dmaReadResp.dataStream.byteEn);
        let errLen = errLenPipeOut.first;

        dmaReadResp.isRespErr = errRespGenReg;
        if (hasRespErr) begin
            if (!errRespGenReg) begin
                if (payloadLenCnt >= errLen) begin
                    payloadLenCnt <= 0;
                    dmaReadResp.isRespErr = True;
                    errRespGenReg <= True;
                    errLenPipeOut.deq;
                end
                else begin
                    payloadLenCnt <= payloadLenCnt + zeroExtend(curFragLen);
                end
            end

                dmaReadRespQ.enq(dmaReadResp);
        end
        else begin
            dmaReadRespQ.enq(dmaReadResp);
        end
    endrule

    interface request = simDmaReadSrv.dmaReadSrv.request;
    interface response = toGet(dmaReadRespQ);
endmodule

interface DmaWriteSrvAndReqRespPipeOut;
    interface DmaWriteSrv dmaWriteSrv;
    interface PipeOut#(DmaWriteReq) dmaWriteReq;
    interface PipeOut#(DmaWriteResp) dmaWriteResp;
endinterface

module mkSimDmaWriteSrvAndReqRespPipeOut(DmaWriteSrvAndReqRespPipeOut);
    FIFOF#(DmaWriteReq) dmaWriteReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ <- mkFIFOF;
    FIFOF#(DmaWriteReq) dmaWriteReqOutQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespOutQ <- mkFIFOF;

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
            dmaWriteRespOutQ.enq(dmaWriteResp);
        endaction
    endfunction

    rule write;
        let dmaWriteReq = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;
        dmaWriteReqOutQ.enq(dmaWriteReq);

        // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));

        if (dmaWriteReq.dataStream.isLast) begin
            genDmaWriteResp(dmaWriteReq.metaData);
        end
    endrule

    interface dmaWriteSrv  = toGPServer(dmaWriteReqQ, dmaWriteRespQ);
    interface dmaWriteReq  = convertFifo2PipeOut(dmaWriteReqOutQ);
    interface dmaWriteResp = convertFifo2PipeOut(dmaWriteRespOutQ);
endmodule

interface DmaWriteSrvAndDataStreamPipeOut;
    interface DmaWriteSrv dmaWriteSrv;
    interface DataStreamPipeOut dataStream;
endinterface

module mkSimDmaWriteSrvAndDataStreamPipeOut(DmaWriteSrvAndDataStreamPipeOut);
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndReqRespPipeOut;
    let dmaWriteRespSink <- mkSink(simDmaWriteSrv.dmaWriteResp);
    DataStreamPipeOut dataStreamPipeOut <- mkFunc2Pipe(
        getDmaWriteReqData, simDmaWriteSrv.dmaWriteReq
    );

    interface dmaWriteSrv = simDmaWriteSrv.dmaWriteSrv;
    interface dataStream = dataStreamPipeOut;
endmodule

module mkSimDmaWriteSrv(DmaWriteSrv);
    let simDmaWriteSrv   <- mkSimDmaWriteSrvAndReqRespPipeOut;
    let dmaWriteReqSink  <- mkSink(simDmaWriteSrv.dmaWriteReq);
    let dmaWriteRespSink <- mkSink(simDmaWriteSrv.dmaWriteResp);
    return simDmaWriteSrv.dmaWriteSrv;
endmodule

module mkFixedLenSimDataStreamPipeOut#(
    PipeOut#(Length) dmaLenPipeOut
)(Vector#(vSz, DataStreamPipeOut));
    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dataStreamPipeOut <- mkDataStreamPipeOutFromDmaReadResp(simDmaReadSrv.response);
    Vector#(vSz, DataStreamPipeOut) dataStreamPipeOutVec <- mkForkVector(dataStreamPipeOut);

    rule sendDmaReq;
        let dmaLength = dmaLenPipeOut.first;
        dmaLenPipeOut.deq;

        let dmaReq = DmaReadReq {
            initiator: dontCareValue,
            sqpn     : getDefaultQPN,
            startAddr: dontCareValue,
            len      : dmaLength,
            wrID     : dontCareValue
        };
        simDmaReadSrv.request.put(dmaReq);
        // $display("time=%0t: dmaLength=%0d", $time, dmaLength);
    endrule

    return dataStreamPipeOutVec;
endmodule

// typedef Vector#(vSz, DataStreamPipeOut) SimDataStreamPipeOut#(type numeric vSz);
module mkRandomLenSimDataStreamPipeOut#(
    Length minDataStreamLength, Length maxDataStreamLength
)(Vector#(vSz, DataStreamPipeOut));
    let dmaLenPipeOut <- mkRandomLenPipeOut(minDataStreamLength, maxDataStreamLength);
    Vector#(vSz, DataStreamPipeOut) simDataStreamPipeOut <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut);

    return simDataStreamPipeOut;
endmodule

(* synthesize *)
module mkTestFixedLenSimDataStreamPipeOut(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 125;

    let dmaLenPipeOut <- mkRandomLenPipeOut(minDmaLength, maxDmaLength);
    let { dmaLenPipeOut4Gen, dmaLenPipeOut4Ref } <- mkForkAndBufferRight(dmaLenPipeOut);
    Vector#(1, DataStreamPipeOut) simDataStreamPipeOutVec <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut4Gen);
    Reg#(Length) refDmaLenReg <- mkRegU;
    Reg#(Length) totalDmaLenReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compare;
        let curDataStreamFrag = simDataStreamPipeOutVec[0].first;
        simDataStreamPipeOutVec[0].deq;

        let curLength = calcByteEnBitNumInSim(curDataStreamFrag.byteEn);

        let totalDmaLen = totalDmaLenReg;
        let refDmaLen = refDmaLenReg;
        if (curDataStreamFrag.isFirst) begin
            refDmaLen = dmaLenPipeOut4Ref.first;
            dmaLenPipeOut4Ref.deq;
            refDmaLenReg <= refDmaLen;

            totalDmaLen = zeroExtend(curLength);
            totalDmaLenReg <= zeroExtend(curLength);
        end
        else begin
            totalDmaLen = totalDmaLenReg + zeroExtend(curLength);
            totalDmaLenReg <= totalDmaLen;
        end

        if (curDataStreamFrag.isLast) begin
            immAssert(
                totalDmaLen == refDmaLen,
                "dataStream length assertion @ mkTestFixedLenSimDataStreamPipeOut",
                $format("totalDmaLen=%0d should == refDmaLen=%0d", totalDmaLen, refDmaLen)
            );
        end

        countDown.decr;
    endrule
endmodule
