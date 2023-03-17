import ClientServer :: *;
import FIFOF :: *;

import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;

typedef Bit#(1) Epoch;

`define QP_ATTR_MASK_OR_NOT(attrName) (pack(qpReq.qpAttrMask) & pack(attrName)) != 0

typedef Server#(ReqQP, RespQP) SrvPortQP;

interface ContextRQ;
    method PermCheckInfo getPermCheckInfo();
    method Action        setPermCheckInfo(PermCheckInfo permCheckInfo);
    method Length        getTotalDmaWriteLen();
    method Action        setTotalDmaWriteLen(Length totalDmaWriteLen);
    method Length        getRemainingDmaWriteLen();
    method Action        setRemainingDmaWriteLen(Length remainingDmaWriteLen);
    method ADDR          getNextDmaWriteAddr();
    method Action        setNextDmaWriteAddr(ADDR nextDmaWriteAddr);
    method PktNum        getSendWriteReqPktNum();
    method Action        setSendWriteReqPktNum(PktNum sendWriteReqPktNum);
    method RdmaOpCode    getPreReqOpCode();
    method Action        setPreReqOpCode(RdmaOpCode preOpCode);
    method Action        restorePreReqOpCode(RdmaOpCode preOpCode);
    method Epoch         getEpoch();
    method Action        incEpoch();
    method MSN           getMSN();
    method Action        setMSN(MSN msn);
    method PktNum        getRespPktNum();
    method Action        setRespPktNum(PktNum respPktNum);
    method PSN           getCurRespPSN();
    method Action        setCurRespPsn(PSN curRespPsn);
    method PSN           getEPSN();
    method Action        setEPSN(PSN psn);
    method Action        restoreEPSN(PSN psn);
endinterface

interface Controller;
    interface SrvPortQP srvPort;
    interface ContextRQ contextRQ;

    method Action initialize(
        QpType                  qpType,
        RetryCnt                maxRnrCnt,
        RetryCnt                maxRetryCnt,
        TimeOutTimer            maxTimeOut,
        RnrTimer                minRnrTimer,
        MemAccessTypeFlags      qpAcessFlags,
        PendingReqCnt           pendingWorkReqNum,
        PendingReqCnt           pendingRecvReqNum,
        PendingReadAtomicReqCnt pendingReadAtomicReqNum,
        PendingReadAtomicReqCnt pendingDestReadAtomicReqNum,
        Bool                    sqSigAll,
        QPN                     sqpn,
        QPN                     dqpn,
        PKEY                    pkey,
        QKEY                    qkey,
        PMTU                    pmtu,
        PSN                     npsn,
        PSN                     epsn
    );

    method Bool isERR();
    method Bool isInit();
    method Bool isReset();
    method Bool isRTR();
    method Bool isRTS();
    method Bool isNonErr();
    method Bool isSQD();

    method QpState getQPS();
    // method Action setQPS(QpState qps);
    method Action setStateReset();
    // method Action setStateInit();
    method Action setStateRTR();
    method Action setStateRTS();
    method Action setStateSQD();
    method Action setStateErr();
    method Action errFlushDone();

    method QpType getQpType();
    // method Action setQpType(QpType qpType);

    method RetryCnt getMaxRnrCnt();
    method RetryCnt getMaxRetryCnt();
    method TimeOutTimer getMaxTimeOut();
    method RnrTimer getMinRnrTimer();

    method PendingReqCnt getPendingWorkReqNum();
    // method Action setPendingWorkReqNum(PendingReqCnt cnt);
    method PendingReqCnt getPendingRecvReqNum();
    // method Action setPendingRecvReqNum(PendingReqCnt cnt);
    // method PendingReqCnt getPendingReadAtomicReqnumList();
    method Bool getSigAll();
    // method Action setSigAll(Bool segAll);

    method QPN getSQPN();
    // method Action setSQPN(QPN sqpn);
    method QPN getDQPN();
    // method Action setDQPN(QPN dqpn);
    method PKEY getPKEY();
    // method Action setPKEY(PKEY pkey);
    method QKEY getQKEY();
    // method Action setQKEY(QKEY qkey);
    method PMTU getPMTU();
    // method Action setPMTU(PMTU pmtu);
    method PSN getNPSN();
    method Action setNPSN(PSN psn);
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
                // TODO: modify QP by qpReq.qpAttrMask
                // stateReg                       <= qpReq.qpAttr.qpState;
                // // qpTypeReg                      <= qpType;
                // maxRnrCntReg                   <= qpReq.qpAttr.rnrRetry;
                // maxRetryCntReg                 <= qpReq.qpAttr.retryCnt;
                // maxTimeOutReg                  <= qpReq.qpAttr.timeout;
                // minRnrTimerReg                 <= qpReq.qpAttr.minRnrTimer;
                // // errFlushDoneReg                <= True;
                // qpAcessFlagsReg                <= qpReq.qpAttr.qpAcessFlags;
                // pendingWorkReqNumReg           <= qpReq.qpAttr.cap.maxSendWR;
                // pendingRecvReqNumReg           <= qpReq.qpAttr.cap.maxRecvWR;
                // pendingReadAtomicReqNumReg     <= qpReq.qpAttr.maxReadAtomic;
                // pendingDestReadAtomicReqNumReg <= qpReq.qpAttr.maxDestReadAtomic;
                // // sqSigAllReg                    <= sqSigAll;
                // dqpnReg                        <= qpReq.qpAttr.dqpn;
                // pkeyReg                        <= qpReq.qpAttr.pkeyIndex;
                // qkeyReg                        <= qpReq.qpAttr.qkey;
                // pmtuReg                        <= qpReq.qpAttr.pmtu;
                // npsnReg                        <= qpReq.qpAttr.sqPSN;
                // epsnReg[0]                     <= qpReq.qpAttr.rqPSN;

                // TODO: mask check? Can be done in the software layer
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_STATE)) begin
                    stateReg <= qpReq.qpAttr.qpState;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_ACCESS_FLAGS)) begin
                    qpAcessFlagsReg <= qpReq.qpAttr.qpAcessFlags;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_PKEY_INDEX)) begin
                    pkeyReg <= qpReq.qpAttr.pkeyIndex;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_QKEY)) begin
                    qkeyReg <= qpReq.qpAttr.qkey;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_PATH_MTU)) begin
                    pmtuReg <= qpReq.qpAttr.pmtu;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_TIMEOUT)) begin
                    maxTimeOutReg <= qpReq.qpAttr.timeout;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_RETRY_CNT)) begin
                    maxRetryCntReg <= qpReq.qpAttr.retryCnt;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_RNR_RETRY)) begin
                    maxRnrCntReg <= qpReq.qpAttr.rnrRetry;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_RQ_PSN)) begin
                    epsnReg[0] <= qpReq.qpAttr.rqPSN;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_MAX_QP_RD_ATOMIC)) begin
                    pendingReadAtomicReqNumReg <= qpReq.qpAttr.maxReadAtomic;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_MIN_RNR_TIMER)) begin
                    minRnrTimerReg <= qpReq.qpAttr.minRnrTimer;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_SQ_PSN)) begin
                    npsnReg <= qpReq.qpAttr.sqPSN;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_MAX_DEST_RD_ATOMIC)) begin
                    pendingDestReadAtomicReqNumReg <= qpReq.qpAttr.maxDestReadAtomic;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_CAP)) begin
                    pendingWorkReqNumReg <= qpReq.qpAttr.cap.maxSendWR;
                    pendingRecvReqNumReg <= qpReq.qpAttr.cap.maxRecvWR;
                end
                if (`QP_ATTR_MASK_OR_NOT(IBV_QP_DEST_QPN)) begin
                    dqpnReg <= qpReq.qpAttr.dqpn;
                end
            

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

    method Action initialize(
        QpType                  qpType,
        RetryCnt                maxRnrCnt,
        RetryCnt                maxRetryCnt,
        TimeOutTimer            maxTimeOut,
        RnrTimer                minRnrTimer,
        MemAccessTypeFlags      qpAcessFlags,
        PendingReqCnt           pendingWorkReqNum,
        PendingReqCnt           pendingRecvReqNum,
        PendingReadAtomicReqCnt pendingReadAtomicReqNum,
        PendingReadAtomicReqCnt pendingDestReadAtomicReqNum,
        Bool                    sqSigAll,
        QPN                     sqpn,
        QPN                     dqpn,
        PKEY                    pkey,
        QKEY                    qkey,
        PMTU                    pmtu,
        PSN                     npsn,
        PSN                     epsn
    ) if (!inited);
        stateReg                       <= IBV_QPS_INIT;

        qpTypeReg                      <= qpType;
        maxRnrCntReg                   <= maxRnrCnt;
        maxRetryCntReg                 <= maxRetryCnt;
        maxTimeOutReg                  <= maxTimeOut;
        minRnrTimerReg                 <= minRnrTimer;
        errFlushDoneReg                <= True;
        qpAcessFlagsReg                <= qpAcessFlags;
        pendingWorkReqNumReg           <= pendingWorkReqNum;
        pendingRecvReqNumReg           <= pendingRecvReqNum;
        pendingReadAtomicReqNumReg     <= pendingReadAtomicReqNum;
        pendingDestReadAtomicReqNumReg <= pendingDestReadAtomicReqNum;
        sqSigAllReg                    <= sqSigAll;
        sqpnReg                        <= sqpn;
        dqpnReg                        <= dqpn;
        pkeyReg                        <= pkey;
        qkeyReg                        <= qkey;
        pmtuReg                        <= pmtu;
        npsnReg                        <= npsn;
        epsnReg[0]                     <= epsn;
    endmethod

    method Bool isERR()    = stateReg == IBV_QPS_ERR;
    method Bool isInit()   = stateReg == IBV_QPS_INIT;
    method Bool isNonErr() = stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS || stateReg == IBV_QPS_SQD;
    method Bool isReset()  = stateReg == IBV_QPS_RESET;
    method Bool isRTR()    = stateReg == IBV_QPS_RTR;
    method Bool isRTS()    = stateReg == IBV_QPS_RTS;
    method Bool isSQD()    = stateReg == IBV_QPS_SQD;

    method QpState getQPS() = stateReg;
    // method Action setQPS(QpState qps) if (inited);
    //     stateReg <= qps;
    // endmethod

    method Action setStateReset() if (inited && stateReg == IBV_QPS_ERR && errFlushDoneReg);
        stateReg <= IBV_QPS_RESET;
    endmethod
    // method Action setStateInit();
    method Action setStateRTR() if (inited && stateReg == IBV_QPS_INIT);
        stateReg <= IBV_QPS_RTR;
    endmethod
    method Action setStateRTS() if (inited && stateReg == IBV_QPS_RTR);
        stateReg <= IBV_QPS_RTS;
    endmethod
    method Action setStateSQD() if (inited && stateReg == IBV_QPS_RTS);
        stateReg <= IBV_QPS_SQD;
    endmethod
    method Action setStateErr() if (inited);
        stateReg <= IBV_QPS_ERR;
        errFlushDoneReg <= False;
    endmethod
    method Action errFlushDone if (inited && stateReg == IBV_QPS_ERR && !errFlushDoneReg);
        errFlushDoneReg <= True;
    endmethod

    method QpType getQpType() if (inited) = qpTypeReg;
    // method Action setQpType(QpType qpType);
    //     qpTypeReg <= qpType;
    // endmethod

    method RetryCnt      getMaxRnrCnt() if (inited) = maxRnrCntReg;
    method RetryCnt    getMaxRetryCnt() if (inited) = maxRetryCntReg;
    method TimeOutTimer getMaxTimeOut() if (inited) = maxTimeOutReg;
    method RnrTimer    getMinRnrTimer() if (inited) = minRnrTimerReg;

    method PendingReqCnt getPendingWorkReqNum() if (inited) = pendingWorkReqNumReg;
    // method Action setPendingWorkReqNum(PendingReqCnt cnt);
    //     pendingWorkReqNumReg <= cnt;
    // endmethod
    method PendingReqCnt getPendingRecvReqNum() if (inited) = pendingRecvReqNumReg;
    // method Action setPendingRecvReqNum(PendingReqCnt cnt);
    //     pendingRecvReqNumReg <= cnt;
    // endmethod

    method Bool getSigAll() if (inited) = sqSigAllReg;
    // method Action setSigAll(Bool sqSigAll);
    //     sqSigAllReg <= sqSigAll;
    // endmethod

    method PSN getSQPN() if (inited) = sqpnReg;
    // method Action setSQPN(PSN sqpn);
    //     sqpnReg <= sqpn;
    // endmethod
    method PSN getDQPN() if (inited) = dqpnReg;
    // method Action setDQPN(PSN dqpn);
    //     dqpnReg <= dqpn;
    // endmethod

    method PKEY getPKEY() if (inited) = pkeyReg;
    // method Action setPKEY(PKEY pkey);
    //     pkeyReg <= pkey;
    // endmethod
    method QKEY getQKEY() if (inited) = qkeyReg;
    // method Action setQKEY(QKEY qkey);
    //     qkeyReg <= qkey;
    // endmethod
    method PMTU getPMTU() if (inited) = pmtuReg;
    // method Action setPMTU(PMTU pmtu);
    //     pmtuReg <= pmtu;
    // endmethod
    method PSN getNPSN() if (inited) = npsnReg;
    method Action setNPSN(PSN psn);
        npsnReg <= psn;
    endmethod

    interface srvPort = toGPServer(reqQ, respQ);

    interface contextRQ = interface ContextRQ;
        method PermCheckInfo getPermCheckInfo() if (inited) = permCheckInfoReg;
        method Action        setPermCheckInfo(PermCheckInfo permCheckInfo) if (inited);
            permCheckInfoReg <= permCheckInfo;
        endmethod

        method Length getTotalDmaWriteLen() if (inited) = totalDmaWriteLenReg;
        method Action setTotalDmaWriteLen(Length totalDmaWriteLen) if (inited);
            totalDmaWriteLenReg <= totalDmaWriteLen;
        endmethod

        method Length getRemainingDmaWriteLen() if (inited) = remainingDmaWriteLenReg;
        method Action setRemainingDmaWriteLen(Length remainingDmaWriteLen) if (inited);
            remainingDmaWriteLenReg <= remainingDmaWriteLen;
        endmethod

        method ADDR   getNextDmaWriteAddr() if (inited) = nextDmaWriteAddrReg;
        method Action setNextDmaWriteAddr(ADDR nextDmaWriteAddr) if (inited);
            nextDmaWriteAddrReg <= nextDmaWriteAddr;
        endmethod

        method PktNum getSendWriteReqPktNum() if (inited) = sendWriteReqPktNumReg;
        method Action setSendWriteReqPktNum(PktNum sendWriteReqPktNum) if (inited);
            sendWriteReqPktNumReg <= sendWriteReqPktNum;
        endmethod

        method RdmaOpCode getPreReqOpCode() if (inited) = preReqOpCodeReg[0];
        method Action     setPreReqOpCode(RdmaOpCode preOpCode) if (inited);
            preReqOpCodeReg[0] <= preOpCode;
        endmethod
        method Action     restorePreReqOpCode(RdmaOpCode preOpCode) if (inited);
            preReqOpCodeReg[1] <= preOpCode;
        endmethod

        method Epoch  getEpoch() if (inited) = epochReg;
        method Action incEpoch() if (inited);
            epochReg <= ~epochReg;
        endmethod

        method MSN    getMSN() if (inited) = msnReg;
        method Action setMSN(MSN msn) if (inited);
            msnReg <= msn;
        endmethod

        method PktNum getRespPktNum() if (inited) = respPktNumReg;
        method Action setRespPktNum(PktNum respPktNum) if (inited);
            respPktNumReg <= respPktNum;
        endmethod

        method PSN    getCurRespPSN() if (inited) = curRespPsnReg;
        method Action setCurRespPsn(PSN curRespPsn) if (inited);
            curRespPsnReg <= curRespPsn;
        endmethod

        method PSN    getEPSN() if (inited) = epsnReg[0];
        method Action setEPSN(PSN psn) if (inited);
            epsnReg[0] <= psn;
        endmethod
        method Action restoreEPSN(PSN psn) if (inited);
            epsnReg[1] <= psn;
        endmethod
    endinterface;
endmodule
