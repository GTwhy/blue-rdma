import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;

typedef Bit#(1) Epoch;

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
    method PSN           getCurRespPsn();
    method Action        setCurRespPsn(PSN curRespPsn);
    method PSN           getEPSN();
    method Action        setEPSN(PSN psn);
    method Action        restoreEPSN(PSN psn);
endinterface

interface Controller;
    interface ContextRQ contextRQ;

    method Action initialize(
        QpType                  qpType,
        RetryCnt                maxRnrCnt,
        RetryCnt                maxRetryCnt,
        TimeOutTimer            maxTimeOut,
        RnrTimer                minRnrTimer,
        PendingReqCnt           pendingWorkReqNum,
        PendingReqCnt           pendingRecvReqNum,
        PendingReadAtomicReqCnt pendingReadAtomicReqNum,
        Bool                    sigAll,
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
    Reg#(QpState) stateReg <- mkReg(IBV_QPS_RESET);
    Reg#(QpType) qpTypeReg <- mkRegU;

    Reg#(RetryCnt)      maxRnrCntReg <- mkRegU;
    Reg#(RetryCnt)    maxRetryCntReg <- mkRegU;
    Reg#(TimeOutTimer) maxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    minRnrTimerReg <- mkRegU;

    Reg#(Bool)        errFlushDoneReg <- mkRegU;

    Reg#(PendingReqCnt) pendingWorkReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingRecvReqNumReg <- mkRegU;
    Reg#(PendingReadAtomicReqCnt) pendingReadAtomicReqNumReg <- mkRegU;

    Reg#(Bool) sigAllReg <- mkRegU;
    Reg#(QPN) sqpnReg <- mkRegU;
    Reg#(QPN) dqpnReg <- mkRegU;

    Reg#(PKEY) pkeyReg <- mkRegU;
    Reg#(QKEY) qkeyReg <- mkRegU;
    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;

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

    method Action initialize(
        QpType                  qpType,
        RetryCnt                maxRnrCnt,
        RetryCnt                maxRetryCnt,
        TimeOutTimer            maxTimeOut,
        RnrTimer                minRnrTimer,
        PendingReqCnt           pendingWorkReqNum,
        PendingReqCnt           pendingRecvReqNum,
        PendingReadAtomicReqCnt pendingReadAtomicReqNum,
        Bool                    sigAll,
        QPN                     sqpn,
        QPN                     dqpn,
        PKEY                    pkey,
        QKEY                    qkey,
        PMTU                    pmtu,
        PSN                     npsn,
        PSN                     epsn
    ) if (!inited);
        stateReg                   <= IBV_QPS_INIT;

        qpTypeReg                  <= qpType;
        maxRnrCntReg               <= maxRnrCnt;
        maxRetryCntReg             <= maxRetryCnt;
        maxTimeOutReg              <= maxTimeOut;
        minRnrTimerReg             <= minRnrTimer;
        errFlushDoneReg            <= True;
        pendingWorkReqNumReg       <= pendingWorkReqNum;
        pendingRecvReqNumReg       <= pendingRecvReqNum;
        pendingReadAtomicReqNumReg <= pendingReadAtomicReqNum;
        sigAllReg                  <= sigAll;
        sqpnReg                    <= sqpn;
        dqpnReg                    <= dqpn;
        pkeyReg                    <= pkey;
        qkeyReg                    <= qkey;
        pmtuReg                    <= pmtu;
        npsnReg                    <= npsn;
        epsnReg[0]                 <= epsn;
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

    method Bool getSigAll() if (inited) = sigAllReg;
    // method Action setSigAll(Bool sigAll);
    //     sigAllReg <= sigAll;
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

        method PSN    getCurRespPsn() if (inited) = curRespPsnReg;
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
