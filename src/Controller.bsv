import ClientServer :: *;
import FIFOF :: *;

import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;

typedef Bit#(1) Epoch;


typedef Server#(ReqQP, RespQP) SrvPortQP;

interface ContextRQ;
endinterface

interface Controller;
    interface SrvPortQP srvPort;
    interface ContextRQ contextRQ;
endinterface

module mkController(Controller);
    FIFOF#(ReqQP)   reqQ <- mkFIFOF;
    FIFOF#(RespQP) respQ <- mkFIFOF;

    // QP Attributes related
    Reg#(QpState) stateReg <- mkReg(IBV_QPS_RESET);
    Reg#(QpType) qpTypeReg <- mkRegU;

    Reg#(RetryCnt)      maxRnrCntReg <- mkRegU;
    Reg#(RetryCnt)    maxRetryCntReg <- mkRegU;
    Reg#(TimeOutTimer) maxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    minRnrTimerReg <- mkRegU;

    Reg#(Bool)       errFlushDoneReg <- mkRegU;

    // TODO: support QP access check
    Reg#(MemAccessTypeFlags) qpAcessFlagsReg <- mkRegU;
    // TODO: support max WR/RR pending number check
    Reg#(PendingReqCnt) pendingWorkReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingRecvReqNumReg <- mkRegU;
    // TODO: support max read/atomic pending requests check
    Reg#(PendingReadAtomicReqCnt)     pendingReadAtomicReqNumReg <- mkRegU;
    Reg#(PendingReadAtomicReqCnt) pendingDestReadAtomicReqNumReg <- mkRegU;
    // TODO: support SG
    Reg#(ScatterGatherElemCnt) sendScatterGatherElemCntReg <- mkRegU;
    Reg#(ScatterGatherElemCnt) recvScatterGatherElemCntReg <- mkRegU;
    // TODO: support inline data
    Reg#(InlineDataSize)       inlineDataSizeReg <- mkRegU;

    Reg#(Bool) sqSigAllReg <- mkRegU;
    Reg#(QPN) sqpnReg <- mkRegU;
    Reg#(QPN) dqpnReg <- mkRegU;

    Reg#(PKEY) pkeyReg <- mkRegU;
    Reg#(QKEY) qkeyReg <- mkRegU;
    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;
    // End QP attributes related

    Bool inited = stateReg != IBV_QPS_RESET;

    // ContextRQ related
    Reg#(PermCheckInfo) permCheckInfoReg <- mkRegU;
    Reg#(Length)     totalDmaWriteLenReg <- mkRegU;
    Reg#(Length) remainingDmaWriteLenReg <- mkRegU;
    Reg#(ADDR)       nextDmaWriteAddrReg <- mkRegU;
    Reg#(PktNum)   sendWriteReqPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)  preReqOpCodeReg[2] <- mkCReg(2, SEND_ONLY);

    // Reg#(Bit#(RNR_WAIT_CNT_WIDTH)) rnrWaitCntReg <- mkRegU;
    // Reg#(Bool) rnrFlushReg <- mkReg(False);

    Reg#(Bool) errFlushReg <- mkReg(False);
    Reg#(Epoch)   epochReg <- mkReg(0);
    Reg#(MSN)       msnReg <- mkReg(0);

    Reg#(PktNum) respPktNumReg <- mkRegU;
    Reg#(PSN)    curRespPsnReg <- mkRegU;
    Reg#(PSN)       epsnReg[2] <- mkCRegU(2);
    // End ContextRQ related

    (* no_implicit_conditions, fire_when_enabled *)
    rule noUnknownState;
        immAssert(
            stateReg != IBV_QPS_UNKNOWN,
            "unknown state assertion @ mkController",
            $format("stateReg=", fshow(stateReg), " should not be IBV_QPS_UNKNOWN")
        );
        // $display("time=%0t:", $time, " sqpnReg=%h, stateReg=", sqpnReg, fshow(stateReg));
    endrule

    // TODO: do not flush server requests
    rule flushSrvPort if (
        stateReg == IBV_QPS_RTS ||
        stateReg == IBV_QPS_RTR ||
        stateReg == IBV_QPS_SQD
    );
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: False,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        immFail(
            "flushSrvPort @ mkController",
            $format("flushSrvPort is prohibited, sqpnReg=%h, qpReq=", sqpnReg, fshow(qpReq))
        );
        respQ.enq(qpResp);
    endrule

    rule handleSrvPort if (
        stateReg == IBV_QPS_RESET ||
        stateReg == IBV_QPS_INIT  ||
        stateReg == IBV_QPS_ERR   ||
        stateReg == IBV_QPS_SQE
    );
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: False,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        if (qpReq.qpReqType != REQ_QP_CREATE) begin
            immAssert(
                qpReq.qpn == sqpnReg,
                "SQPN assertion @ mkController",
                $format("qpReq.qpn=%h should == sqpnReg=%h", qpReq.qpn, sqpnReg)
            );
        end

        case (qpReq.qpReqType)
            REQ_QP_CREATE: begin
                sqpnReg                        <= qpReq.qpn;
                qpTypeReg                      <= qpReq.qpInitAttr.qpType;
                sqSigAllReg                    <= qpReq.qpInitAttr.sqSigAll;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_DESTROY: begin
                stateReg                       <= IBV_QPS_RESET;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_MODIFY: begin
                // TODO: modify QP by QpAttrMask
                // TODO: maybe don't need a mask? Do it in the software layer
                stateReg                       <= qpReq.qpAttr.qpState;
                // qpTypeReg                      <= qpType;
                maxRnrCntReg                   <= qpReq.qpAttr.rnrRetry;
                maxRetryCntReg                 <= qpReq.qpAttr.retryCnt;
                maxTimeOutReg                  <= qpReq.qpAttr.timeout;
                minRnrTimerReg                 <= qpReq.qpAttr.minRnrTimer;
                // errFlushDoneReg                <= True;
                qpAcessFlagsReg                <= qpReq.qpAttr.qpAcessFlags;
                pendingWorkReqNumReg           <= qpReq.qpAttr.cap.maxSendWR;
                pendingRecvReqNumReg           <= qpReq.qpAttr.cap.maxRecvWR;
                pendingReadAtomicReqNumReg     <= qpReq.qpAttr.maxReadAtomic;
                pendingDestReadAtomicReqNumReg <= qpReq.qpAttr.maxDestReadAtomic;
                // sqSigAllReg                    <= sqSigAll;
                dqpnReg                        <= qpReq.qpAttr.dqpn;
                pkeyReg                        <= qpReq.qpAttr.pkeyIndex;
                qkeyReg                        <= qpReq.qpAttr.qkey;
                pmtuReg                        <= qpReq.qpAttr.pmtu;
                npsnReg                        <= qpReq.qpAttr.sqPSN;
                epsnReg[0]                     <= qpReq.qpAttr.rqPSN;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_QUERY : begin
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.pmtu              = pmtuReg;
                qpResp.qpAttr.qkey              = qkeyReg;
                qpResp.qpAttr.rqPSN             = epsnReg[0];
                qpResp.qpAttr.sqPSN             = npsnReg;
                qpResp.qpAttr.dqpn              = dqpnReg;
                qpResp.qpAttr.qpAcessFlags      = qpAcessFlagsReg; // TODO: implement enum flag bitwise-or
                qpResp.qpAttr.cap.maxSendWR     = pendingWorkReqNumReg;
                qpResp.qpAttr.cap.maxRecvWR     = pendingRecvReqNumReg;
                qpResp.qpAttr.cap.maxSendSGE    = sendScatterGatherElemCntReg;
                qpResp.qpAttr.cap.maxRecvSGE    = recvScatterGatherElemCntReg;
                qpResp.qpAttr.cap.maxInlineData = inlineDataSizeReg;
                qpResp.qpAttr.pkeyIndex         = pkeyReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
                qpResp.qpAttr.maxReadAtomic     = pendingReadAtomicReqNumReg;
                qpResp.qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
                qpResp.qpAttr.minRnrTimer       = minRnrTimerReg;
                qpResp.qpAttr.timeout           = maxTimeOutReg;
                qpResp.qpAttr.retryCnt          = maxRetryCntReg;
                qpResp.qpAttr.rnrRetry          = maxRnrCntReg;

                qpResp.qpInitAttr.qpType        = qpTypeReg;
                qpResp.qpInitAttr.sqSigAll      = sqSigAllReg;

                qpResp.successOrNot = True;
            end
            default: begin
                immFail(
                    "unreachible case @ mkController",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        "qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        // $display(
        //     "time=%0t: controller receives qpReq=", $time, fshow(qpReq),
        //     " and generates qpResp=", fshow(qpResp)
        // );
        respQ.enq(qpResp);
    endrule

    interface srvPort = toGPServer(reqQ, respQ);

    interface contextRQ = interface ContextRQ;
    endinterface;
endmodule
