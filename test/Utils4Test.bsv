import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import Array :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import Settings :: *;
import Utils :: *;

typedef 10000 MAX_CMP_CNT;

interface CountDown;
    method Action decr();
    method int   _read();
endinterface

module mkCountDown#(Integer maxValue)(CountDown);
    Reg#(Long) cycleNumReg <- mkReg(0);
    Count#(int) cnt <- mkCount(fromInteger(maxValue));

    rule countCycles;
        cycleNumReg <= cycleNumReg + 1;
    endrule

    method Action decr();
        cnt.decr(1);
        // $display("time=%0t: cycles=%0d, cmp cnt=%0d", $time, cycleNumReg, cnt);

        if (isZero(pack(cnt))) begin
            $info("time=%0t: finished after %0d cycles", $time, cycleNumReg);
            $finish(0);
        end
    endmethod

    method int _read() = cnt;
endmodule

function Bool filterEmptyDataStream(DataStream ds) = !isZero(ds.byteEn);

function Tuple2#(HeaderByteNum, HeaderBitNum) calcHeaderInvalidByteAndBitNum(
    HeaderByteNum headerLen
);
    HeaderByteNum headerInvalidByteNum =
        fromInteger(valueOf(HEADER_MAX_BYTE_EN_WIDTH)) - headerLen;
    HeaderBitNum headerInvalidBitNum = zeroExtend(headerInvalidByteNum) << 3;

    return tuple2(headerInvalidByteNum, headerInvalidBitNum);
endfunction

function Bool compareRdmaHeaderDataInSim(
    HeaderData headerData, HeaderData refHeaderData, HeaderByteNum headerLen
);
    let { headerInvalidByteNum, headerInvalidBitNum } =
        calcHeaderInvalidByteAndBitNum(headerLen);
    let shiftedHeaderData = headerData >> headerInvalidBitNum;
    let shiftedRefHeaderData = refHeaderData >> headerInvalidBitNum;

    return shiftedHeaderData == shiftedRefHeaderData;
endfunction

// This function should be used in simulation only
function ByteEnBitNum calcByteEnBitNumInSim(ByteEn fragByteEn);
    let rightAlignedByteEn = reverseBits(fragByteEn);
    ByteEnBitNum byteEnBitNum = 0;
    // Bool matched = False;
    for (
        Integer idx = 0;
        idx <= valueOf(DATA_BUS_BYTE_WIDTH);
        idx = idx + 1
    ) begin
        if (rightAlignedByteEn == (fromInteger(1) << idx) - 1) begin
            byteEnBitNum = fromInteger(idx);
            // matched = True;
        end
    end
    // $display("matched=%b, rightAlignedByteEn=%h", matched, rightAlignedByteEn);
    return byteEnBitNum;
endfunction

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

function Bool rdmaReqOpCodeMatchWorkReqOpCode(RdmaOpCode rdmaOpCode, WorkReqOpCode wrOpCode);
    return case (rdmaOpCode)
        SEND_FIRST, SEND_MIDDLE            : (wrOpCode == IBV_WR_SEND || wrOpCode == IBV_WR_SEND_WITH_IMM || wrOpCode == IBV_WR_SEND_WITH_INV);
        SEND_LAST, SEND_ONLY               : (wrOpCode == IBV_WR_SEND);
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           : (wrOpCode == IBV_WR_SEND_WITH_IMM);

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: (wrOpCode == IBV_WR_RDMA_WRITE || wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   : (wrOpCode == IBV_WR_RDMA_WRITE);
        RDMA_WRITE_LAST_WITH_IMMEDIATE     ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : (wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);

        RDMA_READ_REQUEST                  : (wrOpCode == IBV_WR_RDMA_READ);
        COMPARE_SWAP                       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP);
        FETCH_ADD                          : (wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);

        SEND_LAST_WITH_INVALIDATE          ,
        SEND_ONLY_WITH_INVALIDATE          : (wrOpCode == IBV_WR_SEND_WITH_INV);

        default                            : False;
    endcase;
endfunction

function Bool rdmaRespOpCodeMatchWorkReqOpCode(RdmaOpCode rdmaOpCode, WorkReqOpCode wrOpCode);
    case (wrOpCode)
        IBV_WR_RDMA_WRITE            ,
        IBV_WR_RDMA_WRITE_WITH_IMM   ,
        IBV_WR_SEND                  ,
        IBV_WR_SEND_WITH_IMM         ,
        IBV_WR_SEND_WITH_INV         : return rdmaOpCode == ACKNOWLEDGE;
        IBV_WR_RDMA_READ             : return case (rdmaOpCode)
            RDMA_READ_RESPONSE_FIRST ,
            RDMA_READ_RESPONSE_MIDDLE,
            RDMA_READ_RESPONSE_LAST  ,
            RDMA_READ_RESPONSE_ONLY  ,
            ACKNOWLEDGE              : True;
            default                  : False;
        endcase;
        IBV_WR_ATOMIC_CMP_AND_SWP    ,
        IBV_WR_ATOMIC_FETCH_AND_ADD  : return case (rdmaOpCode)
            ACKNOWLEDGE              ,
            ATOMIC_ACKNOWLEDGE       : True;
            default                  : False;
        endcase;
        default                      : return False;
    endcase
endfunction

function Bool workCompMatchWorkReqInSQ(WorkComp wc, WorkReq wr);
    return wc.id == wr.id && case (wr.opcode)
        IBV_WR_RDMA_WRITE          : (wc.opcode == IBV_WC_RDMA_WRITE);
        IBV_WR_RDMA_WRITE_WITH_IMM : (wc.opcode == IBV_WC_RDMA_WRITE);
        IBV_WR_SEND                : (wc.opcode == IBV_WC_SEND);
        IBV_WR_SEND_WITH_IMM       : (wc.opcode == IBV_WC_SEND);
        IBV_WR_RDMA_READ           : (wc.opcode == IBV_WC_RDMA_READ);
        IBV_WR_ATOMIC_CMP_AND_SWP  : (wc.opcode == IBV_WC_COMP_SWAP);
        IBV_WR_ATOMIC_FETCH_AND_ADD: (wc.opcode == IBV_WC_FETCH_ADD);
        IBV_WR_LOCAL_INV           : (wc.opcode == IBV_WC_LOCAL_INV);
        IBV_WR_BIND_MW             : (wc.opcode == IBV_WC_BIND_MW);
        IBV_WR_SEND_WITH_INV       : (wc.opcode == IBV_WC_SEND);
        IBV_WR_TSO                 : (wc.opcode == IBV_WC_TSO);
        IBV_WR_DRIVER1             : (wc.opcode == IBV_WC_DRIVER1);
        default                    : False;
    endcase;
endfunction

function Bool workCompMatchWorkReqInRQ(WorkComp wc, WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM : (wc.opcode == IBV_WC_RECV_RDMA_WITH_IMM && compareWorkCompFlags(wc.flags, IBV_WC_WITH_IMM));
        IBV_WR_SEND                : (wc.opcode == IBV_WC_RECV);
        IBV_WR_SEND_WITH_IMM       : (wc.opcode == IBV_WC_RECV && compareWorkCompFlags(wc.flags, IBV_WC_WITH_IMM));
        IBV_WR_SEND_WITH_INV       : (wc.opcode == IBV_WC_RECV && compareWorkCompFlags(wc.flags, IBV_WC_WITH_INV));
        default                    : False;
    endcase;
endfunction

function Bool isFatalErrAETH(AETH aeth);
    case (aeth.code)
        // AETH_CODE_ACK: return tagged Valid IBV_WC_SUCCESS;
        // AETH_CODE_RNR: return tagged Valid IBV_WC_RNR_RETRY_EXC_ERR;
        AETH_CODE_NAK: return case (aeth.value)
            // zeroExtend(pack(AETH_NAK_SEQ_ERR)): tagged Valid IBV_WC_RETRY_EXC_ERR;
            zeroExtend(pack(AETH_NAK_INV_REQ)),
            zeroExtend(pack(AETH_NAK_RMT_ACC)),
            zeroExtend(pack(AETH_NAK_RMT_OP)) ,
            zeroExtend(pack(AETH_NAK_INV_RD)) : True;
            default                           : False;
        endcase;
        // AETH_CODE_RSVD
        default: return False;
    endcase
endfunction

// This module should be used in simulation only
module mkSegmentDataStreamByPmtu#(
    DataStreamPipeOut dataStreamPipeIn,
    PipeOut#(PMTU) pmtuPipeIn
)(DataStreamPipeOut);
    Reg#(PmtuFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PmtuFragNum) fragCntReg <- mkRegU;
    FIFOF#(DataStream) dataQ <- mkFIFOF;
    Reg#(Bool) setFirstReg <- mkReg(False);

    rule segment;
        let curData = dataStreamPipeIn.first;
        dataStreamPipeIn.deq;
        Bool isFragCntZero = isZero(fragCntReg);

        if (!setFirstReg && curData.isFirst) begin
            let pmtu = pmtuPipeIn.first;
            pmtuPipeIn.deq;
            let pmtuFragNum = calcFragNumByPmtu(pmtu);
            pmtuFragNumReg <= pmtuFragNum;
            fragCntReg <= pmtuFragNum - 2;
        end
        else if (setFirstReg) begin
            curData.isFirst = True;
            setFirstReg <= False;
            fragCntReg <= pmtuFragNumReg - 2;
        end
        else if (isFragCntZero) begin
            curData.isLast = True;
            setFirstReg <= True;
        end
        else if (!curData.isLast) begin
            fragCntReg <= fragCntReg - 1;
        end

        dataQ.enq(curData);
    endrule

    method DataStream first() = dataQ.first;
    method Action deq() = dataQ.deq;
    method Bool notEmpty() = dataQ.notEmpty;
endmodule

// This function should be used in simulation only
function ByteEn addPadding2LastFragByteEn(ByteEn lastFragByteEn);
    let lastFragValidByteNum = calcByteEnBitNumInSim(lastFragByteEn);
    let padCnt = calcPadCnt(zeroExtend(lastFragValidByteNum));
    let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
    let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
    return lastFragByteEnWithPadding;
endfunction

// This module should be used in simulation only
module mkSegmentDataStreamByPmtuAndAddPadCnt#(
    DataStreamPipeOut dataStreamPipeIn,
    PipeOut#(PMTU) pmtuPipeIn
)(DataStreamPipeOut);
    function DataStream addPadding(DataStream inputDataStream);
        if (inputDataStream.isLast) begin
            let lastFragByteEnWithPadding = addPadding2LastFragByteEn(
                inputDataStream.byteEn
            );
            // $display(
            //     "time=%0t: inputDataStream.byteEn=%h, padCnt=%0d",
            //     $time, inputDataStream.byteEn, padCnt
            // );
            inputDataStream.byteEn = lastFragByteEnWithPadding;
        end

        return inputDataStream;
    endfunction

    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        dataStreamPipeIn, pmtuPipeIn
    );

    let resultPipeOut <- mkFunc2Pipe(addPadding, segDataStreamPipeOut);
    return resultPipeOut;
endmodule

module mkGenericRandomPipeOut(PipeOut#(anytype))
provisos(Bits#(anytype, anysize), Bounded#(anytype));
    Randomize#(anytype) randomGen <- mkGenericRandomizer;
    FIFOF#(anytype) randomValQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let val <- randomGen.next;
        randomValQ.enq(val);
    endrule

    return convertFifo2PipeOut(randomValQ);
endmodule

module mkGenericRandomPipeOutVec(Vector#(vSz, PipeOut#(anytype)))
provisos(Bits#(anytype, anysize), Bounded#(anytype));
    PipeOut#(anytype) resultPipeOut <- mkGenericRandomPipeOut;
    Vector#(vSz, PipeOut#(anytype)) resultPipeOutVec <-
        mkForkVector(resultPipeOut);
    return resultPipeOutVec;
endmodule

module mkRandomValueInRangePipeOut#(
    // Both min and max are inclusive
    anytype min, anytype max
)(Vector#(vSz, PipeOut#(anytype)))
provisos (Bits#(anytype, anysize), Bounded#(anytype), FShow#(anytype), Ord#(anytype));
    Randomize#(anytype) randomVal <- mkConstrainedRandomizer(min, max);
    FIFOF#(anytype) randomValQ <- mkFIFOF;
    let resultPipeOutVec <- mkForkVector(convertFifo2PipeOut(randomValQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        immAssert(
            max >= min,
            "max >= min assertion @",
            $format(
                "max=", fshow(max), " should >= min=", fshow(min)
            )
        );
        randomVal.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let val <- randomVal.next;
        randomValQ.enq(val);
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomLenPipeOut#(
    // Both min and max are inclusive
    Length minLength, Length maxLength
)(PipeOut#(Length));
    Randomize#(Length) randomLen <- mkConstrainedRandomizer(minLength, maxLength);
    FIFOF#(Length) lenQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        immAssert(
            maxLength >= minLength,
            "maxLength >= minLength assertion @",
            $format(
                "maxLength=%h should >= minLength=%h", minLength, maxLength
            )
        );
        randomLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let len <- randomLen.next;
        // $display(
        //     "time=%0t: generate random len=%0d in range(min=%0d, max=%0d)",
        //     $time, len, minLength, maxLength
        // );
        lenQ.enq(len);
    endrule

    return convertFifo2PipeOut(lenQ);
endmodule

module mkFixedLenHeaderMetaPipeOut#(
    PipeOut#(HeaderByteNum) headerLenPipeIn,
    Bool alwaysHasPayload
)(Vector#(vSz, PipeOut#(HeaderMetaData)));
    FIFOF#(HeaderMetaData) headerMetaDataQ <- mkFIFOF;
    Vector#(vSz, PipeOut#(HeaderMetaData)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(headerMetaDataQ));

    rule enq;
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragValidByeNum(headerLen);
        let headerMetaData = HeaderMetaData {
            headerLen: headerLen,
            headerFragNum: headerFragNum,
            lastFragValidByteNum: headerLastFragValidByteNum,
            // Use the last bit of HeaderLen to randomize hasPayload
            hasPayload: alwaysHasPayload || unpack(headerLen[0])
        };
        headerMetaDataQ.enq(headerMetaData);
        // $display("time=%0t: headerMetaData=", $time, fshow(headerMetaData));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomHeaderMetaPipeOut#(
    HeaderByteNum minHeaderLen,
    HeaderByteNum maxHeaderLen,
    Bool alwaysHasPayload
)(Vector#(vSz, PipeOut#(HeaderMetaData)));
    FIFOF#(HeaderByteNum) headerLenQ <- mkFIFOF;
    Randomize#(HeaderByteNum) randomHeaderLen <-
        mkConstrainedRandomizer(minHeaderLen, maxHeaderLen);
    Vector#(vSz, PipeOut#(HeaderMetaData)) resultPipeOutVec <-
        mkFixedLenHeaderMetaPipeOut(
            convertFifo2PipeOut(headerLenQ),
            alwaysHasPayload
        );

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomHeaderLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule enq if (initializedReg);
        let headerLen <- randomHeaderLen.next;
        headerLenQ.enq(headerLen);
        // $display("time=%0t: headerLen=%0d", $time, headerLen);
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomItemFromVec#(
    Vector#(vSz, anytype) items
)(PipeOut#(anytype)) provisos(
    Bits#(anytype, anysize),
    NumAlias#(TLog#(vSz), idxSz)
);
    UInt#(idxSz) maxIdx = fromInteger(valueOf(vSz) - 1);
    Vector#(1, PipeOut#(UInt#(idxSz))) vecIdxPipeOut <-
        mkRandomValueInRangePipeOut(0, maxIdx);
    let resultPipeOut <- mkFunc2Pipe(select(items), vecIdxPipeOut[0]);
    return resultPipeOut;
endmodule

module mkRandomAtomicReqRdmaOpCode(PipeOut#(RdmaOpCode));
    RdmaOpCode atomicOpCodeArray[2] = {
        COMPARE_SWAP,
        FETCH_ADD
    };
    Vector#(2, RdmaOpCode) atomicOpCodeVec = arrayToVector(atomicOpCodeArray);

    PipeOut#(RdmaOpCode) resultPipeOut <- mkRandomItemFromVec(atomicOpCodeVec);
    return resultPipeOut;
endmodule

module mkRandomAtomicWorkReqOpCode(PipeOut#(WorkReqOpCode));
    WorkReqOpCode atomicOpCodeArray[2] = {
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD
    };
    Vector#(2, WorkReqOpCode) atomicOpCodeVec = arrayToVector(atomicOpCodeArray);

    PipeOut#(WorkReqOpCode) resultPipeOut <- mkRandomItemFromVec(atomicOpCodeVec);
    return resultPipeOut;
endmodule

module mkSimGenWorkReqByOpCode#(
    PipeOut#(WorkReqOpCode) workReqOpCodePipeIn,
    Length minLength,
    Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    FIFOF#(WorkReq) workReqOutQ <- mkFIFOF;
    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IMM) immDtPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rkey2InvPipeOut <- mkGenericRandomPipeOut;
    let dmaLenPipeOut <- mkRandomLenPipeOut(minLength, maxLength);
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(workReqOutQ));

    rule genWorkReq;
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let dmaLen = dmaLenPipeOut.first;
        dmaLenPipeOut.deq;

        let wrOpCode = workReqOpCodePipeIn.first;
        workReqOpCodePipeIn.deq;

        let isAtomicWR = isAtomicWorkReq(wrOpCode);

        let comp = compPipeOut.first;
        compPipeOut.deq;

        let swap = swapPipeOut.first;
        swapPipeOut.deq;

        let immDt = immDtPipeOut.first;
        immDtPipeOut.deq;

        let rkey2Inv = rkey2InvPipeOut.first;
        rkey2InvPipeOut.deq;

        QPN srqn = dontCareValue;
        QPN dqpn = dontCareValue;
        QKEY qkey = dontCareValue;
        let workReq = WorkReq {
            id       : wrID,
            opcode   : wrOpCode,
            flags    : IBV_SEND_SIGNALED,
            raddr    : isAtomicWR ? 0 : dontCareValue,
            rkey     : dontCareValue,
            len      : isAtomicWR ? fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)) : dmaLen,
            laddr    : dontCareValue,
            lkey     : dontCareValue,
            sqpn     : dontCareValue,
            solicited: dontCareValue,
            comp     : workReqHasComp(wrOpCode) ? (tagged Valid comp) : (tagged Invalid),
            swap     : workReqHasSwap(wrOpCode) ? (tagged Valid swap) : (tagged Invalid),
            immDt    : workReqHasImmDt(wrOpCode) ? (tagged Valid immDt) : (tagged Invalid),
            rkey2Inv : workReqHasInv(wrOpCode) ? (tagged Valid rkey2Inv) : (tagged Invalid),
            srqn     : tagged Valid srqn,
            dqpn     : tagged Valid dqpn,
            qkey     : tagged Valid qkey
        };
        workReqOutQ.enq(workReq);
        // $display("time=%0t: generate random WR=", $time, fshow(workReq));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomWorkReqInRange#(
    Vector#(wrVecSz, WorkReqOpCode) workReqOpCodeVec,
    Length minLength,
    Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    let resultPipeOutVec <- mkSimGenWorkReqByOpCode(
        workReqOpCodePipeOut, minLength, maxLength
    );
    return resultPipeOutVec;
endmodule

module mkRandomWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    WorkReqOpCode workReqOpCodeArray[8] = {
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD,
        IBV_WR_SEND_WITH_INV
    };
    Vector#(8, WorkReqOpCode) workReqOpCodeVec = arrayToVector(workReqOpCodeArray);
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength
    );
    return resultPipeOutVec;
endmodule

module mkRandomSendWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    WorkReqOpCode workReqOpCodeArray[3] = {
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV
    };
    Vector#(3, WorkReqOpCode) workReqOpCodeVec = arrayToVector(workReqOpCodeArray);
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength
    );
    return resultPipeOutVec;
endmodule

module mkRandomReadWorkReq#(
    Length minLength, Length maxLength
)(PipeOut#(WorkReq));
    PipeOut#(WorkReqOpCode) readWorkReqOpCodePipeOut <-
        mkConstantPipeOut(IBV_WR_RDMA_READ);
    Vector#(1, PipeOut#(WorkReq)) resultPipeOutVec <- mkSimGenWorkReqByOpCode(
        readWorkReqOpCodePipeOut, minLength, maxLength
    );
    return resultPipeOutVec[0];
endmodule

module mkRandomReadOrAtomicWorkReq#(
    Length minLength, Length maxLength
)(PipeOut#(WorkReq));
    WorkReqOpCode workReqOpCodeArray[3] = {
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD
    };
    Vector#(3, WorkReqOpCode) workReqOpCodeVec = arrayToVector(workReqOpCodeArray);
    Vector#(1, PipeOut#(WorkReq)) resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength
    );
    return resultPipeOutVec[0];
endmodule

module mkGenIllegalAtomicWorkReq(PipeOut#(WorkReq));
    FIFOF#(WorkReq) workReqOutQ <- mkFIFOF;
    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR) addrPipeOut <- mkGenericRandomPipeOut;
    let atomicWorkReqOpCodePipeOut <- mkRandomAtomicWorkReqOpCode;

    rule genWorkReq;
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let addr = addrPipeOut.first;
        addrPipeOut.deq;

        ADDR unalignedAddr = truncate({ addr, 1'b1 });

        let wrOpCode = atomicWorkReqOpCodePipeOut.first;
        atomicWorkReqOpCodePipeOut.deq;

        Long comp = dontCareValue;
        Long swap = dontCareValue;
        IMM immDt = dontCareValue;
        RKEY rkey2Inv = dontCareValue;
        QPN srqn = dontCareValue;
        QPN dqpn = dontCareValue;
        QKEY qkey = dontCareValue;
        let workReq = WorkReq {
            id       : wrID,
            opcode   : wrOpCode,
            flags    : IBV_SEND_NO_FLAGS,
            raddr    : unalignedAddr,
            rkey     : dontCareValue,
            len      : fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
            laddr    : dontCareValue,
            lkey     : dontCareValue,
            sqpn     : dontCareValue,
            solicited: dontCareValue,
            comp     : tagged Valid comp,
            swap     : tagged Valid swap,
            immDt    : tagged Invalid,
            rkey2Inv : tagged Invalid,
            srqn     : tagged Invalid,
            dqpn     : tagged Invalid,
            qkey     : tagged Invalid
        };
        workReqOutQ.enq(workReq);
        // $display("time=%0t: generate illegal atomic WR=", $time, fshow(workReq));
    endrule

    return convertFifo2PipeOut(workReqOutQ);
endmodule

module mkGenNormalOrDupWorkReq#(
    Bool normalOrDupReq,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(Tuple2#(PipeOut#(Bool), PipeOut#(PendingWorkReq)));
    Reg#(Bool) normalOrDupReqReg <- mkReg(True);
    Reg#(PendingWorkReq) dupWorkReqReg <- mkRegU;

    PipeOut#(Tuple2#(Bool, PendingWorkReq)) normalOrDupWorkReqPipeOut = interface PipeOut;
        method Tuple2#(Bool, PendingWorkReq) first();
            return tuple2(
                normalOrDupReqReg,
                normalOrDupReqReg ?
                    pendingWorkReqPipeIn.first : dupWorkReqReg
            );
        endmethod

        method Action deq();
            if (normalOrDupReqReg) begin
                pendingWorkReqPipeIn.deq;
                dupWorkReqReg <= pendingWorkReqPipeIn.first;
                // $display(
                //     "time=%0t:", $time,
                //     " normal pendingWR=", fshow(pendingWorkReqPipeIn.first)
                // );
            end
            else begin
                // $display(
                //     "time=%0t:", $time,
                //     " duplicate pendingWR=", fshow(dupWorkReqReg)
                // );
            end

            if (!normalOrDupReq) begin
                normalOrDupReqReg <= !normalOrDupReqReg;
            end
        endmethod

        method Bool notEmpty();
            return normalOrDupReqReg ? pendingWorkReqPipeIn.notEmpty : True;
        endmethod
    endinterface;

    let resultPipeOut <- mkFork(identityFunc, normalOrDupWorkReqPipeOut);
    return resultPipeOut;
endmodule

module mkSimController#(QpType qpType, PMTU pmtu)(Controller);
    PSN minPSN = 0;
    PSN maxPSN = maxBound;

    let cntrl <- mkController;
    Randomize#(PSN) randomEPSN <- mkConstrainedRandomizer(minPSN, maxPSN);
    Randomize#(PSN) randomNPSN <- mkConstrainedRandomizer(minPSN, maxPSN);
    Randomize#(PKEY) randomPKEY <- mkGenericRandomizer;
    Randomize#(QKEY) randomQKEY <- mkGenericRandomizer;
    Reg#(Bool) initializedReg <- mkReg(False);

    rule initRandomizer if (!initializedReg);
        randomEPSN.cntrl.init;
        randomNPSN.cntrl.init;
        randomPKEY.cntrl.init;
        randomQKEY.cntrl.init;
        initializedReg <= True;
    endrule

    rule initController if (initializedReg && cntrl.getQPS == IBV_QPS_RESET);
        let epsn <- randomEPSN.next;
        let npsn <- randomNPSN.next;
        let pkey <- randomPKEY.next;
        let qkey <- randomQKEY.next;
        cntrl.initialize(
            qpType,
            3, // maxRnrCnt
            3, // maxRetryCnt
            1, // maxTimeOut 0 - infinite, 1 - 8.192 usec (0.000008 sec)
            1, // minRnrTimer 1 - 0.01 milliseconds delay
            fromInteger(valueOf(MAX_QP_WR)), // pendingWorkReqNum
            fromInteger(valueOf(MAX_QP_WR)), // pendingRecvReqNum
            fromInteger(valueOf(MAX_QP_RD_ATOM)), // pendingReadAtomicReqNum
            False, // sigAll
            dontCareValue, // sqpn
            dontCareValue, // dqpn
            pkey,
            qkey,
            pmtu,
            npsn,
            epsn
        );
    endrule

    rule setRTR if (initializedReg && cntrl.isInit);
        cntrl.setStateRTR;
    endrule

    rule setRTS if (initializedReg && cntrl.isRTR);
        cntrl.setStateRTS;
    endrule

    return cntrl;
endmodule

module mkSimPermCheckMR#(Bool mrCheckPassOrFail)(PermCheckMR);
    FIFOF#(PermCheckInfo) checkReqQ <- mkFIFOF;
    FIFOF#(Bool) checkRespQ <- mkFIFOF;

    rule check;
        checkReqQ.deq;
        checkRespQ.enq(mrCheckPassOrFail);
    endrule

    // method Action checkReq(PermCheckInfo permCheckInfo);
    //     checkReqQ.enq(permCheckInfo);
    // endmethod

    // method ActionValue#(Bool) checkResp();
    //     let permCheckInfo = checkReqQ.first;
    //     checkReqQ.deq;

    //     return mrCheckPassOrFail;
    // endmethod

    return toGPServer(checkReqQ, checkRespQ);
endmodule

module mkSimMetaDataQPs#(QpType qpType, PMTU pmtu)(MetaDataQPs);
    let cntrl <- mkSimController(qpType, pmtu);

    method Action createQP(QKEY qkey);
        noAction;
    endmethod

    method ActionValue#(QPN) createResp();
        return dontCareValue;
    endmethod

    method Action destroyQP(QPN qpn);
        noAction;
    endmethod

    method ActionValue#(Bool) destroyResp();
        return True;
    endmethod

    method Bool isValidQP(QPN qpn) = True;
    method Maybe#(PdHandler) getPD(QPN qpn);
        return tagged Valid dontCareValue;
    endmethod
    method Controller getCntrl(QPN qpn) = cntrl;

    method Action clear();
        noAction;
    endmethod

    method Bool notEmpty() = True;
    method Bool notFull() = True;
endmodule

module mkSimGenRecvReq#(Controller cntrl)(Vector#(vSz, PipeOut#(RecvReq)));
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;
    PipeOut#(WorkReqID) recvReqIdPipeOut <- mkGenericRandomPipeOut;

    rule genRR;
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
    endrule

    Vector#(vSz, PipeOut#(RecvReq)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(recvReqQ));
    return resultPipeOutVec;
endmodule

module mkSimRetryHandlerWithLimitExcErr(RetryHandleSQ);
    // FIFOF#(PendingWorkReq) emptyQ <- mkFIFOF;
    method Bool hasRetryErr() = True;
    method Bool isRetryDone() = False;
    method Bool isRetrying() = False;
    method Action resetRetryCntBySQ();
        noAction;
    endmethod
    method Action resetTimeOutBySQ();
        noAction;
    endmethod
    method Action notifyRetryFromSQ(
        WorkReqID        wrID,
        PSN              retryStartPSN,
        RetryReason      retryReason,
        Maybe#(RnrTimer) retryRnrTimer
    );
        noAction;
    endmethod
    // interface retryWorkReqPipeOut = convertFifo2PipeOut(emptyQ);
endmodule

/*
module mkPendingWorkReqPipeOut#(
    PipeOut#(WorkReq) workReqPipeIn, PMTU pmtu
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    Reg#(PSN) nextPSN <- mkReg(maxBound);

    function ActionValue#(PendingWorkReq) genExistingPendingWorkReq(WorkReq wr);
        actionvalue
            let startPktSeqNum = nextPSN;
            let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
                calcPktNumNextAndEndPSN(
                    startPktSeqNum,
                    wr.len,
                    pmtu
                );

            nextPSN <= nextPktSeqNum;
            let isOnlyReqPkt = isOnlyPkt || isReadWorkReq(wr.opcode);
            let pendingWR = PendingWorkReq {
                wr: wr,
                startPSN: tagged Valid startPktSeqNum,
                endPSN: tagged Valid endPktSeqNum,
                pktNum: tagged Valid totalPktNum,
                isOnlyReqPkt: tagged Valid isOnlyReqPkt
            };

            // $display("time=%0t: generates pendingWR=", $time, fshow(pendingWR));
            return pendingWR;
        endactionvalue
    endfunction

    PipeOut#(PendingWorkReq) pendingWorkReqPipeOut <- mkActionValueFunc2Pipe(
        genExistingPendingWorkReq, workReqPipeIn
    );

    Vector#(vSz, PipeOut#(PendingWorkReq)) resultPipeOutVec <-
        mkForkVector(pendingWorkReqPipeOut);
    return resultPipeOutVec;
endmodule
*/
module mkExistingPendingWorkReqPipeOut#(
    Controller cntrl,
    PipeOut#(WorkReq) workReqPipeIn
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    FIFOF#(PendingWorkReq) pendingWorkReqOutQ <- mkFIFOF;
    let pendingWorkReqPipeOut = convertFifo2PipeOut(pendingWorkReqOutQ);

    rule setExpectedPSN if (cntrl.isInit);
        cntrl.contextRQ.restoreEPSN(cntrl.getNPSN);
    endrule

    rule genExistingPendingWorkReq if (cntrl.isRTS);
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let startPktSeqNum = cntrl.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
            calcPktNumNextAndEndPSN(
                startPktSeqNum,
                wr.len,
                cntrl.getPMTU
            );

        cntrl.setNPSN(nextPktSeqNum);
        let isOnlyReqPkt = isOnlyPkt || isReadWorkReq(wr.opcode);

        let pendingWR = PendingWorkReq {
            wr: wr,
            startPSN: tagged Valid startPktSeqNum,
            endPSN: tagged Valid endPktSeqNum,
            pktNum: tagged Valid totalPktNum,
            isOnlyReqPkt: tagged Valid isOnlyReqPkt
        };
        pendingWorkReqOutQ.enq(pendingWR);

        // $display(
        //     "time=%0t: generates pendingWR=", $time, fshow(pendingWR)
        // );
    endrule

    Vector#(vSz, PipeOut#(PendingWorkReq)) resultPipeOutVec <-
        mkForkVector(pendingWorkReqPipeOut);
    return resultPipeOutVec;
endmodule

module mkSimInputPktBuf#(
    Bool isRespPktPipeIn,
    DataStreamPipeOut rdmaPktPipeIn,
    MetaDataQPs qpMetaData
)(RdmaPktMetaDataAndPayloadPipeOut);
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaPktPipeIn
    );
    let inputRdmaPktBuf <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let reqPktMetaDataAndPayloadPipeOut = inputRdmaPktBuf.reqPktPipeOut;
    let respPktMetaDataAndPayloadPipeOut = inputRdmaPktBuf.respPktPipeOut;

    rule checkEmpty;
        if (isRespPktPipeIn) begin
            immAssert(
                !reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
                !reqPktMetaDataAndPayloadPipeOut.payload.notEmpty,
                "reqPktMetaDataAndPayloadPipeOut assertion @ mkSimInputPktBuf",
                $format(
                    "reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                    fshow(reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                    " and reqPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                    fshow(reqPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                    " should both be false"
                )
            );
        end
        else begin
            immAssert(
                !respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
                !respPktMetaDataAndPayloadPipeOut.payload.notEmpty,
                "respPktMetaDataAndPayloadPipeOut assertion @ mkSimInputPktBuf",
                $format(
                    "respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                    fshow(respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                    " and respPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                    fshow(respPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                    " should both be false"
                )
            );
        end

        immAssert(
            !inputRdmaPktBuf.cnpPipeOut.notEmpty,
            "cnpPipeOut empty assertion @ mkTestReceiveCNP",
            $format(
                "inputRdmaPktBuf.cnpPipeOut.notEmpty=",
                fshow(inputRdmaPktBuf.cnpPipeOut.notEmpty),
                " should be false"
            )
        );
    endrule

    return isRespPktPipeIn ? respPktMetaDataAndPayloadPipeOut : reqPktMetaDataAndPayloadPipeOut;
endmodule

// PipeOut related

module mkActionValueFunc2Pipe#(
    function ActionValue#(tb) avfn(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut #(tb)) provisos (Bits #(ta, taSz), Bits #(tb, tbSz));
    // let resultPipeOut <- mkTap(avfn, pipeIn); // No delay
    let resultPipeOut <- mkAVFn_to_Pipe(avfn, pipeIn); // One cycle delay
    return resultPipeOut;
endmodule

module mkDebugSink#(PipeOut#(anytype) pipeIn)(Empty) provisos(FShow#(anytype));
   rule drain;
      pipeIn.deq;
      $display("time=%0t: mkDebugSink drain ", $time, fshow(pipeIn.first));
   endrule
endmodule
