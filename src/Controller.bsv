import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import Utils :: *;

interface Controller;
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
    method Bool isRTRorRTSorSQD();
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
    method PSN getEPSN();
    method Action incEPSN();
    method Action setEPSN(PSN psn);
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

    Reg#(PSN) epsnReg[2] <- mkCRegU(2);

    Bool inited = stateReg != IBV_QPS_RESET;

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

    method Bool isERR()           = stateReg == IBV_QPS_ERR;
    method Bool isInit()          = stateReg == IBV_QPS_INIT;
    method Bool isReset()         = stateReg == IBV_QPS_RESET;
    method Bool isRTR()           = stateReg == IBV_QPS_RTR;
    method Bool isRTS()           = stateReg == IBV_QPS_RTS;
    method Bool isRTRorRTSorSQD() = stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS || stateReg == IBV_QPS_SQD;
    method Bool isSQD()           = stateReg == IBV_QPS_SQD;

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
    method    PSN getEPSN() if (inited) = epsnReg[0];
    method Action incEPSN() if (inited);
        epsnReg[0] <= epsnReg[0] + 1;
    endmethod
    method Action setEPSN(PSN psn) if (inited);
        epsnReg[1] <= psn;
    endmethod
endmodule
