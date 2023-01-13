import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
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
    // WR_ACK_RETRY_FLUSH,
    WR_ACK_DISCARD,
    WR_ACK_ERR_FLUSH_WR,
    WR_ACK_UNKNOWN
} WorkReqAckType deriving(Bits, Eq, FShow);

typedef enum {
    SQ_ACT_BAD_RESP,
    SQ_ACT_COALESCE_RESP,
    SQ_ACT_ERROR_RESP,
    SQ_ACT_EXPLICIT_RESP,
    SQ_ACT_DISCARD_RESP,
    SQ_ACT_DUPLICATE_RESP,
    // SQ_ACT_GHOST_RESP,
    SQ_ACT_ILLEGAL_RESP,
    SQ_ACT_FLUSH_WR,
    SQ_ACT_EXPLICIT_RETRY,
    SQ_ACT_IMPLICIT_RETRY,
    SQ_ACT_LOCAL_ACC_ERR,
    SQ_ACT_LOCAL_LEN_ERR,
    // SQ_ACT_RETRY_EXC,
    SQ_ACT_UNKNOWN
} RespActionSQ deriving(Bits, Eq, FShow);

function RespActionSQ pktStatus2RespActionSQ(
    PktVeriStatus pktStatus
);
    return case (pktStatus)
        PKT_ST_VALID  : SQ_ACT_EXPLICIT_RESP;
        PKT_ST_LEN_ERR: SQ_ACT_ILLEGAL_RESP;
        PKT_ST_DISCARD: SQ_ACT_DISCARD_RESP;
        default       : SQ_ACT_UNKNOWN;
    endcase;
endfunction

typedef struct {
    BTH bth;
    AETH aeth;
    Bool isZeroPayloadLen;
    Bool isFirstOrOnlyPkt;
    Bool isLastOrOnlyPkt;
    Bool isReadResp;
    Bool isAtomicResp;
    Bool hasLocalErr;
    Bool shouldDiscard;
    Bool genWorkComp;
} RespPktInfo deriving(Bits);

interface RespHandleSQ;
    interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
endinterface

module mkRespHandleSQ#(
    Controller cntrl,
    RetryHandleSQ retryHandler,
    PermCheckMR permCheckMR,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn
)(RespHandleSQ);
    FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    FIFOF#(Tuple7#(
        PendingWorkReq, RdmaPktMetaData, RespPktInfo, RdmaRespType,
        RetryReason, WorkReqAckType, WorkCompReqType
    )) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple5#(
        PendingWorkReq, RdmaPktMetaData, RespPktInfo,
        RespActionSQ, WorkCompReqType
    )) pendingPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(
        PendingWorkReq, RdmaPktMetaData, RespPktInfo,
        RespActionSQ, WorkCompReqType, Bool
    )) pendingPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple6#(
        PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ,
        Maybe#(WorkCompStatus), WorkCompReqType
    )) pendingLenCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(
        PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ,
        Maybe#(WorkCompStatus), WorkCompReqType, ADDR
    )) pendingDmaReqQ <- mkFIFOF;

    Reg#(Length)     remainingReadRespLenReg <- mkRegU;
    Reg#(ADDR)      nextReadRespWriteAddrReg <- mkRegU;
    Reg#(PktNum)           readRespPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)        preRdmaOpCodeReg <- mkReg(ACKNOWLEDGE);
    Reg#(RespHandleState) respHandleStateReg <- mkReg(SQ_HANDLE_RESP_HEADER);
    Reg#(Bool)              hasErrOccuredReg <- mkReg(False);

    // TODO: check discard duplicate or ghost reponses has
    // no response from PayloadConsumer will not incur bugs.
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

    // Response handle pipeline first stage
    rule recvRespHeader if (
        cntrl.isRTS && !hasErrOccuredReg            &&
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
        let wrAckType = WR_ACK_UNKNOWN;
        let wcReqType = WC_REQ_TYPE_UNKNOWN;

        let isIllegalResp   = !curPktMetaData.pktValid;
        let isMatchEndPSN   = bth.psn == endPSN;
        let isCoalesceResp  = psnInRangeExclusive(bth.psn, endPSN, nextPSN);
        let isMatchStartPSN = bth.psn == startPSN;
        let isPartialResp   = psnInRangeExclusive(bth.psn, startPSN, endPSN);

        if (isIllegalResp) begin
            wrAckType = WR_ACK_ILLEGAL;
            wcReqType = WC_REQ_TYPE_FULL_ACK;
        end
        else begin
            case ({
                pack(isMatchEndPSN), pack(isCoalesceResp),
                pack(isMatchStartPSN), pack(isPartialResp)
            })
                4'b1000, 4'b1010: begin // Response to whole WR, multi-or-single packets
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
                            wcReqType           = WC_REQ_TYPE_FULL_ACK;
                            respHandleStateReg <= SQ_ERROR_FLUSH;
                            deqPendingWorkReq = True;
                        end
                        RDMA_RESP_NORMAL: begin
                            wcReqType = WC_REQ_TYPE_FULL_ACK;
                            deqPendingWorkReq = True;
                        end
                        default: begin end
                    endcase
                end
                4'b0100: begin // Coalesce ACK
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
                        wcReqType = WC_REQ_TYPE_FULL_ACK;
                        deqPendingWorkReq = True;
                    end
                end
                4'b0010, 4'b0001: begin // Partial ACK
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
                            wcReqType           = WC_REQ_TYPE_FULL_ACK;
                            respHandleStateReg <= SQ_ERROR_FLUSH;
                            deqPendingWorkReq = True;
                        end
                        RDMA_RESP_NORMAL: begin
                            wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                        end
                        default: begin end
                    endcase
                end
                default: begin // Duplicated responses
                    wrAckType = WR_ACK_DUPLICATE;
                    wcReqType = WC_REQ_TYPE_NO_WC;
                end
            endcase
        end

        dynAssert(
            wrAckType != WR_ACK_UNKNOWN && wcReqType != WC_REQ_TYPE_UNKNOWN,
            "wrAckType and wcReqType assertion @ mkRespHandleSQ",
            $format(
                "wrAckType=", fshow(wrAckType),
                ", and wcReqType=", fshow(wcReqType),
                " should not be unknown"
            )
        );

        if (shouldDeqPktMetaData) begin
            pktMetaDataPipeIn.deq;
        end
        if (deqPendingWorkReq) begin
            pendingWorkReqPipeIn.deq;
            retryHandler.resetRetryCntBySQ;
        end

        if (
            (rdmaRespType == RDMA_RESP_NORMAL && isLastOrOnlyRdmaOpCode(bth.opcode)) ||
            (rdmaRespType == RDMA_RESP_ERROR)
        ) begin
            dynAssert(
                deqPendingWorkReq,
                "deqPendingWorkReq assertion @ mkRespHandleSQ",
                $format(
                    "deqPendingWorkReq=", fshow(deqPendingWorkReq),
                    " should be true when rdmaRespType=", fshow(rdmaRespType),
                    ", and bth.psn=%h, bth.opcode=", bth.psn, fshow(bth.opcode),
                    " is the last or only response, AETH=", fshow(aeth),
                    ", pending WR=", fshow(curPendingWR)
                )
            );
        end

        let respPktInfo = RespPktInfo {
            bth             : bth,
            aeth            : aeth,
            isZeroPayloadLen: isZero(curPktMetaData.pktPayloadLen),
            isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
            isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
            isReadResp      : isReadRespRdmaOpCode(bth.opcode),
            isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
            hasLocalErr     : False,
            shouldDiscard   : False,
            genWorkComp     : False // Altered in later stage
        };
        pendingRespQ.enq(tuple7(
            curPendingWR, curPktMetaData, respPktInfo,
            rdmaRespType, retryReason, wrAckType, wcReqType
        ));
        // $display(
        //     "time=%0d: 1st stage, bth.psn=%h, nextPSN=%h",
        //     $time, bth.psn, nextPSN,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", aeth.code=", fshow(aeth.code),
        //     ", curPendingWR=", fshow(curPendingWR),
        //     ", isIllegalResp=", fshow(isIllegalResp),
        //     ", isMatchEndPSN=", fshow(isMatchEndPSN),
        //     ", isCoalesceResp=", fshow(isCoalesceResp),
        //     ", isMatchStartPSN=", fshow(isMatchStartPSN),
        //     ", isPartialResp=", fshow(isPartialResp),
        //     ", rdmaRespType=", fshow(rdmaRespType),
        //     ", retryReason=", fshow(retryReason),
        //     ", wrAckType=", fshow(wrAckType),
        //     ", wcReqType=", fshow(wcReqType)
        // );
    endrule

    // Response handle pipeline second stage
    rule handleRespByType if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            curPendingWR, curPktMetaData, respPktInfo,
            rdmaRespType, retryReason, wrAckType, wcReqType
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let bth              = respPktInfo.bth;
        let isZeroPayloadLen = respPktInfo.isZeroPayloadLen;
        let isFirstOrOnlyPkt = respPktInfo.isFirstOrOnlyPkt;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;

        let respOpCodeSeqCheck = checkNormalRespOpCodeSeqSQ(preRdmaOpCodeReg, bth.opcode);
        let respMatchWorkReq   = rdmaRespMatchWorkReq(bth.opcode, curPendingWR.wr.opcode);

        let respAction = SQ_ACT_UNKNOWN;
        case (wrAckType)
            WR_ACK_EXPLICIT_WHOLE, WR_ACK_EXPLICIT_PARTIAL: begin
                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        respAction = SQ_ACT_EXPLICIT_RETRY;
                    end
                    RDMA_RESP_ERROR: begin
                        respAction = SQ_ACT_ERROR_RESP;
                    end
                    RDMA_RESP_NORMAL: begin
                        // Only update pre-opcode when normal response
                        if (!hasErrOccuredReg) begin
                            preRdmaOpCodeReg <= bth.opcode;
                        end

                        if (!respMatchWorkReq || !respOpCodeSeqCheck) begin
                            respAction = SQ_ACT_BAD_RESP;
                            respPktInfo.hasLocalErr = True;
                            if (wrAckType == WR_ACK_EXPLICIT_PARTIAL) begin
                                wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                            end
                            else begin
                                wcReqType = WC_REQ_TYPE_FULL_ACK;
                            end
                        end
                        else begin
                            respAction = SQ_ACT_EXPLICIT_RESP;
                        end
                    end
                    default: begin end
                endcase
            end
            WR_ACK_COALESCE_NORMAL: begin
                respAction = SQ_ACT_COALESCE_RESP;
            end
            WR_ACK_COALESCE_RETRY: begin
                respAction = SQ_ACT_IMPLICIT_RETRY;
            end
            WR_ACK_DUPLICATE: begin
                respAction = SQ_ACT_DUPLICATE_RESP;
            end
            WR_ACK_GHOST, WR_ACK_DISCARD: begin
                respAction = SQ_ACT_DISCARD_RESP;
            end
            WR_ACK_ILLEGAL: begin
                respAction = pktStatus2RespActionSQ(curPktMetaData.pktStatus);
            end
            WR_ACK_ERR_FLUSH_WR: begin
                respAction = SQ_ACT_FLUSH_WR;
            end
            default: begin end
        endcase

        dynAssert(
            respAction != SQ_ACT_UNKNOWN,
            "respAction assertion @ mkRespHandleSQ",
            $format("respAction=", fshow(respAction), " should not be unknown")
        );
        pendingPermQueryQ.enq(tuple5(
            curPendingWR, curPktMetaData, respPktInfo, respAction, wcReqType
        ));
        // $display(
        //     "time=%0d: 2nd stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType)
        // );
    endrule

    // Response handle pipeline third stage
    rule queryPerm4NormalReadAtomicResp if (cntrl.isRTS || cntrl.isERR);
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType
        } = pendingPermQueryQ.first;
        pendingPermQueryQ.deq;

        let isZeroPayloadLen = respPktInfo.isZeroPayloadLen;
        let isFirstOrOnlyPkt = respPktInfo.isFirstOrOnlyPkt;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;

        let expectPermCheckResp = False;
        if (respAction == SQ_ACT_EXPLICIT_RESP) begin
            if (
                !hasErrOccuredReg && isFirstOrOnlyPkt &&
                ((isReadResp && !isZeroPayloadLen) || isAtomicResp)
            ) begin
                let permCheckInfo = PermCheckInfo {
                    wrID         : tagged Valid pendingWR.wr.id,
                    lkey         : pendingWR.wr.lkey,
                    rkey         : dontCareValue,
                    laddr        : pendingWR.wr.laddr,
                    totalLen     : pendingWR.wr.len,
                    pdHandler    : pktMetaData.pdHandler,
                    isZeroDmaLen : isAtomicResp ? False : isZeroPayloadLen,
                    accType      : IBV_ACCESS_LOCAL_WRITE,
                    localOrRmtKey: True
                };
                permCheckMR.checkReq(permCheckInfo);
                expectPermCheckResp = True;
            end
        end

        pendingPermCheckQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, expectPermCheckResp
        ));
        // $display(
        //     "time=%0d: 3rd stage, respAction=", $time, fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", expectPermCheckResp=", fshow(expectPermCheckResp)
        // );
    endrule

    // Response handle pipeline fourth stage
    rule checkPerm4NormalReadAtomicResp if (cntrl.isRTS || cntrl.isERR);
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, expectPermCheckResp
        } = pendingPermCheckQ.first;
        pendingPermCheckQ.deq;

        let bth  = respPktInfo.bth;
        let aeth = respPktInfo.aeth;

        let isLastOrOnlyPkt = respPktInfo.isLastOrOnlyPkt;
        let needWorkComp    = workReqNeedWorkCompSQ(pendingWR.wr);
        let wcStatus        = tagged Invalid;
        case (respAction)
            SQ_ACT_BAD_RESP: begin
                respPktInfo.genWorkComp = True;
                // Discard bad response payload
                respPktInfo.shouldDiscard = True;
                wcStatus = tagged Valid IBV_WC_BAD_RESP_ERR;
            end
            SQ_ACT_ERROR_RESP: begin
                respPktInfo.genWorkComp = True;

                dynAssert(
                    rdmaRespHasAETH(bth.opcode),
                    "rdmaRespHasAETH assertion @ mkRespHandleSQ",
                    $format(
                        "rdmaRespHasAETH=", fshow(rdmaRespHasAETH(bth.opcode)),
                        " should be true"
                    )
                );
                wcStatus = genErrWorkCompStatusFromAethSQ(aeth);
                dynAssert(
                    isValid(wcStatus),
                    "isValid(wcStatus) assertion @ mkRespHandleSQ",
                    $format("wcStatus=", fshow(wcStatus), " should be valid")
                );
            end
            SQ_ACT_EXPLICIT_RESP: begin
                if (expectPermCheckResp) begin
                    let mrCheckResult <- permCheckMR.checkResp;
                    if (!mrCheckResult) begin
                        wcStatus   = tagged Valid IBV_WC_LOC_ACCESS_ERR;
                        respAction = SQ_ACT_LOCAL_ACC_ERR;
                        respPktInfo.genWorkComp   = True;
                        respPktInfo.hasLocalErr   = True;
                        // Discard read response payload
                        respPktInfo.shouldDiscard = True;
                    end
                end

                if (needWorkComp && isLastOrOnlyPkt) begin
                    respPktInfo.genWorkComp = True;

                    // If need WC and no valid WC status yet,
                    // then WC status is success.
                    if (!isValid(wcStatus)) begin
                        wcStatus = tagged Valid IBV_WC_SUCCESS;
                    end
                end
            end
            SQ_ACT_COALESCE_RESP: begin
                respPktInfo.genWorkComp = needWorkComp;
                wcStatus = needWorkComp ? (tagged Valid IBV_WC_SUCCESS) : (tagged Invalid);
            end
            SQ_ACT_DUPLICATE_RESP: begin
                // Discard duplicate response payload
                respPktInfo.shouldDiscard = True;
            end
            // SQ_ACT_GHOST_RESP: begin
            //     // Discard ghost response payload
            //     respPktInfo.shouldDiscard = True;
            // end
            SQ_ACT_ILLEGAL_RESP: begin
                respPktInfo.genWorkComp   = True;
                // Discard illegal response payload
                respPktInfo.shouldDiscard = True;
                wcStatus = pktStatus2WorkCompStatusSQ(pktMetaData.pktStatus);
            end
            SQ_ACT_DISCARD_RESP: begin
                // Discard response payload when retry or error flush
                respPktInfo.shouldDiscard = True;
            end
            SQ_ACT_FLUSH_WR: begin
                // Generate WC for flushed WR
                respPktInfo.genWorkComp = True;
                wcStatus  = tagged Valid IBV_WC_WR_FLUSH_ERR;
            end
            SQ_ACT_EXPLICIT_RETRY, SQ_ACT_IMPLICIT_RETRY: begin
                // TODO: support timeout retry error
                let isRetryErr  = retryHandler.hasRetryErr;
                if (isRetryErr) begin
                    wcStatus  = tagged Valid IBV_WC_RETRY_EXC_ERR;
                    wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                    respPktInfo.genWorkComp = True;
                end

                // Discard implicite retry response payload
                respPktInfo.shouldDiscard = True;
            end
            default: begin end
        endcase

        pendingLenCheckQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType
        ));
        // $display(
        //     "time=%0d: 4th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType)
        // );
    endrule

    // Response handle pipeline fifth stage
    rule checkReadRespLen if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType
        } = pendingLenCheckQ.first;
        pendingLenCheckQ.deq;

        let bth           = respPktInfo.bth;
        let isReadResp    = respPktInfo.isReadResp;
        let pktPayloadLen = pktMetaData.pktPayloadLen;
        let isFirstPkt    = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt      = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt     = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt     = isOnlyRdmaOpCode(bth.opcode);

        let isLastOrOnlyPkt       = respPktInfo.isLastOrOnlyPkt;
        let enoughDmaSpace        = True;
        let readRespLenMatch      = True;
        let remainingReadRespLen  = remainingReadRespLenReg;
        let nextReadRespWriteAddr = nextReadRespWriteAddrReg;
        let readRespPktNum        = readRespPktNumReg;
        let oneAsPSN              = 1;

        if (isReadResp) begin
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

            if (respAction == SQ_ACT_EXPLICIT_RESP && !hasErrOccuredReg) begin
                remainingReadRespLenReg  <= remainingReadRespLen;
                nextReadRespWriteAddrReg <= nextReadRespWriteAddr;
                readRespPktNumReg        <= readRespPktNum;

                readRespLenMatch = isLastOrOnlyPkt ? isZero(remainingReadRespLen) : True;
                if (!enoughDmaSpace || !readRespLenMatch) begin
                    // Read response length not match WR length
                    respAction    = SQ_ACT_LOCAL_LEN_ERR;
                    wcStatus      = tagged Valid IBV_WC_LOC_LEN_ERR;
                    wcReqType     = isLastOrOnlyPkt ? WC_REQ_TYPE_FULL_ACK : WC_REQ_TYPE_PARTIAL_ACK;
                    respPktInfo.genWorkComp   = True;
                    respPktInfo.hasLocalErr   = True;
                    // Discard read response payload when length error
                    respPktInfo.shouldDiscard = True;
                end

                // $display(
                //     "time=%0d: bth.opcode=", $time, fshow(bth.opcode),
                //     ", remainingReadRespLen=%h", remainingReadRespLen,
                //     ", nextReadRespWriteAddr=%h", nextReadRespWriteAddr,
                //     ", readRespPktNum=%0d", readRespPktNum
                // );
            end
        end

        pendingDmaReqQ.enq(tuple7(
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        ));
        // $display(
        //     "time=%0d: 5th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", nextReadRespWriteAddr=", fshow(nextReadRespWriteAddr)
        // );
    endrule

    // Response handle pipeline sixth stage
    rule genWorkCompAndInitDma if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        let rdmaHeader       = pktMetaData.pktHeader;
        let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let genWorkComp      = respPktInfo.genWorkComp;
        let shouldDiscard    = respPktInfo.shouldDiscard;
        let hasLocalErr      = respPktInfo.hasLocalErr;
        let bth              = respPktInfo.bth;
        let isZeroPayloadLen = respPktInfo.isZeroPayloadLen;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;

        let wcWaitDmaResp = False;
        if (respAction == SQ_ACT_EXPLICIT_RESP && !hasErrOccuredReg) begin
            if (isReadResp && !isZeroPayloadLen) begin
                let payloadConReq = PayloadConReq {
                    initiator    : OP_INIT_SQ_WR,
                    fragNum      : pktMetaData.pktFragNum,
                    consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                        sqpn     : cntrl.getSQPN,
                        startAddr: nextReadRespWriteAddr,
                        len      : pktMetaData.pktPayloadLen,
                        psn      : bth.psn
                    }
                };
                payloadConReqOutQ.enq(payloadConReq);
                wcWaitDmaResp = True;
            end
            else if (isAtomicResp) begin
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
        end
        else if (shouldDiscard || hasErrOccuredReg) begin
            discardPktPayload(pktMetaData.pktFragNum);
        end

        dynAssert(
            !hasLocalErr || genWorkComp,
            "hasLocalErr -> genWorkComp assertion @ mkRespHandleSQ",
            $format(
                "genWorkComp=", fshow(genWorkComp),
                " should be true when hasLocalErr=", fshow(hasLocalErr),
                ", respAction=", fshow(respAction)
            )
        );

        if (!hasErrOccuredReg) begin
            if (wcStatus matches tagged Valid .wcs &&& wcs != IBV_WC_SUCCESS) begin
                hasErrOccuredReg <= True;
                // $display(
                //     "time=%0d: hasErrOccuredReg=", $time, fshow(hasErrOccuredReg),
                //     ", wcStatus=", fshow(wcStatus)
                // );

                dynAssert(
                    genWorkComp,
                    "genWorkComp assertion @ mkRespHandleSQ",
                    $format(
                        "genWorkComp=", fshow(genWorkComp),
                        " should be true when wcStatus=", fshow(wcs)
                    )
                );
            end
        end

        if (genWorkComp || wcWaitDmaResp) begin
            dynAssert(
                !genWorkComp || isValid(wcStatus),
                "genWorkComp -> isValid(wcStatus) assertion @ mkRespHandleSQ",
                $format(
                    "wcStatus=", fshow(wcStatus),
                    " should be valid when genWorkComp=", fshow(genWorkComp),
                    ", respAction=", fshow(respAction)
                )
            );

            dynAssert(
                !(wcWaitDmaResp && !genWorkComp) || !isValid(wcStatus),
                "(wcWaitDmaResp && !genWorkComp) -> !isValid(wcStatus) assertion @ mkRespHandleSQ",
                $format(
                    "wcStatus=", fshow(wcStatus),
                    " should be invalid when wcWaitDmaResp=", fshow(wcWaitDmaResp),
                    " and genWorkComp=", fshow(genWorkComp),
                    ", respAction=", fshow(respAction)
                )
            );

            let wcGenReq = WorkCompGenReqSQ {
                pendingWR    : pendingWR,
                wcWaitDmaResp: wcWaitDmaResp,
                wcReqType    : wcReqType,
                triggerPSN   : bth.psn,
                wcStatus     : unwrapMaybeWithDefault(wcStatus, IBV_WC_SUCCESS)
            };
            // Wait for read/atomic response DMA write and generate WC for WR if needed
            workCompGenReqOutQ.enq(wcGenReq);
            // $display(
            //     "time=%0d: wcGenReq=", $time, fshow(wcGenReq),
            //     ", wcStatus=", fshow(wcStatus)
            // );
        end
        // $display(
        //     "time=%0d: 6th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", genWorkComp=", fshow(genWorkComp),
        //     ", wcWaitDmaResp=", fshow(wcWaitDmaResp)
        // );
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule errFlushPktMetaDataAndPayload if (
        cntrl.isERR || hasErrOccuredReg      ||
        respHandleStateReg == SQ_ERROR_FLUSH || // Error flush
        !pendingWorkReqPipeIn.notEmpty          // Ghost responses
    );
        if (pendingWorkReqPipeIn.notEmpty) begin
            let pendingWR = pendingWorkReqPipeIn.first;
            pendingWorkReqPipeIn.deq;

            let respPktInfo = RespPktInfo {
                bth             : dontCareValue,
                aeth            : dontCareValue,
                isZeroPayloadLen: True,
                isFirstOrOnlyPkt: True,
                isLastOrOnlyPkt : True,
                isReadResp      : False,
                isAtomicResp    : False,
                hasLocalErr     : True,
                shouldDiscard   : True,
                genWorkComp     : True
            };
            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen: 0,
                pktFragNum   : 0,
                pktHeader    : dontCareValue,
                pdHandler    : dontCareValue,
                pktValid     : False,
                pktStatus    : PKT_ST_DISCARD
            };

            let rdmaRespType = RDMA_RESP_UNKNOWN;
            let retryReason  = RETRY_REASON_NOT_RETRY;
            let wrAckType    = WR_ACK_ERR_FLUSH_WR;
            let wcReqType    = WC_REQ_TYPE_FULL_ACK;
            pendingRespQ.enq(tuple7(
                pendingWR, pktMetaData, respPktInfo, rdmaRespType,
                retryReason, wrAckType, wcReqType
            ));
            // $display(
            //     "time=%0d: 1st error flush stage", $time,
            //     ", pendingWR=", fshow(pendingWR),
            //     ", rdmaRespType=", fshow(rdmaRespType),
            //     ", retryReason=", fshow(retryReason),
            //     ", wrAckType=", fshow(wrAckType),
            //     ", wcReqType=", fshow(wcReqType)
            // );
        end
        else if (pktMetaDataPipeIn.notEmpty) begin
            let pktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            PendingWorkReq emptyPendingWR = dontCareValue;

            let rdmaHeader  = pktMetaData.pktHeader;
            let bth         = extractBTH(rdmaHeader.headerData);
            let aeth        = extractAETH(rdmaHeader.headerData);
            let respPktInfo = RespPktInfo {
                bth             : bth,
                aeth            : aeth,
                isZeroPayloadLen: isZero(pktMetaData.pktPayloadLen),
                isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
                isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
                isReadResp      : isReadRespRdmaOpCode(bth.opcode),
                isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
                hasLocalErr     : False,
                shouldDiscard   : True,
                genWorkComp     : False
            };
            let rdmaRespType = RDMA_RESP_UNKNOWN;
            let retryReason  = RETRY_REASON_NOT_RETRY;
            let wrAckType    = pendingWorkReqPipeIn.notEmpty ?
                WR_ACK_DISCARD : WR_ACK_GHOST;
            let wcReqType    = WC_REQ_TYPE_NO_WC;
            pendingRespQ.enq(tuple7(
                emptyPendingWR, pktMetaData, respPktInfo, rdmaRespType,
                retryReason, wrAckType, wcReqType
            ));
            // $display(
            //     "time=%0d: 1st discard stage, bth.psn=%h", $time, bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode),
            //     ", rdmaRespType=", fshow(rdmaRespType),
            //     ", retryReason=", fshow(retryReason),
            //     ", wrAckType=", fshow(wrAckType),
            //     ", wcReqType=", fshow(wcReqType)
            // );
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule retryFlushPktMetaDataAndPayload if (
        cntrl.isRTS && !hasErrOccuredReg     &&
        respHandleStateReg == SQ_RETRY_FLUSH &&
        pendingWorkReqPipeIn.notEmpty
    );
        if (pktMetaDataPipeIn.notEmpty) begin
            let pktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            PendingWorkReq emptyPendingWR = dontCareValue;

            let rdmaHeader  = pktMetaData.pktHeader;
            let bth         = extractBTH(rdmaHeader.headerData);
            let aeth        = extractAETH(rdmaHeader.headerData);
            let respPktInfo = RespPktInfo {
                bth             : bth,
                aeth            : aeth,
                isZeroPayloadLen: isZero(pktMetaData.pktPayloadLen),
                isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
                isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
                isReadResp      : isReadRespRdmaOpCode(bth.opcode),
                isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
                hasLocalErr     : False,
                shouldDiscard   : True,
                genWorkComp     : False
            };
            let rdmaRespType = RDMA_RESP_UNKNOWN;
            let retryReason = RETRY_REASON_NOT_RETRY;
            let wrAckType = WR_ACK_DISCARD;
            let wcReqType = WC_REQ_TYPE_NO_WC;
            pendingRespQ.enq(tuple7(
                emptyPendingWR, pktMetaData, respPktInfo, rdmaRespType,
                retryReason, wrAckType, wcReqType
            ));
            $display(
                "time=%0d: 1st retry flush stage, bth.psn=%h", $time, bth.psn,
                ", bth.opcode=", fshow(bth.opcode),
                ", rdmaRespType=", fshow(rdmaRespType),
                ", retryReason=", fshow(retryReason),
                ", wrAckType=", fshow(wrAckType),
                ", wcReqType=", fshow(wcReqType)
            );
        end

        if (
            cntrl.isRTS && !hasErrOccuredReg &&
            respHandleStateReg == SQ_RETRY_FLUSH
        ) begin
            // Retry WR begin, change state to normal handling
            if (retryHandler.retryBegin) begin
                respHandleStateReg <= SQ_HANDLE_RESP_HEADER;
            end
        end
    endrule

    interface payloadConReqPipeOut = convertFifo2PipeOut(payloadConReqOutQ);
    interface workCompGenReqPipeOut = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
