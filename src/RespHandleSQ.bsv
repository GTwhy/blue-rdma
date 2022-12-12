import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Utils :: *;

function Bool rdmaRespMatchWorkReq(RdmaOpCode opcode, WorkReqOpCode wrOpCode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : (wrOpCode == IBV_WR_RDMA_READ);
        ATOMIC_ACKNOWLEDGE       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP || wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);
        ACKNOWLEDGE              : True;
        default                  : False;
    endcase;
endfunction

typedef enum {
    SQ_HANDLE_RESP_HEADER,
    SQ_RETRY_FLUSH,
    SQ_ERROR_FLUSH
    // SQ_RETRY_FLUSH_AND_WAIT
} RespHandleState deriving(Bits, Eq);

typedef enum {
    WR_ACK_EXPLICIT_WHOLE,
    WR_ACK_EXPLICIT_PARTIAL,
    WR_ACK_COALESCE_NORMAL,
    WR_ACK_COALESCE_RETRY,
    WR_ACK_DUPLICATE,
    WR_ACK_GHOST,
    WR_ACK_ILLEGAL,
    WR_ACK_FLUSH
} WorkReqAckType deriving(Bits, Eq, FShow);

typedef enum {
    WR_ACT_BAD_RESP,
    WR_ACT_COALESCE_RESP,
    WR_ACT_ERROR_RESP,
    WR_ACT_EXPLICIT_RESP,
    WR_ACT_DISCARD_RESP,
    WR_ACT_DUPLICATE_RESP,
    WR_ACT_GHOST_RESP,
    WR_ACT_ILLEGAL_RESP,
    WR_ACT_FLUSH_RESP,
    WR_ACT_EXPLICIT_RETRY,
    WR_ACT_IMPLICIT_RETRY,
    // WR_ACT_RETRY_EXC,
    WR_ACT_UNKNOWN
} WorkReqAction deriving(Bits, Eq, FShow);

function WorkReqAction pktStatus2WorkReqActionSQ(
    PktVeriStatus pktStatus
);
    return case (pktStatus)
        PKT_ST_VALID  : WR_ACT_EXPLICIT_RESP;
        PKT_ST_LEN_ERR: WR_ACT_ILLEGAL_RESP;
        PKT_ST_DISCARD: WR_ACT_DISCARD_RESP;
        default       : WR_ACT_UNKNOWN;
    endcase;
endfunction

typedef struct {
    Bool genWorkComp;
    Bool shouldDiscard;
    Bool enoughDmaSpace;
    Bool readRespLenMatch;
} Bools4WorkCompAndDmaWrite deriving(Bits);

interface RespHandleSQ;
    interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
endinterface

module mkRespHandleSQ#(
    Controller cntrl,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn,
    RetryHandleSQ retryHandler
)(RespHandleSQ);
    FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    FIFOF#(Tuple6#(
        PendingWorkReq, RdmaPktMetaData, RdmaRespType,
        RetryReason, WorkReqAckType, WorkCompReqType
    )) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple5#(
        PendingWorkReq, RdmaPktMetaData, WorkReqAction,
        Maybe#(WorkCompStatus), WorkCompReqType
    )) pendingLenCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(
        PendingWorkReq, RdmaPktMetaData, Maybe#(WorkCompStatus),
        WorkCompReqType, PktLen, ADDR, Bools4WorkCompAndDmaWrite
    )) pendingDmaReqQ <- mkFIFOF;

    Reg#(Length)     remainingReadRespLenReg <- mkRegU;
    Reg#(ADDR)      nextReadRespWriteAddrReg <- mkRegU;
    Reg#(PktNum)           readRespPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)        preRdmaOpCodeReg <- mkReg(ACKNOWLEDGE);
    Reg#(RespHandleState) respHandleStateReg <- mkReg(SQ_HANDLE_RESP_HEADER);

    // TODO: check discard duplicate or ghost reponses has
    // no response from PayloadConsumer will not incur bugs.
    function Action discardPayload(PmtuFragNum fragNum);
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

    // Response handle pipeline first stage
    rule recvRespHeader if (
        cntrl.isRTS                                 &&
        respHandleStateReg == SQ_HANDLE_RESP_HEADER &&
        pendingWorkReqPipeIn.notEmpty
    ); // This rule will not run at retry or error state
        let curPktMetaData = pktMetaDataPipeIn.first;
        let curPendingWR   = pendingWorkReqPipeIn.first;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        // No need to change to SQ_RETRY_FLUSH state if timeout retry,
        // since no responses to flush when timeout.
        retryHandler.resetTimeOutBySQ;

        let bth         = extractBTH(curRdmaHeader.headerData);
        let aeth        = extractAETH(curRdmaHeader.headerData);
        let retryReason = getRetryReasonFromAETH(aeth);
        dynAssert(
            isRdmaRespOpCode(bth.opcode),
            "isRdmaRespOpCode assertion @ mkRespHandleSQ",
            $format(
                "bth.opcode=", fshow(bth.opcode), " should be RDMA response"
            )
        );
        // $display(
        //     "time=%0d: curPendingWR=", $time, fshow(curPendingWR),
        //     ", curPktMetaData=", fshow(curPktMetaData),
        //     ", bth=", fshow(bth)
        // );

        PSN nextPSN   = cntrl.getNPSN;
        PSN startPSN  = unwrapMaybe(curPendingWR.startPSN);
        PSN endPSN    = unwrapMaybe(curPendingWR.endPSN);
        PktNum pktNum = unwrapMaybe(curPendingWR.pktNum);
        dynAssert(
            isValid(curPendingWR.startPSN) &&
            isValid(curPendingWR.endPSN) &&
            isValid(curPendingWR.pktNum) &&
            isValid(curPendingWR.isOnlyReqPkt),
            "curPendingWR assertion @ mkRespHandleSQ",
            $format(
                "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                fshow(curPendingWR)
            )
        );

        let rdmaRespType = getRdmaRespType(bth.opcode, aeth);
        dynAssert(
            rdmaRespType != RDMA_RESP_UNKNOWN,
            "rdmaRespType assertion @ handleRetryResp() in mkRespHandleSQ",
            $format("rdmaRespType=", fshow(rdmaRespType), " should not be unknown")
        );

        // This stage needs to do:
        // - dequeue pending WR when normal response;
        // - change to flush state if retry or error response
        let shouldDeqPktMetaData = True;
        let deqPendingWorkReq = False;
        let wrAckType = WR_ACK_FLUSH;
        let wcReqType = WC_REQ_TYPE_UNKNOWN;

        let isIllegalResp   = !curPktMetaData.pktValid;
        let isMatchEndPSN   = bth.psn == endPSN;
        let isCoalesceResp  = psnInRangeExclusive(bth.psn, endPSN, nextPSN);
        let isMatchStartPSN = bth.psn == startPSN;
        let isPartialResp   = psnInRangeExclusive(bth.psn, startPSN, endPSN);
        // $display(
        //     "time=%0d: bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", curPendingWR=", fshow(curPendingWR),
        //     ", isGhostResp=", fshow(isGhostResp),
        //     ", isIllegalResp=", fshow(isIllegalResp),
        //     ", isMatchEndPSN=", fshow(isMatchEndPSN),
        //     ", isCoalesceResp=", fshow(isCoalesceResp),
        //     ", isMatchStartPSN=", fshow(isMatchStartPSN),
        //     ", isPartialResp=", fshow(isPartialResp)
        // );

        case ({
            pack(isIllegalResp), pack(isMatchEndPSN), pack(isCoalesceResp),
            pack(isMatchStartPSN), pack(isPartialResp)
        })
            5'b10000: begin
                wrAckType = WR_ACK_ILLEGAL;
                wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
            end
            5'b01000, 5'b01010: begin // Response to whole WR, multi-or-single packets
                wrAckType = WR_ACK_EXPLICIT_WHOLE;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        wcReqType           = WC_REQ_TYPE_NO_WC;
                        respHandleStateReg <= SQ_RETRY_FLUSH;

                        let rnrTimer = (retryReason == RETRY_REASON_RNR) ?
                                (tagged Valid aeth.value) : (tagged Invalid);
                        retryHandler.notifyRetryFromSQ(
                            curPendingWR.wr.id,
                            bth.psn,
                            retryReason,
                            rnrTimer
                        );
                    end
                    RDMA_RESP_ERROR: begin
                        wcReqType           = WC_REQ_TYPE_ERR_FULL_ACK;
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                        deqPendingWorkReq = True;
                    end
                    RDMA_RESP_NORMAL: begin
                        wcReqType = WC_REQ_TYPE_SUC_FULL_ACK;
                        deqPendingWorkReq = True;
                    end
                    default: begin end
                endcase
            end
            5'b00100: begin // Coalesce ACK
                shouldDeqPktMetaData = False;

                if (isReadOrAtomicWorkReq(curPendingWR.wr.opcode)) begin // Implicit retry
                    wrAckType           = WR_ACK_COALESCE_RETRY;
                    wcReqType           = WC_REQ_TYPE_NO_WC;
                    respHandleStateReg <= SQ_RETRY_FLUSH;

                    retryReason = RETRY_REASON_IMPLICIT;
                    let rnrTimer = tagged Invalid;
                    retryHandler.notifyRetryFromSQ(
                        curPendingWR.wr.id,
                        bth.psn,
                        retryReason,
                        rnrTimer
                    );
                end
                else begin
                    wrAckType = WR_ACK_COALESCE_NORMAL;
                    wcReqType = WC_REQ_TYPE_SUC_FULL_ACK;
                    deqPendingWorkReq = True;
                end
            end
            5'b00010, 5'b00001: begin // Partial ACK
                wrAckType = WR_ACK_EXPLICIT_PARTIAL;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        wcReqType           = WC_REQ_TYPE_NO_WC;
                        respHandleStateReg <= SQ_RETRY_FLUSH;

                        let rnrTimer = (retryReason == RETRY_REASON_RNR) ?
                                (tagged Valid aeth.value) : (tagged Invalid);
                        retryHandler.notifyRetryFromSQ(
                            curPendingWR.wr.id,
                            bth.psn,
                            retryReason,
                            rnrTimer
                        );
                    end
                    RDMA_RESP_ERROR: begin
                        // Explicit error responses will dequeue whole WR,
                        // no matter error reponses are full or partial ACK.
                        wcReqType           = WC_REQ_TYPE_ERR_FULL_ACK;
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                        deqPendingWorkReq = True;
                    end
                    RDMA_RESP_NORMAL: begin
                        wcReqType = WC_REQ_TYPE_SUC_PARTIAL_ACK;
                    end
                    default         : begin end
                endcase
            end
            default: begin // Duplicated responses
                wrAckType = WR_ACK_DUPLICATE;
                wcReqType = WC_REQ_TYPE_NO_WC;
            end
        endcase

        if (shouldDeqPktMetaData) begin
            pktMetaDataPipeIn.deq;
        end
        if (deqPendingWorkReq) begin
            pendingWorkReqPipeIn.deq;
            retryHandler.resetRetryCntBySQ;
        end

        if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
            dynAssert(
                deqPendingWorkReq,
                "deqPendingWorkReq assertion @ mkRespHandleSQ",
                $format(
                    "deqPendingWorkReq=", fshow(deqPendingWorkReq),
                    " should be true when bth.opcode=", fshow(bth.opcode),
                    " is last or only response"
                )
            );
        end

        dynAssert(
            wrAckType != WR_ACK_FLUSH && wcReqType != WC_REQ_TYPE_UNKNOWN,
            "wrAckType and wcReqType assertion @ mkRespHandleSQ",
            $format(
                "wrAckType=", fshow(wrAckType),
                ", and wcReqType=", fshow(wcReqType),
                " should not be unknown in rule recvRespHeader"
            )
        );
        pendingRespQ.enq(tuple6(
            curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType, wcReqType
        ));
    endrule

    // Response handle pipeline second stage
    rule handleRespByType if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType, wcReqType
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let curRdmaHeader = curPktMetaData.pktHeader;
        let bth           = extractBTH(curRdmaHeader.headerData);
        let aeth          = extractAETH(curRdmaHeader.headerData);

        let wcStatus = tagged Invalid;
        if (rdmaRespHasAETH(bth.opcode)) begin
            wcStatus = genWorkCompStatusFromAETH(aeth);
            dynAssert(
                isValid(wcStatus),
                "isValid(wcStatus) assertion @ handleRetryResp() in mkRespHandleSQ",
                $format("wcStatus=", fshow(wcStatus), " should be valid")
            );
        end

        Bool isReadWR           = isReadWorkReq(curPendingWR.wr.opcode);
        Bool isAtomicWR         = isAtomicWorkReq(curPendingWR.wr.opcode);
        Bool respOpCodeSeqCheck = rdmaNormalRespOpCodeSeqCheck(preRdmaOpCodeReg, bth.opcode);
        Bool respMatchWorkReq   = rdmaRespMatchWorkReq(bth.opcode, curPendingWR.wr.opcode);

        let hasWorkComp = False;
        let needDmaWrite = False;
        let isFinalRespNormal = False;
        // let shouldDiscardPayload = False;
        let wrAction = WR_ACT_UNKNOWN;
        case (wrAckType)
            WR_ACK_EXPLICIT_WHOLE, WR_ACK_EXPLICIT_PARTIAL: begin
                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        wrAction = WR_ACT_EXPLICIT_RETRY;
                    end
                    RDMA_RESP_ERROR: begin
                        hasWorkComp = True;
                        wrAction = WR_ACT_ERROR_RESP;
                    end
                    RDMA_RESP_NORMAL: begin
                        // Only update pre-opcode when normal response
                        preRdmaOpCodeReg <= bth.opcode;

                        if (!respMatchWorkReq || !respOpCodeSeqCheck) begin
                            hasWorkComp = True;
                            wcStatus = tagged Valid IBV_WC_BAD_RESP_ERR;
                            wrAction = WR_ACT_BAD_RESP;
                            if (wrAckType == WR_ACK_EXPLICIT_PARTIAL) begin
                                wcReqType = WC_REQ_TYPE_ERR_PARTIAL_ACK;
                            end
                            else begin
                                wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
                            end
                        end
                        else begin
                            hasWorkComp  = workReqNeedWorkComp(curPendingWR.wr);
                            needDmaWrite = isReadWR || isAtomicWR;
                            isFinalRespNormal = True;
                            wrAction = WR_ACT_EXPLICIT_RESP;
                        end
                    end
                    default: begin end
                endcase
            end
            WR_ACK_COALESCE_NORMAL: begin
                hasWorkComp = workReqNeedWorkComp(curPendingWR.wr);
                wcStatus = hasWorkComp ? (tagged Valid IBV_WC_SUCCESS) : (tagged Invalid);
                isFinalRespNormal = True;
                wrAction = WR_ACT_COALESCE_RESP;
            end
            WR_ACK_COALESCE_RETRY: begin
                // Discard coalesce responses
                // shouldDiscardPayload = True;
                wrAction = WR_ACT_IMPLICIT_RETRY;
            end
            WR_ACK_DUPLICATE: begin
                // Discard duplicate responses
                // shouldDiscardPayload = True;
                wrAction = WR_ACT_DUPLICATE_RESP;
            end
            WR_ACK_GHOST: begin
                // Discard ghost responses
                // shouldDiscardPayload = True;
                wrAction = WR_ACT_GHOST_RESP;
            end
            WR_ACK_ILLEGAL: begin
                // Discard invalid responses
                // shouldDiscardPayload = True;
                wcStatus = pktStatus2WorkCompStatusSQ(curPktMetaData.pktStatus);
                wrAction = pktStatus2WorkReqActionSQ(curPktMetaData.pktStatus);
            end
            WR_ACK_FLUSH: begin
                // Discard responses when retry or error flush
                // shouldDiscardPayload = True;
                wrAction = WR_ACT_FLUSH_RESP;
            end
            default: begin end
        endcase

        dynAssert(
            wrAction != WR_ACT_UNKNOWN,
            "wrAction assertion @ mkRespHandleSQ",
            $format("wrAction=", fshow(wrAction), " should not be unknown")
        );
        pendingLenCheckQ.enq(tuple5(
            curPendingWR, curPktMetaData, wrAction, wcStatus, wcReqType
        ));
    endrule

    // Response handle pipeline third stage
    rule checkReadRespLen if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, wrAction, wcStatus, wcReqType
        } = pendingLenCheckQ.first;
        pendingLenCheckQ.deq;

        let rdmaHeader       = pktMetaData.pktHeader;
        let bth              = extractBTH(rdmaHeader.headerData);
        // let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let pktPayloadLen    = pktMetaData.pktPayloadLen - zeroExtend(bth.padCnt);
        let isReadWR         = isReadWorkReq(pendingWR.wr.opcode);
        // let isZeroWorkReqLen = isZero(pendingWR.wr.len);
        // let isAtomicWR       = isAtomicWorkReq(pendingWR.wr.opcode);
        let isFirstPkt       = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt         = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt        = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt        = isOnlyRdmaOpCode(bth.opcode);
        let needWorkComp     = workReqNeedWorkComp(pendingWR.wr);

        let genWorkComp   = False;
        let shouldDiscard = False;

        let enoughDmaSpace        = True;
        let readRespLenMatch      = True;
        let remainingReadRespLen  = remainingReadRespLenReg;
        let nextReadRespWriteAddr = nextReadRespWriteAddrReg;
        let readRespPktNum        = readRespPktNumReg;
        let oneAsPSN              = 1;
        case (wrAction)
            WR_ACT_BAD_RESP: begin
                genWorkComp = True;
                shouldDiscard = True;
                // discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_ERROR_RESP: begin
                genWorkComp = True;
            end
            WR_ACT_EXPLICIT_RESP: begin
                // No WC for the first and middle read response
                genWorkComp = needWorkComp && !(isFirstPkt || isMidPkt);

                if (isReadWR) begin
                    case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                        4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = pendingWR.wr.len - zeroExtend(pktPayloadLen);
                            enoughDmaSpace        = lenGtEqPktLen(pendingWR.wr.len, pktPayloadLen, cntrl.getPMTU);
                            nextReadRespWriteAddr = pendingWR.wr.laddr;
                            readRespPktNum        = 1;
                        end
                        4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = lenSubtractPsnMultiplyPMTU(pendingWR.wr.len, oneAsPSN, cntrl.getPMTU);
                            enoughDmaSpace        = lenGtEqPMTU(pendingWR.wr.len, cntrl.getPMTU);
                            nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(pendingWR.wr.laddr, oneAsPSN, cntrl.getPMTU);
                            readRespPktNum        = readRespPktNumReg + 1;
                        end
                        4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = lenSubtractPsnMultiplyPMTU(remainingReadRespLenReg, oneAsPSN, cntrl.getPMTU);
                            enoughDmaSpace        = lenGtEqPMTU(remainingReadRespLenReg, cntrl.getPMTU);
                            nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(nextReadRespWriteAddrReg, oneAsPSN, cntrl.getPMTU);
                            readRespPktNum        = readRespPktNumReg + 1;
                        end
                        4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = lenSubtractPktLen(remainingReadRespLenReg, pktPayloadLen, cntrl.getPMTU);
                            enoughDmaSpace        = lenGtEqPktLen(remainingReadRespLenReg, pktPayloadLen, cntrl.getPMTU);
                            // No need to calculate next DMA write address for last read responses
                            // nextReadRespWriteAddr = nextReadRespWriteAddrReg + zeroExtend(pktPayloadLen);
                            readRespPktNum        = readRespPktNumReg + 1;
                        end
                        default: begin end
                    endcase
                    remainingReadRespLenReg  <= remainingReadRespLen;
                    nextReadRespWriteAddrReg <= nextReadRespWriteAddr;
                    readRespPktNumReg        <= readRespPktNum;
                    // $display(
                    //     "time=%0d: bth.opcode=", $time, fshow(bth.opcode),
                    //     ", remainingReadRespLen=%h", remainingReadRespLen,
                    //     ", nextReadRespWriteAddr=%h", nextReadRespWriteAddr,
                    //     ", readRespPktNum=%0d", readRespPktNum
                    // );

                    readRespLenMatch = (isLastPkt || isOnlyPkt) ? isZero(remainingReadRespLen) : True;
                end
            end
            WR_ACT_COALESCE_RESP: begin
                genWorkComp = needWorkComp;
            end
            WR_ACT_DUPLICATE_RESP: begin
                shouldDiscard = True;
                // discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_GHOST_RESP: begin
                shouldDiscard = True;
                // discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_ILLEGAL_RESP: begin
                genWorkComp   = True;
                shouldDiscard = True;
                // discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_DISCARD_RESP, WR_ACT_FLUSH_RESP: begin
                shouldDiscard = True;
                // discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_EXPLICIT_RETRY, WR_ACT_IMPLICIT_RETRY: begin
                Bool isRetryErr  = retryHandler.hasRetryErr;
                if (isRetryErr) begin
                    genWorkComp = True;
                    wcStatus    = tagged Valid IBV_WC_RETRY_EXC_ERR;
                    wcReqType   = WC_REQ_TYPE_ERR_PARTIAL_ACK;
                end
            end
            // WR_ACT_RETRY_EXC: begin
            //     genWorkComp = True;
            // end
            default: begin end
        endcase

        let bools4WorkCompAndDmaWrite = Bools4WorkCompAndDmaWrite {
            genWorkComp     : genWorkComp,
            shouldDiscard   : shouldDiscard,
            enoughDmaSpace  : enoughDmaSpace,
            readRespLenMatch: readRespLenMatch
        };
        pendingDmaReqQ.enq(tuple7(
            pendingWR, pktMetaData, wcStatus, wcReqType, pktPayloadLen,
            nextReadRespWriteAddr, bools4WorkCompAndDmaWrite
        ));
    endrule

    // Response handle pipeline fourth stage
    rule genWorkCompAndInitDma if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, wcStatus, wcReqType, pktPayloadLen,
            nextReadRespWriteAddr, bools4WorkCompAndDmaWrite
        } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        let genWorkComp      = bools4WorkCompAndDmaWrite.genWorkComp;
        let shouldDiscard    = bools4WorkCompAndDmaWrite.shouldDiscard;
        let enoughDmaSpace   = bools4WorkCompAndDmaWrite.enoughDmaSpace;
        let readRespLenMatch = bools4WorkCompAndDmaWrite.readRespLenMatch;
        let rdmaHeader       = pktMetaData.pktHeader;
        let bth              = extractBTH(rdmaHeader.headerData);
        let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let isReadWR         = isReadWorkReq(pendingWR.wr.opcode);
        let isZeroWorkReqLen = isZero(pendingWR.wr.len);
        let isAtomicWR       = isAtomicWorkReq(pendingWR.wr.opcode);

        let wcWaitDmaResp = False;
        if (shouldDiscard) begin
            discardPayload(pktMetaData.pktFragNum);
        end
        else if (isReadWR) begin
            if (!enoughDmaSpace || !readRespLenMatch) begin
                // Read response length not match WR length
                discardPayload(pktMetaData.pktFragNum);
                wcStatus  = tagged Valid IBV_WC_LOC_LEN_ERR;
                wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
            end
            else if (!isZeroWorkReqLen) begin
                let payloadConReq = PayloadConReq {
                    initiator    : OP_INIT_SQ_WR,
                    fragNum      : pktMetaData.pktFragNum,
                    consumeInfo  : tagged ReadRespInfo DmaWriteMetaData {
                        sqpn     : cntrl.getSQPN,
                        startAddr: nextReadRespWriteAddr,
                        len      : pktPayloadLen,
                        psn      : bth.psn
                    }
                };
                payloadConReqOutQ.enq(payloadConReq);
                wcWaitDmaResp = True;
            end
        end
        else if (isAtomicWR) begin
            // let initiator = isAtomicWR ? OP_INIT_SQ_ATOMIC : OP_INIT_SQ_WR;
            let atomicWriteReq = PayloadConReq {
                initiator  : OP_INIT_SQ_ATOMIC,
                fragNum    : 0,
                consumeInfo: tagged AtomicRespInfoAndPayload tuple2(
                    DmaWriteMetaData {
                        sqpn     : cntrl.getSQPN,
                        startAddr: pendingWR.wr.laddr,
                        len      : truncate(pendingWR.wr.len),
                        psn      : bth.psn
                    },
                    atomicAckAeth.orig
                )
            };
            payloadConReqOutQ.enq(atomicWriteReq);
            wcWaitDmaResp = True;
        end

        if (genWorkComp || wcWaitDmaResp) begin
            dynAssert(
                !genWorkComp || isValid(wcStatus),
                "genWorkComp -> isValid(wcStatus) assertion @ mkRespHandleSQ",
                $format(
                    "wcStatus=", fshow(wcStatus),
                    " should be valid when genWorkComp=", fshow(genWorkComp)
                )
            );
            let wcGenReq = WorkCompGenReqSQ {
                pendingWR    : pendingWR,
                wcWaitDmaResp: wcWaitDmaResp,
                wcReqType    : wcReqType,
                triggerPSN   : bth.psn,
                wcStatus     : unwrapMaybeWithDefault(wcStatus, IBV_WC_SUCCESS)
            };
            workCompGenReqOutQ.enq(wcGenReq);
            // $display(
            //     "time=%0d: wcGenReq=", $time, fshow(wcGenReq),
            //     ", wcStatus=", fshow(wcStatus)
            // );
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule flushPktMetaDataAndPayload if (
        cntrl.isERR                          ||
        respHandleStateReg == SQ_ERROR_FLUSH || // Error flush
        respHandleStateReg == SQ_RETRY_FLUSH || // Retry flush
        !pendingWorkReqPipeIn.notEmpty          // Ghost responses
    );
        if (pktMetaDataPipeIn.notEmpty) begin
            let pktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            PendingWorkReq emptyPendingWR = dontCareValue;
            let rdmaRespType = RDMA_RESP_UNKNOWN;
            let retryReason = RETRY_REASON_NOT_RETRY;
            let wrAckType = pendingWorkReqPipeIn.notEmpty ?
                WR_ACK_FLUSH : WR_ACK_GHOST;
            let wcReqType = WC_REQ_TYPE_NO_WC;
            pendingRespQ.enq(tuple6(
                emptyPendingWR, pktMetaData, rdmaRespType,
                retryReason, wrAckType, wcReqType
            ));
        end

        if (cntrl.isRTS && respHandleStateReg == SQ_RETRY_FLUSH) begin
            // Retry WR begin, change state to normal handling
            if (retryHandler.retryBegin) begin
                respHandleStateReg <= SQ_HANDLE_RESP_HEADER;
            end
        end
    endrule

    interface payloadConReqPipeOut = convertFifo2PipeOut(payloadConReqOutQ);
    interface workCompGenReqPipeOut = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
