import FIFOF :: *;
import PAClib :: *;
import Cntrs :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

typedef enum {
    RDMA_REQ_ST_NORMAL,
    RDMA_REQ_ST_SEQ_ERR,
    RDMA_REQ_ST_RNR,
    RDMA_REQ_ST_INV_REQ,
    RDMA_REQ_ST_INV_RD,
    RDMA_REQ_ST_RMT_ACC,
    RDMA_REQ_ST_RMT_OP,
    RDMA_REQ_ST_DUP,
    RDMA_REQ_ST_ERR_FLUSH_RR,
    RDMA_REQ_ST_DISCARD,
    RDMA_REQ_ST_UNKNOWN
} RdmaReqStatus deriving(Bits, Eq, FShow);

function Bool isErrReqStatus(RdmaReqStatus reqStatus);
    return case (reqStatus)
        RDMA_REQ_ST_INV_REQ,
        RDMA_REQ_ST_INV_RD ,
        RDMA_REQ_ST_RMT_ACC,
        RDMA_REQ_ST_RMT_OP : True;
        default            : False;
    endcase;
endfunction

function Maybe#(QPN) getMaybeDestQpnRQ(Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_RC      ,
        IBV_QPT_UC      ,
        IBV_QPT_XRC_SEND, // TODO: XRC RQ should have its own controller
        IBV_QPT_XRC_RECV: tagged Valid cntrl.getDQPN;
        // IBV_QPT_UD
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(WorkCompStatus) genWorkCompStatusFromReqStatusRQ(RdmaReqStatus reqStatus);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL      : tagged Valid IBV_WC_SUCCESS;
        RDMA_REQ_ST_INV_REQ     : tagged Valid IBV_WC_REM_INV_REQ_ERR;
        RDMA_REQ_ST_INV_RD      : tagged Valid IBV_WC_REM_INV_RD_REQ_ERR;
        RDMA_REQ_ST_RMT_ACC     : tagged Valid IBV_WC_REM_ACCESS_ERR;
        RDMA_REQ_ST_RMT_OP      : tagged Valid IBV_WC_REM_OP_ERR;
        RDMA_REQ_ST_ERR_FLUSH_RR: tagged Valid IBV_WC_WR_FLUSH_ERR;
        default                 : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyRespRdmaOpCode(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus, Bool isOnlyRespPkt
);
    case (reqStatus)
        RDMA_REQ_ST_NORMAL,
        RDMA_REQ_ST_DUP   : begin
            return case (reqOpCode)
                SEND_FIRST                    ,
                SEND_MIDDLE                   ,
                SEND_LAST                     ,
                SEND_LAST_WITH_IMMEDIATE      ,
                SEND_ONLY                     ,
                SEND_ONLY_WITH_IMMEDIATE      ,
                SEND_LAST_WITH_INVALIDATE     ,
                SEND_ONLY_WITH_INVALIDATE     ,
                RDMA_WRITE_FIRST              ,
                RDMA_WRITE_MIDDLE             ,
                RDMA_WRITE_LAST               ,
                RDMA_WRITE_LAST_WITH_IMMEDIATE,
                RDMA_WRITE_ONLY               ,
                RDMA_WRITE_ONLY_WITH_IMMEDIATE: tagged Valid ACKNOWLEDGE;
                RDMA_READ_REQUEST             : tagged Valid (isOnlyRespPkt ? RDMA_READ_RESPONSE_ONLY : RDMA_READ_RESPONSE_FIRST);
                COMPARE_SWAP                  ,
                FETCH_ADD                     : tagged Valid ATOMIC_ACKNOWLEDGE;
                default                       : tagged Invalid;
            endcase;
        end
        RDMA_REQ_ST_SEQ_ERR,
        RDMA_REQ_ST_RNR    ,
        RDMA_REQ_ST_INV_REQ,
        RDMA_REQ_ST_INV_RD ,
        RDMA_REQ_ST_RMT_ACC,
        RDMA_REQ_ST_RMT_OP : begin
            return tagged Valid ACKNOWLEDGE;
        end
        default: return tagged Invalid;
    endcase
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastRespRdmaOpCode(RdmaOpCode reqOpCode, Bool isLastRespPkt);
    return case (reqOpCode)
        RDMA_READ_REQUEST: tagged Valid (isLastRespPkt ? RDMA_READ_RESPONSE_LAST : RDMA_READ_RESPONSE_MIDDLE);
        default          : tagged Invalid;
    endcase;
endfunction

function Maybe#(AETH) genAethByReqStatus(RdmaReqStatus reqStatus, Controller cntrl, MSN msn);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL,
        RDMA_REQ_ST_DUP   : begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_ACK,
                value: pack(AETH_ACK_VALUE_INVALID_CREDIT_CNT),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RNR: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_RNR,
                value: cntrl.getMinRnrTimer,
                msn  : msn
            };
        end
        RDMA_REQ_ST_SEQ_ERR: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_INV_REQ: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_INV_REQ)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_INV_RD: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_INV_RD)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RMT_ACC: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_RMT_ACC)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RMT_OP: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_RMT_OP)),
                msn  : msn
            };
        end
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaHeader) genFirstOrOnlyRespHeader(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus,
    Length payloadLen, Maybe#(Long) atomicOrigData,
    Controller cntrl, PSN psn, MSN msn, Bool isOnlyRespPkt
);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genFirstOrOnlyRespRdmaOpCode(reqOpCode, reqStatus, isOnlyRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrl);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrl, msn);

    let maybeAtomicAckEth = case (atomicOrigData) matches
        tagged Valid .origData: tagged Valid AtomicAckEth { orig: origData };
        default               : tagged Invalid;
    endcase;

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn   &&&
        maybeAETH   matches tagged Valid .aeth
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : isOnlyRespPkt ? calcPadCnt(payloadLen) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : False,
            resv7    : unpack(0),
            psn      : psn
        };

        return case (opcode)
            ACKNOWLEDGE: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    False // hasPayload
                );
            end
            ATOMIC_ACKNOWLEDGE: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth), pack(unwrapMaybe(maybeAtomicAckEth)) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH) + valueOf(ATOMIC_ACK_ETH_BYTE_WIDTH)),
                    False // hasPayload
                );
            end
            RDMA_READ_RESPONSE_FIRST,
            RDMA_READ_RESPONSE_ONLY : begin
                let hasPayload = !isZero(payloadLen);
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    hasPayload
                );
            end
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(RdmaHeader) genMiddleOrLastRespHeader(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus, Length payloadLen,
    Controller cntrl, PSN psn, MSN msn, Bool isLastRespPkt
);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genMiddleOrLastRespRdmaOpCode(reqOpCode, isLastRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrl);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrl, msn);

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn   &&&
        maybeAETH   matches tagged Valid .aeth
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : isLastRespPkt ? calcPadCnt(payloadLen) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : False,
            resv7    : unpack(0),
            psn      : psn
        };

        let hasPayload = True;
        if (isLastRespPkt) begin
            return tagged Valid genRdmaHeader(
                zeroExtendLSB({ pack(bth), pack(aeth) }),
                fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                hasPayload
            );
        end
        else begin
            return tagged Valid genRdmaHeader(
                zeroExtendLSB(pack(bth)),
                fromInteger(valueOf(BTH_BYTE_WIDTH)),
                hasPayload
            );
        end
    end
    else begin
        return tagged Invalid;
    end
endfunction

function RdmaReqStatus getInvReqStatusByTransType(TransType transType);
    return case (transType)
        TRANS_TYPE_RC : RDMA_REQ_ST_INV_REQ;
        TRANS_TYPE_UC : RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_RD : RDMA_REQ_ST_INV_RD ;
        TRANS_TYPE_UD : RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_CNP: RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_XRC: RDMA_REQ_ST_INV_RD ;
        default       : RDMA_REQ_ST_UNKNOWN;
    endcase;
endfunction

function RdmaReqStatus pktStatus2ReqStatusRQ(
    PktVeriStatus pktStatus, TransType transType
);
    return case (pktStatus)
        PKT_ST_VALID  : RDMA_REQ_ST_NORMAL;
        PKT_ST_LEN_ERR: getInvReqStatusByTransType(transType);
        PKT_ST_DISCARD: RDMA_REQ_ST_DISCARD;
        default       : RDMA_REQ_ST_UNKNOWN;
    endcase;
endfunction

typedef enum {
    RQ_SEQ_RETRY_FLUSH,
    RQ_RNR_RETRY_FLUSH,
    RQ_RNR_WAIT,
    RQ_RNR_WAIT_DONE,
    RQ_NOT_RETRY
} RetryFlushStateRQ deriving(Bits, Eq);

typedef struct {
    BTH bth;
    Epoch epoch;
    PktNum respPktNum;
    Bool isSendReq;
    Bool isWriteReq;
    Bool isWriteImmReq;
    Bool isReadReq;
    Bool isAtomicReq;
    Bool isZeroPayloadLen;
    Bool isOnlyPkt;
    Bool isFirstPkt;
    Bool isMidPkt;
    Bool isLastPkt;
    Bool isFirstOrOnlyPkt;
    Bool isLastOrOnlyPkt;
    Bool isOnlyRespPkt;
} RdmaReqPktInfo deriving(Bits);

typedef struct {
    Bool shouldGenResp;
    Bool expectReadRespPayload;
    Bool expectAtomicRespOrig;
    Bool expectDupAtomicCheckResp;
    Maybe#(Long) atomicAckOrig;
    DupReadReqStartState dupReadReqStartState;
} RespPktGenInfo deriving(Bits);

interface ReqHandleRQ;
    interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    // interface PipeOut#(PayloadGenReq) payloadGenReqPipeOut;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface PipeOut#(WorkCompGenReqRQ) workCompGenReqPipeOut;
endinterface

module mkReqHandleRQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    // PayloadGenerator payloadGenerator,
    PermCheckMR permCheckMR,
    DupReadAtomicCache dupReadAtomicCache,
    RecvReqBuf recvReqBuf,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn
)(ReqHandleRQ);
    FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(PayloadGenReq)     payloadGenReqOutQ <- mkFIFOF;
    FIFOF#(AtomicOpReq)            atomicOpReqQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqRQ) workCompGenReqOutQ <- mkFIFOF;
    FIFOF#(RdmaHeader)                  headerQ <- mkFIFOF;

    let atomicOpRespPipeIn <- mkAtomicOp(convertFifo2PipeOut(atomicOpReqQ));
    let payloadGenerator <- mkPayloadGenerator(
        cntrl, dmaReadSrv, convertFifo2PipeOut(payloadGenReqOutQ)
    );
    let payloadDataStreamPipeOut <- mkFunc2Pipe(
        getDataStreamFromPayloadGenRespPipeOut,
        payloadGenerator.respPipeOut
    );
    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(headerQ)
    );
    let rdmaRespPipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        payloadDataStreamPipeOut
    );

    FIFOF#(Tuple3#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo)) supportedReqOpCodeCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo)) reqOpCodeSeqCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaOpCode, RdmaReqPktInfo)) rnrCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo)) reqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, Bool)) reqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo)) dupReadReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, Bool)) dupReadReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState)) reqLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, ADDR, DupReadReqStartState)) initDmaReqQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) respGenCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) dupAtomicReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) dupAtomicReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo)) workCompReqQ <- mkFIFOF;

    Reg#(RnrWaitCycleCnt)        rnrWaitCntReg <- mkRegU;
    Reg#(RetryFlushStateRQ) retryFlushStateReg <- mkReg(RQ_NOT_RETRY);
    Reg#(Bool)              isErrFlushStateReg <- mkReg(False);
    Reg#(Bool)                 isErrRespGenReg <- mkReg(False);
    Reg#(Bool)            isGenMultiPktRespReg <- mkReg(False);

    Count#(Bit#(TLog#(MAX_QP_WR))) maxUnackedWorkReqCnt <- mkCount(fromInteger(valueOf(TSub#(MAX_QP_WR, 1))));

    Wire#(Bool) retryDoneWire <- mkDWire(False);

    // TODO: remove duplicate function definition
    function Action discardPktPayload(PmtuFragNum fragNum);
        action
            if (!isZero(fragNum)) begin
                let discardReq = PayloadConReq {
                    initiator  : OP_INIT_SQ_DISCARD,
                    fragNum    : fragNum,
                    consumeInfo: tagged DiscardPayload
                };
                payloadConReqOutQ.enq(discardReq);
            end
        endaction
    endfunction

    rule checkEPSN if (
        cntrl.isNonErr                     &&
        retryFlushStateReg == RQ_NOT_RETRY &&
        !isErrFlushStateReg
    );
        let curPktMetaData = pktMetaDataPipeIn.first;
        pktMetaDataPipeIn.deq;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        let reqStatus = RDMA_REQ_ST_UNKNOWN;
        let bth       = extractBTH(curRdmaHeader.headerData);
        let reth      = extractRETH(curRdmaHeader.headerData, bth.trans);
        let epoch     = cntrl.contextRQ.getEpoch;

        let isSendReq        = isSendReqRdmaOpCode(bth.opcode);
        let isWriteReq       = isWriteReqRdmaOpCode(bth.opcode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);
        let isReadReq        = isReadReqRdmaOpCode(bth.opcode);
        let isAtomicReq      = isAtomicReqRdmaOpCode(bth.opcode);
        let isFirstOrOnlyPkt = isFirstOrOnlyRdmaOpCode(bth.opcode);
        let isLastOrOnlyPkt  = isLastOrOnlyRdmaOpCode(bth.opcode);
        let isZeroPayloadLen = isZero(curPktMetaData.pktPayloadLen);

        let isOnlyPkt  = isOnlyRdmaOpCode(bth.opcode);
        let isFirstPkt = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt   = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt  = isLastRdmaOpCode(bth.opcode);

        let expectedPSN  = cntrl.contextRQ.getEPSN;
        let oldestPSN    = calcOldestValidPsn4RQ(expectedPSN);
        let isIllegalReq = !curPktMetaData.pktValid;
        let isExpected   = bth.psn == expectedPSN;
        let isDuplicated = psnInRangeExclusive(bth.psn, oldestPSN, expectedPSN);

        let { isOnlyRespPkt, respPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
            bth.psn, reth.dlen, cntrl.getPMTU
        );

        let reqPktInfo = RdmaReqPktInfo {
            bth             : bth,
            epoch           : epoch,
            respPktNum      : isReadReq ? respPktNum : 1,
            isSendReq       : isSendReq,
            isWriteReq      : isWriteReq,
            isWriteImmReq   : isWriteImmReq,
            isReadReq       : isReadReq,
            isAtomicReq     : isAtomicReq,
            isZeroPayloadLen: isZeroPayloadLen,
            isOnlyPkt       : isOnlyPkt,
            isFirstPkt      : isFirstPkt,
            isMidPkt        : isMidPkt,
            isLastPkt       : isLastPkt,
            isFirstOrOnlyPkt: isFirstOrOnlyPkt,
            isLastOrOnlyPkt : isLastOrOnlyPkt,
            isOnlyRespPkt   : isReadReq ? isOnlyRespPkt : True
        };

        if (isIllegalReq) begin
            reqStatus = pktStatus2ReqStatusRQ(curPktMetaData.pktStatus, bth.trans);
        end
        else if (bth.trans != TRANS_TYPE_UD) begin
            // ePSN check, no PSN check for UD
            case ({ pack(isExpected), pack(isDuplicated) })
                2'b10: begin
                    if (isReadReq) begin
                        cntrl.contextRQ.setEPSN(nextPktSeqNum);
                    end
                    else begin
                        cntrl.contextRQ.setEPSN(bth.psn + 1);
                    end
                    reqStatus = RDMA_REQ_ST_NORMAL;
                end
                2'b01: begin
                    reqStatus = RDMA_REQ_ST_DUP;
                end
                default: begin
                    reqStatus = RDMA_REQ_ST_SEQ_ERR;
                end
            endcase
        end

        immAssert(
            reqStatus != RDMA_REQ_ST_UNKNOWN,
            "reqStatus assertion @ mkReqHandleRQ",
            $format(
                "reqStatus=", fshow(reqStatus), " should not be unknown"
            )
        );
        supportedReqOpCodeCheckQ.enq(tuple3(curPktMetaData, reqStatus, reqPktInfo));
        $display(
            "time=%0t: 1st stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h, ePSN=%h, epoch=%h", bth.psn, expectedPSN, epoch,
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule checkSupportedReqOpCode if (
        cntrl.isNonErr                     &&
        retryFlushStateReg == RQ_NOT_RETRY &&
        !isErrFlushStateReg
    );
        let { pktMetaData, reqStatus, reqPktInfo } = supportedReqOpCodeCheckQ.first;
        supportedReqOpCodeCheckQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let isSupportedReqOpCode = isSupportedReqOpCodeRQ(cntrl.getQpType, bth.opcode);

        if (epoch == cntrl.contextRQ.getEpoch) begin
            if (reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
                // Update bth.psn to ePSN when SEQ ERR
                reqPktInfo.bth.psn = cntrl.contextRQ.getEPSN;
            end
            else if (!isSupportedReqOpCode) begin
                if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                end
                else if (reqStatus == RDMA_REQ_ST_DUP) begin
                    reqStatus = RDMA_REQ_ST_DISCARD;
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 2nd stage, epoch=", $time, fshow(epoch),
                ", cntrl.contextRQ.getEpoch=", fshow(cntrl.contextRQ.getEpoch)
            );
        end
        reqOpCodeSeqCheckQ.enq(tuple3(pktMetaData, reqStatus, reqPktInfo));
        // $display(
        //     "time=%0t: 2nd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", isSupportedReqOpCode=", fshow(isSupportedReqOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule checkNormalReqOpCodeSeq if (
        cntrl.isNonErr                     &&
        retryFlushStateReg == RQ_NOT_RETRY &&
        !isErrFlushStateReg
    );
        let { pktMetaData, reqStatus, reqPktInfo } = reqOpCodeSeqCheckQ.first;
        reqOpCodeSeqCheckQ.deq;

        let bth        = reqPktInfo.bth;
        let epoch      = reqPktInfo.epoch;
        let preOpCode  = cntrl.contextRQ.getPreReqOpCode;

        if (epoch == cntrl.contextRQ.getEpoch) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                let seqCheckResult = checkNormalReqOpCodeSeqRQ(preOpCode, bth.opcode);
                if (seqCheckResult) begin
                    cntrl.contextRQ.setPreReqOpCode(bth.opcode);
                end
                else begin
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 3rd stage, epoch=", $time, fshow(epoch),
                ", cntrl.contextRQ.getEpoch=", fshow(cntrl.contextRQ.getEpoch)
            );
        end

        rnrCheckQ.enq(tuple4(pktMetaData, reqStatus, preOpCode, reqPktInfo));
        // $display(
        //     "time=%0t: 3rd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", preOpCode=", fshow(preOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule checkRNR if (
        cntrl.isNonErr                     &&
        retryFlushStateReg == RQ_NOT_RETRY &&
        !isErrFlushStateReg
    );
        let { pktMetaData, reqStatus, preOpCode, reqPktInfo } = rnrCheckQ.first;
        rnrCheckQ.deq;

        let bth        = reqPktInfo.bth;
        let epoch      = reqPktInfo.epoch;
        let hasReth    = rdmaReqHasRETH(bth.opcode);
        let rdmaHeader = pktMetaData.pktHeader;
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        let isZeroPayloadLen = reqPktInfo.isZeroPayloadLen;
        let isSendReq        = reqPktInfo.isSendReq;
        let isReadReq        = reqPktInfo.isReadReq;
        let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        let isAtomicReq      = reqPktInfo.isAtomicReq;

        let curPermCheckInfo = cntrl.contextRQ.getPermCheckInfo;
        if (epoch == cntrl.contextRQ.getEpoch) begin
            // Duplicate requests no use PermCheckInfo
            if (reqStatus == RDMA_REQ_ST_NORMAL && !isErrFlushStateReg) begin
                // For write/read/atomic requests
                case ({ pack(hasReth), pack(isAtomicReq) })
                    2'b10: begin
                        curPermCheckInfo.wrID          = tagged Invalid;
                        curPermCheckInfo.rkey          = reth.rkey;
                        curPermCheckInfo.lkey          = dontCareValue;
                        curPermCheckInfo.laddr         = reth.va;
                        curPermCheckInfo.totalLen      = reth.dlen;
                        curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckInfo.isZeroDmaLen  = isZero(reth.dlen);
                        curPermCheckInfo.accType       = isReadReq ? IBV_ACCESS_REMOTE_READ : IBV_ACCESS_REMOTE_WRITE;
                        curPermCheckInfo.localOrRmtKey = False;
                    end
                    2'b01: begin
                        curPermCheckInfo.wrID          = tagged Invalid;
                        curPermCheckInfo.rkey          = atomicEth.rkey;
                        curPermCheckInfo.lkey          = dontCareValue;
                        curPermCheckInfo.laddr         = atomicEth.va;
                        curPermCheckInfo.totalLen      = fromInteger(valueOf(ATOMIC_WORK_REQ_LEN));
                        curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckInfo.isZeroDmaLen  = False;
                        curPermCheckInfo.accType       = IBV_ACCESS_REMOTE_ATOMIC;
                        curPermCheckInfo.localOrRmtKey = False;
                    end
                    default: begin end
                endcase

                if (isFirstOrOnlyPkt && isSendReq) begin
                    if (recvReqBuf.notEmpty) begin
                        let recvReq = recvReqBuf.first;
                        recvReqBuf.deq;

                        if (isZeroPayloadLen) begin
                            immAssert(
                                isOnlyRdmaOpCode(bth.opcode),
                                "isOnlyRdmaOpCode assertion @ mkReqHandleRQ",
                                $format(
                                    "bth.opcode=", fshow(bth.opcode),
                                    " should be only request packet"
                                )
                            );
                        end

                        curPermCheckInfo.wrID          = tagged Valid recvReq.id;
                        curPermCheckInfo.lkey          = recvReq.lkey;
                        curPermCheckInfo.rkey          = dontCareValue;
                        curPermCheckInfo.laddr         = recvReq.laddr;
                        curPermCheckInfo.totalLen      = isZeroPayloadLen ? 0 : recvReq.len;
                        curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckInfo.isZeroDmaLen  = isZeroPayloadLen;
                        curPermCheckInfo.accType       = IBV_ACCESS_LOCAL_WRITE;
                        curPermCheckInfo.localOrRmtKey = True;
                    end
                    else begin
                        reqStatus = RDMA_REQ_ST_RNR;
                    end
                end
                else if (isWriteImmReq) begin
                    if (recvReqBuf.notEmpty) begin
                        let recvReq = recvReqBuf.first;
                        recvReqBuf.deq;

                        curPermCheckInfo.wrID = tagged Valid recvReq.id;
                    end
                    else begin
                        reqStatus = RDMA_REQ_ST_RNR;
                    end
                end

                cntrl.contextRQ.setPermCheckInfo(curPermCheckInfo);
            end

            // Trigger retry flush
            if (reqStatus == RDMA_REQ_ST_RNR) begin
                cntrl.contextRQ.incEpoch;
                cntrl.contextRQ.restorePreReqOpCode(preOpCode);
                cntrl.contextRQ.restoreEPSN(bth.psn);
                rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(cntrl.getMinRnrTimer));

                retryFlushStateReg <= RQ_RNR_RETRY_FLUSH;
            end
            else if (reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
                cntrl.contextRQ.incEpoch;

                retryFlushStateReg <= RQ_SEQ_RETRY_FLUSH;
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 4th stage, epoch=", $time, fshow(epoch),
                ", cntrl.contextRQ.getEpoch=", fshow(cntrl.contextRQ.getEpoch)
            );
        end

        reqPermQueryQ.enq(tuple4(pktMetaData, reqStatus, curPermCheckInfo, reqPktInfo));
        // $display(
        //     "time=%0t: 4th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule queryPerm4NormalReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let { pktMetaData, reqStatus, permCheckInfo, reqPktInfo } = reqPermQueryQ.first;
        reqPermQueryQ.deq;

        let bth = reqPktInfo.bth;

        let expectPermCheckResp = False;
        if (
            reqPktInfo.isFirstOrOnlyPkt && !isErrFlushStateReg &&
            reqStatus == RDMA_REQ_ST_NORMAL && !permCheckInfo.isZeroDmaLen
        ) begin
            permCheckMR.checkReq(permCheckInfo);
            expectPermCheckResp = True;
        end

        reqPermCheckQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, expectPermCheckResp
        ));
        // $display(
        //     "time=%0t: 5th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule checkPerm4NormalReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, expectPermCheckResp
        } = reqPermCheckQ.first;
        reqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let reth        = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let expectDupReadCheckResp = False;
        if (reqStatus == RDMA_REQ_ST_NORMAL && expectPermCheckResp) begin
            let mrCheckResult <- permCheckMR.checkResp;
            if (mrCheckResult) begin
                if (isReadReq) begin
                    dupReadAtomicCache.insertRead(reth);
                end
                else if (isAtomicReq) begin
                    let isAligned = isAlignedAtomicAddr(atomicEth.va);
                    if (!isAligned) begin
                        reqStatus = getInvReqStatusByTransType(bth.trans);
                    end
                    // $display("time=%0t: atomicEth.va=%h", $time, atomicEth.va);
                end
            end
            else begin
                reqStatus = RDMA_REQ_ST_RMT_ACC;
            end
        end

        dupReadReqPermQueryQ.enq(tuple4(pktMetaData, reqStatus, permCheckInfo, reqPktInfo));
        $display(
            "time=%0t: 6th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule queryPerm4DupReadReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let { pktMetaData, reqStatus, permCheckInfo, reqPktInfo } = dupReadReqPermQueryQ.first;
        dupReadReqPermQueryQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let reth        = extractRETH(rdmaHeader.headerData, bth.trans);
        let isReadReq   = reqPktInfo.isReadReq;
        // let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        // let isAtomicReq = reqPktInfo.isAtomicReq;

        // let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        // let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let expectDupReadCheckResp = False;
        if (
            reqStatus == RDMA_REQ_ST_DUP && isReadReq &&
            reqPktInfo.isFirstOrOnlyPkt && !isErrFlushStateReg
        ) begin
            dupReadAtomicCache.searchReadReq(reth);
            expectDupReadCheckResp = True;
        end

        dupReadReqPermCheckQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, expectDupReadCheckResp
        ));
        $display(
            "time=%0t: 7th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule checkPerm4DupReadReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, expectDupReadCheckResp
        } = dupReadReqPermCheckQ.first;
        dupReadReqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        // let rdmaHeader  = pktMetaData.pktHeader;
        // let reth        = extractRETH(rdmaHeader.headerData, bth.trans);
        // let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        // let isReadReq   = reqPktInfo.isReadReq;
        // let isAtomicReq = reqPktInfo.isAtomicReq;

        let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let dupReadReqStartState = DUP_READ_REQ_START_FROM_FIRST;
        if (reqStatus == RDMA_REQ_ST_DUP && expectDupReadCheckResp) begin
            let searchResult <- dupReadAtomicCache.searchReadResp;
            if (searchResult matches tagged Valid .dupReadReqStart) begin
                dupReadReqStartState = dupReadReqStart;
            end
            else begin
                // Discard duplicate requests with error
                reqStatus = RDMA_REQ_ST_DISCARD;
            end
        end

        reqLenCalcQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState
        ));
        $display(
            "time=%0t: 8th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule calcNormalSendWriteReqDmaLen if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, curPermCheckInfo, reqPktInfo, dupReadReqStartState
        } = reqLenCalcQ.first;
        reqLenCalcQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);

        let isSendReq   = reqPktInfo.isSendReq;
        let isWriteReq  = reqPktInfo.isWriteReq;
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        let isMidPkt   = reqPktInfo.isMidPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        let pktPayloadLen = pktMetaData.pktPayloadLen;

        Length totalDmaWriteLen  = cntrl.contextRQ.getTotalDmaWriteLen;
        let remainingDmaWriteLen = cntrl.contextRQ.getRemainingDmaWriteLen;
        let enoughDmaSpace       = False;
        let isLastPayloadLenZero = False;
        let curDmaWriteAddr      = curPermCheckInfo.laddr;
        let nextDmaWriteAddr     = cntrl.contextRQ.getNextDmaWriteAddr;
        let sendWriteReqPktNum   = cntrl.contextRQ.getSendWriteReqPktNum;
        let oneAsPSN             = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = curPermCheckInfo.totalLen - zeroExtend(pktPayloadLen);
                    totalDmaWriteLen     = zeroExtend(pktPayloadLen);
                    enoughDmaSpace       = lenGtEqPktLen(curPermCheckInfo.totalLen, pktPayloadLen, cntrl.getPMTU);
                    // No need to calculate next DMA write address for only send/write responses
                    // nextDmaWriteAddr     = curPermCheckInfo.laddr;
                    sendWriteReqPktNum   = 1;
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(curPermCheckInfo.totalLen, oneAsPSN, cntrl.getPMTU);
                    totalDmaWriteLen     = lenAddPsnMultiplyPMTU(0, oneAsPSN, cntrl.getPMTU);
                    enoughDmaSpace       = lenGtEqPMTU(curPermCheckInfo.totalLen, cntrl.getPMTU);
                    nextDmaWriteAddr     = addrAddPsnMultiplyPMTU(curPermCheckInfo.laddr, oneAsPSN, cntrl.getPMTU);
                    sendWriteReqPktNum   = 1;
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(cntrl.contextRQ.getRemainingDmaWriteLen, oneAsPSN, cntrl.getPMTU);
                    totalDmaWriteLen     = lenAddPsnMultiplyPMTU(cntrl.contextRQ.getTotalDmaWriteLen, oneAsPSN, cntrl.getPMTU);
                    enoughDmaSpace       = lenGtEqPMTU(cntrl.contextRQ.getRemainingDmaWriteLen, cntrl.getPMTU);
                    curDmaWriteAddr      = cntrl.contextRQ.getNextDmaWriteAddr;
                    nextDmaWriteAddr     = addrAddPsnMultiplyPMTU(cntrl.contextRQ.getNextDmaWriteAddr, oneAsPSN, cntrl.getPMTU);
                    sendWriteReqPktNum   = cntrl.contextRQ.getSendWriteReqPktNum + 1;
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPktLen(cntrl.contextRQ.getRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    totalDmaWriteLen     = lenAddPktLen(cntrl.contextRQ.getTotalDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    enoughDmaSpace       = lenGtEqPktLen(cntrl.contextRQ.getRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    curDmaWriteAddr      = cntrl.contextRQ.getNextDmaWriteAddr;
                    // No need to calculate next DMA write address for last send/write responses
                    // nextDmaWriteAddr  = nextDmaWriteAddrReg + zeroExtend(pktPayloadLen);
                    sendWriteReqPktNum   = cntrl.contextRQ.getSendWriteReqPktNum + 1;
                    isLastPayloadLenZero = reqPktInfo.isZeroPayloadLen;
                end
                default: begin end
            endcase

            if (reqStatus == RDMA_REQ_ST_NORMAL && !isErrFlushStateReg) begin
                cntrl.contextRQ.setRemainingDmaWriteLen(remainingDmaWriteLen);
                cntrl.contextRQ.setTotalDmaWriteLen(totalDmaWriteLen);
                cntrl.contextRQ.setNextDmaWriteAddr(nextDmaWriteAddr);
                cntrl.contextRQ.setSendWriteReqPktNum(sendWriteReqPktNum);

                // $display(
                //     "time=%0t: remainingDmaWriteLen=%h, totalDmaWriteLen=%h, nextDmaWriteAddr=%h, sendWriteReqPktNum=%0d, enoughDmaSpace=",
                //     $time, remainingDmaWriteLen, totalDmaWriteLen, nextDmaWriteAddr, sendWriteReqPktNum, fshow(enoughDmaSpace)
                // );

                let noRemainingDmaWrite = isZero(remainingDmaWriteLen);
                let writeReqLenMatch = (isWriteReq && (isLastPkt || isOnlyPkt)) ?
                    noRemainingDmaWrite : True;
                if (!enoughDmaSpace || !writeReqLenMatch || isLastPayloadLenZero) begin
                    // Write request length not match RETH length,
                    // or RecvReq has not enough space,
                    // or last packet has no payload
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                end
                else if (isSendReq && (isLastPkt || isOnlyPkt)) begin
                    // Update send request total length
                    curPermCheckInfo.totalLen = totalDmaWriteLen;
                end
            end
        end

        initDmaReqQ.enq(tuple6(
            pktMetaData, reqStatus, curPermCheckInfo,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 9th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule initDmaReqOrDiscard if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        } = initDmaReqQ.first;
        initDmaReqQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isSendReq   = reqPktInfo.isSendReq;
        let isWriteReq  = reqPktInfo.isWriteReq;
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let isZeroDmaLen = permCheckInfo.isZeroDmaLen;

        let expectReadRespPayload    = False;
        let expectAtomicRespOrig     = False;
        // let expectDupAtomicCheckResp = False;
        if (!isErrFlushStateReg) begin
            case ({ pack(isSendReq), pack(isWriteReq), pack(isReadReq), pack(isAtomicReq) })
                4'b1000, 4'b0100: begin // Send/Write requests
                    if (reqStatus == RDMA_REQ_ST_NORMAL && !isZeroDmaLen) begin
                        let payloadConReq = PayloadConReq {
                            initiator    : OP_INIT_RQ_WR,
                            fragNum      : pktMetaData.pktFragNum,
                            consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                                sqpn     : cntrl.getSQPN,
                                startAddr: curDmaWriteAddr,
                                len      : pktMetaData.pktPayloadLen,
                                psn      : bth.psn
                            }
                        };
                        payloadConReqOutQ.enq(payloadConReq);
                    end
                end
                4'b0010: begin // Read requests
                    if (
                        !isZeroDmaLen                    &&
                        (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
                    ) begin
                        let payloadGenReq = PayloadGenReq {
                            initiator    : OP_INIT_RQ_RD,
                            addPadding   : True,
                            segment      : True,
                            pmtu         : cntrl.getPMTU,
                            dmaReadReq   : DmaReadReq {
                                sqpn     : cntrl.getSQPN,
                                startAddr: reth.va,
                                len      : reth.dlen,
                                wrID     : dontCareValue
                            }
                        };
                        payloadGenReqOutQ.enq(payloadGenReq);
                        expectReadRespPayload = True;
                    end
                end
                4'b0001: begin // Atomic requests
                    if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                        let atomicOpReq = AtomicOpReq {
                            initiator    : OP_INIT_RQ_ATOMIC,
                            casOrFetchAdd: bth.opcode == COMPARE_SWAP,
                            startAddr    : atomicEth.va,
                            compData     : atomicEth.comp,
                            swapData     : atomicEth.swap,
                            sqpn         : cntrl.getSQPN,
                            psn          : bth.psn
                        };
                        atomicOpReqQ.enq(atomicOpReq);
                        expectAtomicRespOrig = True;
                    end
                    // else if (reqStatus == RDMA_REQ_ST_DUP) begin
                    //     dupReadAtomicCache.searchAtomicReq(bth.opcode, atomicEth);
                    //     expectDupAtomicCheckResp = True;
                    // end
                end
                default: begin end
            endcase
        end

        // Set internal error state if any,
        // and no more DMA requests after first error.
        if (isErrReqStatus(reqStatus) && !isErrFlushStateReg) begin
            isErrFlushStateReg <= True;
        end
        if (reqStatus != RDMA_REQ_ST_NORMAL || isErrFlushStateReg) begin
            // Discard request payload if error or flushing
            discardPktPayload(pktMetaData.pktFragNum);
        end

        let respPktGenInfo = RespPktGenInfo {
            shouldGenResp           : False,
            expectReadRespPayload   : expectReadRespPayload,
            expectAtomicRespOrig    : expectAtomicRespOrig,
            expectDupAtomicCheckResp: False,
            atomicAckOrig           : tagged Invalid,
            dupReadReqStartState    : dupReadReqStartState
        };
        respGenCheckQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 10th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule checkShouldGenRespAndWaitAtomicResp if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
            // dupReadReqStartState, expectReadRespPayload,
            // expectAtomicRespOrig, expectDupAtomicCheckResp
        } = respGenCheckQ.first;
        respGenCheckQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isSendReq   = reqPktInfo.isSendReq;
        let isWriteReq  = reqPktInfo.isWriteReq;
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let isLastOrOnlyPkt = reqPktInfo.isLastOrOnlyPkt;

        let shouldGenResp = False;
        let shouldDiscard = False;
        let qpHasResp     = qpNeedGenResp(bth.trans);
        let atomicAckOrig = tagged Invalid;

        let reloadMaxUnackedWorkReqCnt = False;
        let decrMaxUnackedWorkReqCnt = False;
        let shouldGenRespEvenNoAckReq = isLastOrOnlyPkt && isZero(maxUnackedWorkReqCnt);
        case (reqStatus)
            RDMA_REQ_ST_NORMAL: begin
                case ({ pack(isSendReq), pack(isWriteReq), pack(isReadReq), pack(isAtomicReq) })
                    4'b1000, 4'b0100: begin // Send/Write requests
                        if (bth.ackReq || shouldGenRespEvenNoAckReq) begin
                            shouldGenResp = qpHasResp;
                            reloadMaxUnackedWorkReqCnt = True;
                        end
                        else begin
                            decrMaxUnackedWorkReqCnt = isLastOrOnlyPkt;
                        end
                    end
                    4'b0010: begin // Read requests
                        shouldGenResp = qpHasResp;
                        reloadMaxUnackedWorkReqCnt = True;
                    end
                    4'b0001: begin // Atomic requests
                        if (respPktGenInfo.expectAtomicRespOrig) begin
                            let atomicOpResp = atomicOpRespPipeIn.first;
                            atomicOpRespPipeIn.deq;

                            let atomicCache = AtomicCache {
                                atomicOpCode: bth.opcode,
                                atomicEth   : atomicEth,
                                atomicAckEth: AtomicAckEth { orig: atomicOpResp.original }
                            };
                            dupReadAtomicCache.insertAtomic(atomicCache);

                            atomicAckOrig = tagged Valid atomicOpResp.original;
                            shouldGenResp = qpHasResp;
                            reloadMaxUnackedWorkReqCnt = True;
                        end
                    end
                endcase
            end
            RDMA_REQ_ST_DUP: begin
                case ({ pack(isSendReq), pack(isWriteReq), pack(isReadReq), pack(isAtomicReq) })
                    4'b1000, 4'b0100: begin // Duplicate send/Write requests
                        if (bth.ackReq || isLastOrOnlyPkt) begin
                            // Must generate responses for duplicate send/write requests
                            // when last or only packets
                            shouldGenResp = qpHasResp;
                        end
                    end
                    4'b0010: begin // Duplicate read requests
                        shouldGenResp = qpHasResp;
                    end
                    4'b0001: begin // Duplicate atomic requests
                        // Duplicate atomic requests will be checked in later stages
                        // if (expectDupAtomicCheckResp) begin
                        //     let searchResult <- dupReadAtomicCache.searchAtomicResp;
                        //     if (searchResult matches tagged Valid .atomicCache) begin
                        //         atomicAckOrig = tagged Valid atomicCache.atomicAckEth.orig;
                        //         shouldGenResp = qpHasResp;
                        //     end
                        // end
                    end
                endcase
            end
            RDMA_REQ_ST_SEQ_ERR,
            RDMA_REQ_ST_RNR    ,
            RDMA_REQ_ST_INV_REQ,
            RDMA_REQ_ST_INV_RD ,
            RDMA_REQ_ST_RMT_ACC,
            RDMA_REQ_ST_RMT_OP : begin
                shouldGenResp = qpHasResp;
            end
            RDMA_REQ_ST_DISCARD     ,
            RDMA_REQ_ST_ERR_FLUSH_RR: begin
                shouldDiscard = True;
            end
            default: begin end
        endcase

        if (!isErrFlushStateReg && qpHasResp) begin
            // The counter will record how many normal send/write requests
            // without AckReq, and if more than MAX_QP_WR consecutive send/write requests
            // without AckReq, enforce a response to avoid SQ deadlock.
            if (reloadMaxUnackedWorkReqCnt) begin
                maxUnackedWorkReqCnt <= fromInteger(valueOf(TSub#(MAX_QP_WR, 1)));
            end
            else if (decrMaxUnackedWorkReqCnt) begin
                maxUnackedWorkReqCnt.decr(1);
            end
        end
        // $display(
        //     "time=%0t: maxUnackedWorkReqCnt=%0d", $time, maxUnackedWorkReqCnt,
        //     ", reloadMaxUnackedWorkReqCnt=", fshow(reloadMaxUnackedWorkReqCnt),
        //     ", decrMaxUnackedWorkReqCnt=", fshow(decrMaxUnackedWorkReqCnt)
        // );

        // Even no response generated for some requests,
        // they might need to wait for DMA write responses,
        // so still need send to next stage
        respPktGenInfo.shouldGenResp = shouldGenResp;
        respPktGenInfo.atomicAckOrig = atomicAckOrig;
        // let respPktGenInfo = RespPktGenInfo {
        //     expectReadRespPayload   : expectReadRespPayload,
        //     expectAtomicRespOrig    : expectAtomicRespOrig,
        //     expectDupAtomicCheckResp: False,
        //     dupReadReqStartState    : dupReadReqStartState
        // };
        dupAtomicReqPermQueryQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        $display(
            "time=%0t: 11th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            ", shouldDiscard=", fshow(shouldDiscard),
            ", shouldGenResp=", fshow(shouldGenResp),
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule queryPerm4DupAtomicReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = dupAtomicReqPermQueryQ.first;
        dupAtomicReqPermQueryQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        // let reth        = extractRETH(rdmaHeader.headerData, bth.trans);
        // let isReadReq   = reqPktInfo.isReadReq;
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        let isAtomicReq = reqPktInfo.isAtomicReq;
        // let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        // let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let expectDupAtomicCheckResp = False;
        if (
            reqStatus == RDMA_REQ_ST_DUP && isAtomicReq && !isErrFlushStateReg
        ) begin
            dupReadAtomicCache.searchAtomicReq(bth.opcode, atomicEth);
            expectDupAtomicCheckResp = True;
        end

        respPktGenInfo.expectDupAtomicCheckResp = expectDupAtomicCheckResp;
        dupAtomicReqPermCheckQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        $display(
            "time=%0t: 12th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule checkPerm4DupAtomicReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = dupAtomicReqPermCheckQ.first;
        dupAtomicReqPermCheckQ.deq;

        let bth = reqPktInfo.bth;
        // let rdmaHeader  = pktMetaData.pktHeader;
        // let reth        = extractRETH(rdmaHeader.headerData, bth.trans);
        // let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        // let isReadReq   = reqPktInfo.isReadReq;
        // let isAtomicReq = reqPktInfo.isAtomicReq;
        // let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        // let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let expectDupAtomicCheckResp = respPktGenInfo.expectDupAtomicCheckResp;
        if (reqStatus == RDMA_REQ_ST_DUP && expectDupAtomicCheckResp) begin
            let searchResult <- dupReadAtomicCache.searchAtomicResp;
            if (searchResult matches tagged Valid .atomicCache) begin
                respPktGenInfo.atomicAckOrig = tagged Valid atomicCache.atomicAckEth.orig;
                respPktGenInfo.shouldGenResp = qpNeedGenResp(bth.trans);
            end
            else begin
                // Discard duplicate requests with error
                reqStatus = RDMA_REQ_ST_DISCARD;
            end
        end

        pendingRespQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        $display(
            "time=%0t: 13th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule genFirstOrOnlyResp if (cntrl.isNonErr && !isGenMultiPktRespReg); // This rule still runs at retry or error state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = pendingRespQ.first;

        let bth           = reqPktInfo.bth;
        let isReadReq     = isReadReqRdmaOpCode(bth.opcode);
        let isAtomicReq   = isAtomicReqRdmaOpCode(bth.opcode);
        let totalPktNum   = reqPktInfo.respPktNum;
        let isOnlyRespPkt = reqPktInfo.isOnlyRespPkt;

        let errReqStatus = isErrReqStatus(reqStatus);
        if (errReqStatus && !isErrRespGenReg) begin
            isErrRespGenReg <= True;
            // $display("time=%0t: first fatal error response, reqStatus=", $time, fshow(reqStatus));
        end
        workCompReqQ.enq(tuple4(pktMetaData, reqStatus, permCheckInfo, reqPktInfo));

        if (isErrRespGenReg || errReqStatus) begin
            immAssert(
                !respPktGenInfo.expectReadRespPayload &&
                !respPktGenInfo.expectAtomicRespOrig  &&
                !respPktGenInfo.expectDupAtomicCheckResp,
                "respPktGenInfo assertion @ mkReqHandleRQ",
                $format(
                    "expectReadRespPayload=", fshow(respPktGenInfo.expectReadRespPayload),
                    ", expectAtomicRespOrig=", fshow(respPktGenInfo.expectAtomicRespOrig),
                    ", expectDupAtomicCheckResp=", fshow(respPktGenInfo.expectDupAtomicCheckResp),
                    ", all should be false when errReqStatus=", fshow(errReqStatus),
                    " and isErrRespGenReg=", fshow(isErrRespGenReg)
                )
            );
        end

        if (isErrRespGenReg) begin
            // No responses after error response
            pendingRespQ.deq;
        end
        else begin
            if (
                respPktGenInfo.dupReadReqStartState == DUP_READ_REQ_START_FROM_MIDDLE
            ) begin
                immAssert(
                    isReadReq && reqStatus == RDMA_REQ_ST_DUP,
                    "isReadReq and reqStatus assertion @ mkReqHandleRQ",
                    $format(
                        "isReadReq=", fshow(isReadReq),
                        " and reqStatus=", fshow(reqStatus),
                        " should match duplicate read requests"
                    )
                );
                cntrl.contextRQ.setCurRespPsn(bth.psn);
                cntrl.contextRQ.setRespPktNum(totalPktNum - 1);
                isGenMultiPktRespReg <= True;
            end
            else begin
                if (isOnlyRespPkt) begin
                    pendingRespQ.deq;
                end
                else begin
                    cntrl.contextRQ.setCurRespPsn(bth.psn + 1);
                    // Current cycle output first/only packet,
                    // so the remaining pktNum = totalPktNum - 2
                    cntrl.contextRQ.setRespPktNum(totalPktNum - 2);
                end

                if (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP) begin
                    isGenMultiPktRespReg <= !isOnlyRespPkt;
                end

                let isLastOrOnlyPkt = isLastOrOnlyRdmaOpCode(bth.opcode);
                let msn = cntrl.contextRQ.getMSN;
                if (reqStatus == RDMA_REQ_ST_NORMAL && isLastOrOnlyPkt) begin
                    msn = msn + 1;
                    cntrl.contextRQ.setMSN(msn);
                end

                let maybeFirstOrOnlyHeader = genFirstOrOnlyRespHeader(
                    bth.opcode, reqStatus, permCheckInfo.totalLen, respPktGenInfo.atomicAckOrig,
                    cntrl, bth.psn, msn, isOnlyRespPkt
                );
                if (respPktGenInfo.shouldGenResp) begin
                    immAssert(
                        isValid(maybeFirstOrOnlyHeader),
                        "maybeFirstOrOnlyHeader assertion @ mkReqHandleRQ",
                        $format(
                            "maybeFirstOrOnlyHeader=", fshow(maybeFirstOrOnlyHeader),
                            " must be valid when shouldGenResp=",
                            fshow(respPktGenInfo.shouldGenResp),
                            ", bth.opcode=", fshow(bth.opcode),
                            ", bth.psn=%h, msn=%h", bth.psn, msn
                        )
                    );

                    if (
                        isAtomicReq &&
                        (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
                    ) begin
                        immAssert(
                            isValid(respPktGenInfo.atomicAckOrig),
                            "atomicAckOrig assertion @ mkReqHandleRQ",
                            $format(
                                "atomicAckOrig=", fshow(respPktGenInfo.atomicAckOrig),
                                " should be valid when isAtomicReq=", fshow(isAtomicReq),
                                ", reqStatus=", fshow(reqStatus),
                                " and shouldGenResp=", fshow(respPktGenInfo.shouldGenResp)
                            )
                        );
                    end

                    if (maybeFirstOrOnlyHeader matches tagged Valid .firstOrOnlyHeader) begin
                        headerQ.enq(firstOrOnlyHeader);
                    end
                end
            end
        end
        $display(
            "time=%0t: 14th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            ", isOnlyRespPkt=", fshow(isOnlyRespPkt),
            ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
            ", isErrRespGenReg=", fshow(isErrRespGenReg),
            ", errReqStatus=", fshow(errReqStatus),
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule genMiddleOrLastResp if (
        cntrl.isNonErr && !isErrFlushStateReg && isGenMultiPktRespReg
    ); // This rule still runs at retry state
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = pendingRespQ.first;

        let bth = reqPktInfo.bth;
        let isLastRespPkt = isZero(cntrl.contextRQ.getRespPktNum);

        immAssert(
            reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP,
            "reqStatus assertion @ mkReqHandleRQ",
            $format(
                "reqStatus=", fshow(reqStatus),
                " must be normal or duplicate when isGenMultiPktRespReg=",
                fshow(isGenMultiPktRespReg)
            )
        );
        immAssert(
            respPktGenInfo.shouldGenResp,
            "shouldGenResp assertion @ mkReqHandleRQ",
            $format(
                "shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
                " must be true when isGenMultiPktRespReg=",
                fshow(isGenMultiPktRespReg)
            )
        );
        immAssert(
            bth.opcode == RDMA_READ_REQUEST,
            "bth.opcode assertion @ mkReqHandleRQ",
            $format(
                "bth.opcode=", fshow(bth.opcode),
                " must be read request when isGenMultiPktRespReg=",
                fshow(isGenMultiPktRespReg)
            )
        );

        let msn = cntrl.contextRQ.getMSN;
        if (isLastRespPkt) begin
            pendingRespQ.deq;
            if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                msn = msn + 1;
                cntrl.contextRQ.setMSN(msn);
            end
        end
        else begin
            cntrl.contextRQ.setCurRespPsn(cntrl.contextRQ.getCurRespPsn + 1);
            cntrl.contextRQ.setRespPktNum(cntrl.contextRQ.getRespPktNum - 1);
        end

        let maybeMiddleOrLastHeader = genMiddleOrLastRespHeader(
            bth.opcode, reqStatus, permCheckInfo.totalLen, cntrl,
            cntrl.contextRQ.getCurRespPsn, msn, isLastRespPkt
        );
        immAssert(
            isValid(maybeMiddleOrLastHeader),
            "maybeMiddleOrLastHeader assertion @ mkReqHandleRQ",
            $format(
                "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                " must be valid"
            )
        );
        let middleOrLastHeader = unwrapMaybe(maybeMiddleOrLastHeader);
        headerQ.enq(middleOrLastHeader);

        isGenMultiPktRespReg <= !isLastRespPkt;
        $display(
            "time=%0t: 15th stage, bth.opcode=", $time, fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            ", curRespPsn=%h", cntrl.contextRQ.getCurRespPsn,
            ", isLastRespPkt=", fshow(isLastRespPkt),
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    rule genWorkCompReq if (cntrl.isNonErr || cntrl.isERR); // This rule still runs at retry or error state
        let { pktMetaData, reqStatus, permCheckInfo, reqPktInfo } = workCompReqQ.first;
        workCompReqQ.deq;

        let rdmaHeader   = pktMetaData.pktHeader;
        let bth          = reqPktInfo.bth;
        let immDt        = extractImmDt(rdmaHeader.headerData, bth.opcode, bth.trans);
        let ieth         = extractIETH(rdmaHeader.headerData, bth.trans);
        let hasImmDt     = rdmaReqHasImmDt(bth.opcode);
        let hasIETH      = rdmaReqHasIETH(bth.opcode);
        let isZeroDmaLen = permCheckInfo.isZeroDmaLen;

        let maybeWorkCompStatus = genWorkCompStatusFromReqStatusRQ(reqStatus);
        if (maybeWorkCompStatus matches tagged Valid .workCompStatus) begin
            let workCompReq = WorkCompGenReqRQ {
                rrID        : permCheckInfo.wrID,
                len         : permCheckInfo.totalLen,
                sqpn        : cntrl.getSQPN,
                reqPSN      : bth.psn,
                isZeroDmaLen: isZeroDmaLen,
                wcStatus    : workCompStatus,
                reqOpCode   : bth.opcode,
                immDt       : hasImmDt ? (tagged Valid immDt.data) : (tagged Invalid),
                rkey2Inv    : hasIETH  ? (tagged Valid ieth.rkey)  : (tagged Invalid)
            };

            // Wait for send/write request DMA write responses and generate WC if needed
            workCompGenReqOutQ.enq(workCompReq);
        end
        // $display(
        //     "time=%0t: 16th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", immDt=%h, ieth=%h", immDt, ieth,
        //     ", hasImmDt=", fshow(hasImmDt),
        //     ", hasIETH=", fshow(hasIETH),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule errFlush if (cntrl.isERR || isErrFlushStateReg);
        supportedReqOpCodeCheckQ.clear;
        reqOpCodeSeqCheckQ.clear;
        rnrCheckQ.clear;

        if (recvReqBuf.notEmpty) begin
            let recvReq = recvReqBuf.first;
            recvReqBuf.deq;

            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen: 0,
                pktFragNum   : 0,
                pktHeader    : dontCareValue,
                pdHandler    : dontCareValue,
                pktValid     : False,
                pktStatus    : PKT_ST_DISCARD
            };
            let reqStatus        = RDMA_REQ_ST_ERR_FLUSH_RR;
            let curPermCheckInfo = PermCheckInfo {
                wrID         : tagged Valid recvReq.id,
                lkey         : recvReq.lkey,
                rkey         : dontCareValue,
                laddr        : recvReq.laddr,
                totalLen     : recvReq.len,
                pdHandler    : dontCareValue,
                isZeroDmaLen : True,
                accType      : IBV_ACCESS_LOCAL_WRITE,
                localOrRmtKey: True
            };

            let maybeTrans  = qpType2TransType(cntrl.getQpType);
            let bth = BTH {
                trans    : unwrapMaybe(maybeTrans),
                opcode   : SEND_LAST,
                solicited: False,
                migReq   : unpack(0),
                padCnt   : 0,
                tver     : unpack(0),
                pkey     : cntrl.getPKEY,
                fecn     : unpack(0),
                becn     : unpack(0),
                resv6    : unpack(0),
                dqpn     : dontCareValue,
                ackReq   : False,
                resv7    : unpack(0),
                psn      : dontCareValue
            };
            let reqPktInfo = RdmaReqPktInfo {
                bth             : dontCareValue,
                epoch           : cntrl.contextRQ.getEpoch,
                respPktNum      : 0,
                isSendReq       : False,
                isWriteReq      : False,
                isWriteImmReq   : False,
                isReadReq       : False,
                isAtomicReq     : False,
                isZeroPayloadLen: True,
                isOnlyPkt       : True,
                isFirstPkt      : False,
                isMidPkt        : False,
                isLastPkt       : False,
                isFirstOrOnlyPkt: True,
                isLastOrOnlyPkt : True,
                isOnlyRespPkt   : True
            };

            reqPermQueryQ.enq(tuple4(
                pktMetaData, reqStatus, curPermCheckInfo, reqPktInfo
            ));
        end
        else if (pktMetaDataPipeIn.notEmpty) begin
            let curPktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            let curRdmaHeader  = curPktMetaData.pktHeader;
            let bth            = extractBTH(curRdmaHeader.headerData);
            let reqStatus      = RDMA_REQ_ST_DISCARD;

            PermCheckInfo curPermCheckInfo = dontCareValue;
            curPermCheckInfo.wrID          = tagged Invalid;

            let isSendReq        = isSendReqRdmaOpCode(bth.opcode);
            let isWriteReq       = isWriteReqRdmaOpCode(bth.opcode);
            let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);
            let isReadReq        = isReadReqRdmaOpCode(bth.opcode);
            let isAtomicReq      = isAtomicReqRdmaOpCode(bth.opcode);
            let isFirstOrOnlyPkt = isFirstOrOnlyRdmaOpCode(bth.opcode);
            let isLastOrOnlyPkt  = isLastOrOnlyRdmaOpCode(bth.opcode);
            let isZeroPayloadLen = isZero(curPktMetaData.pktPayloadLen);

            let isOnlyPkt  = isOnlyRdmaOpCode(bth.opcode);
            let isFirstPkt = isFirstRdmaOpCode(bth.opcode);
            let isMidPkt   = isMiddleRdmaOpCode(bth.opcode);
            let isLastPkt  = isLastRdmaOpCode(bth.opcode);

            let reqPktInfo = RdmaReqPktInfo {
                bth             : bth,
                epoch           : cntrl.contextRQ.getEpoch,
                respPktNum      : 1,
                isSendReq       : isSendReq,
                isWriteReq      : isWriteReq,
                isWriteImmReq   : isWriteImmReq,
                isReadReq       : isReadReq,
                isAtomicReq     : isAtomicReq,
                isZeroPayloadLen: isZeroPayloadLen,
                isOnlyPkt       : isOnlyPkt,
                isFirstPkt      : isFirstPkt,
                isMidPkt        : isMidPkt,
                isLastPkt       : isLastPkt,
                isFirstOrOnlyPkt: isFirstOrOnlyPkt,
                isLastOrOnlyPkt : isLastOrOnlyPkt,
                isOnlyRespPkt   : True
            };

            reqPermQueryQ.enq(tuple4(
                curPktMetaData, reqStatus, curPermCheckInfo, reqPktInfo
            ));
        end
        // $display(
        //     "time=%0t: 1st error flush stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStateChange if (
        cntrl.isNonErr && retryFlushStateReg != RQ_NOT_RETRY && !isErrFlushStateReg
    );
        if (retryFlushStateReg == RQ_RNR_RETRY_FLUSH) begin
            // rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(cntrl.getMinRnrTimer));
            retryFlushStateReg <= RQ_RNR_WAIT;
        end
        else if (retryFlushStateReg == RQ_RNR_WAIT) begin
            if (isZero(rnrWaitCntReg)) begin
                retryFlushStateReg <= RQ_RNR_WAIT_DONE;
            end
            else begin
                rnrWaitCntReg <= rnrWaitCntReg - 1;
            end
        end
        else if (
            retryFlushStateReg == RQ_RNR_WAIT_DONE ||
            retryFlushStateReg == RQ_SEQ_RETRY_FLUSH
        ) begin
            if (retryDoneWire) begin
                retryFlushStateReg <= RQ_NOT_RETRY;
            end
            // $display(
            //     "time=%0t:", $time, " retryDoneWire=", fshow(retryDoneWire)
            // );
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule retryFlush if (
        cntrl.isNonErr && retryFlushStateReg != RQ_NOT_RETRY && !isErrFlushStateReg
    );
        supportedReqOpCodeCheckQ.clear;
        reqOpCodeSeqCheckQ.clear;
        rnrCheckQ.clear;

        if (pktMetaDataPipeIn.notEmpty) begin
            let curPktMetaData = pktMetaDataPipeIn.first;
            let curRdmaHeader  = curPktMetaData.pktHeader;

            let bth       = extractBTH(curRdmaHeader.headerData);
            let psnMatch  = bth.psn == cntrl.contextRQ.getEPSN;
            let retryDone = psnMatch && (
                retryFlushStateReg == RQ_RNR_WAIT_DONE ||
                retryFlushStateReg == RQ_SEQ_RETRY_FLUSH
            );
            retryDoneWire <= retryDone;
            // $display(
            //     "time=%0t:", $time,
            //     " retryDone=", fshow(retryDone),
            //     ", bth.psn=%h", bth.psn,
            //     ", ePSN=%h", cntrl.contextRQ.getEPSN
            // );

            let reqStatus = RDMA_REQ_ST_DISCARD;
            if (!retryDone) begin
                pktMetaDataPipeIn.deq;

                PermCheckInfo curPermCheckInfo = dontCareValue;
                curPermCheckInfo.wrID          = tagged Invalid;

                let isSendReq        = isSendReqRdmaOpCode(bth.opcode);
                let isWriteReq       = isWriteReqRdmaOpCode(bth.opcode);
                let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);
                let isReadReq        = isReadReqRdmaOpCode(bth.opcode);
                let isAtomicReq      = isAtomicReqRdmaOpCode(bth.opcode);
                let isFirstOrOnlyPkt = isFirstOrOnlyRdmaOpCode(bth.opcode);
                let isLastOrOnlyPkt  = isLastOrOnlyRdmaOpCode(bth.opcode);
                let isZeroPayloadLen = isZero(curPktMetaData.pktPayloadLen);

                let isOnlyPkt  = isOnlyRdmaOpCode(bth.opcode);
                let isFirstPkt = isFirstRdmaOpCode(bth.opcode);
                let isMidPkt   = isMiddleRdmaOpCode(bth.opcode);
                let isLastPkt  = isLastRdmaOpCode(bth.opcode);

                let reqPktInfo = RdmaReqPktInfo {
                    bth             : bth,
                    epoch           : cntrl.contextRQ.getEpoch,
                    respPktNum      : 1,
                    isSendReq       : isSendReq,
                    isWriteReq      : isWriteReq,
                    isWriteImmReq   : isWriteImmReq,
                    isReadReq       : isReadReq,
                    isAtomicReq     : isAtomicReq,
                    isZeroPayloadLen: isZeroPayloadLen,
                    isOnlyPkt       : isOnlyPkt,
                    isFirstPkt      : isFirstPkt,
                    isMidPkt        : isMidPkt,
                    isLastPkt       : isLastPkt,
                    isFirstOrOnlyPkt: isFirstOrOnlyPkt,
                    isLastOrOnlyPkt : isLastOrOnlyPkt,
                    isOnlyRespPkt   : True
                };

                reqPermQueryQ.enq(tuple4(
                    curPktMetaData, reqStatus, curPermCheckInfo, reqPktInfo
                ));
            end
            // $display(
            //     "time=%0t: 1st retry flush stage, bth.opcode=", $time, fshow(bth.opcode),
            //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            //     ", reqStatus=", fshow(reqStatus)
            // );
        end
    endrule

    interface payloadConReqPipeOut      = convertFifo2PipeOut(payloadConReqOutQ);
    // interface payloadGenReqPipeOut      = convertFifo2PipeOut(payloadGenReqOutQ);
    interface rdmaRespDataStreamPipeOut = rdmaRespPipeOut;
    interface workCompGenReqPipeOut     = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
