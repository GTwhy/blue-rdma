import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

interface RetryHandleSQ;
    method Bool hasRetryErr();
    method Bool isRetryDone();
    method Bool retryBegin();
    method Action resetRetryCntBySQ();
    method Action resetTimeOutBySQ();
    method Action notifyRetryFromSQ(
        WorkReqID        wrID,
        PSN              retryStartPSN,
        RetryReason      retryReason,
        Maybe#(RnrTimer) retryRnrTimer
    );
    interface PipeOut#(PendingWorkReq) retryWorkReqPipeOut;
endinterface

typedef enum {
    RETRY_ST_RNR_CHECK,
    RETRY_ST_RNR_WAIT,
    RETRY_ST_PARTIAL_RETRY_WR,
    RETRY_ST_FULL_RETRY_WR,
    RETRY_ST_RETRY_LIMIT_EXC,
    RETRY_ST_NOT_RETRY
} RetryHandleState deriving(Bits, Eq);

// TODO: handle RNR waiting
// TODO: implement timeout retry
module mkRetryHandleSQ#(
    Controller cntrl,
    ScanIfc#(PendingWorkReq) pendingWorkReqScan
)(RetryHandleSQ);
    FIFOF#(PendingWorkReq) retryPendingWorkReqOutQ <- mkFIFOF;

    Reg#(RnrWaitCycleCnt) rnrWaitCntReg <- mkRegU;
    Reg#(TimeOutCycleCnt) timeOutCntReg <- mkRegU;
    Reg#(Bool)        disableTimeOutReg <- mkRegU;

    Reg#(Bool) resetRetryCntReg[2] <- mkCReg(2, False);
    Reg#(Bool)  resetTimeOutReg[2] <- mkCReg(2, False);

    Reg#(Bool) hasNotifiedRetryReg[2] <- mkCReg(2, False);
    Reg#(Bool)  hasTimeOutRetryReg[2] <- mkCReg(2, False);

    Reg#(WorkReqID) retryWorkReqIdReg <- mkRegU;
    Reg#(PSN)        retryStartPsnReg <- mkRegU;
    Reg#(PSN)              psnDiffReg <- mkRegU;
    Reg#(RetryReason)  retryReasonReg <- mkRegU;
    Reg#(RnrTimer)   retryRnrTimerReg <- mkRegU;
    Reg#(RetryCnt)          rnrCntReg <- mkRegU;
    Reg#(RetryCnt)        retryCntReg <- mkRegU;

    Reg#(RetryHandleState) retryHandleStateReg <- mkReg(RETRY_ST_NOT_RETRY);

    let notRetrying = retryHandleStateReg == RETRY_ST_NOT_RETRY;
    let retryErr    = retryHandleStateReg == RETRY_ST_RETRY_LIMIT_EXC;
    let retryPendingWorkReqPipeOut = convertFifo2PipeOut(retryPendingWorkReqOutQ);

    function Bool retryCntExceedLimit(RetryReason retryReason);
        return case (retryReason)
            RETRY_REASON_RNR      : isZero(rnrCntReg);
            RETRY_REASON_SEQ_ERR  ,
            RETRY_REASON_IMPLICIT ,
            RETRY_REASON_TIME_OUT : isZero(retryCntReg);
            // RETRY_REASON_NOT_RETRY
            default               : False;
        endcase;
    endfunction

    function Action decRetryCnt(RetryReason retryReason);
        action
            case (retryReason)
                RETRY_REASON_SEQ_ERR, RETRY_REASON_IMPLICIT, RETRY_REASON_TIME_OUT: begin
                    if (cntrl.getMaxRetryCnt != fromInteger(valueOf(INFINITE_RETRY))) begin
                        if (!isZero(retryCntReg)) begin
                            retryCntReg <= retryCntReg - 1;
                        end
                    end
                end
                RETRY_REASON_RNR: begin
                    if (cntrl.getMaxRnrCnt != fromInteger(valueOf(INFINITE_RETRY))) begin
                        if (!isZero(rnrCntReg)) begin
                            rnrCntReg <= rnrCntReg - 1;
                        end
                    end
                end
                default: begin end
            endcase
        endaction
    endfunction

    function Action resetRetryCntInternal();
        action
            retryCntReg <= cntrl.getMaxRetryCnt;
            rnrCntReg   <= cntrl.getMaxRnrCnt;
        endaction
    endfunction

    function Action resetTimeOutInternal();
        action
            timeOutCntReg <= fromInteger(getTimeOutValue(cntrl.getMaxTimeOut));
            disableTimeOutReg <= isZero(cntrl.getMaxTimeOut);
            // $display("time=%0d: cntrl.getMaxTimeOut=%0d", $time, cntrl.getMaxTimeOut);
        endaction
    endfunction

    rule resetRetryCntAndTimeOutTimer if (cntrl.isRTR);
        resetRetryCntInternal;
        resetTimeOutInternal;
    endrule

    rule decTimeOutTimer if (cntrl.isRTS && notRetrying && !retryErr);
        if (resetTimeOutReg[1]) begin
            resetTimeOutInternal;
        end
        else if (!disableTimeOutReg && !hasTimeOutRetryReg[0]) begin
            if (isZero(timeOutCntReg)) begin
                hasTimeOutRetryReg[0] <= True;
                resetTimeOutInternal;
            end
            else begin
                timeOutCntReg <= timeOutCntReg - 1;
            end
        end
    endrule

    rule recvRetryReq if (cntrl.isRTS && notRetrying && !retryErr);
        if (resetRetryCntReg[1]) begin
            resetRetryCntInternal;
        end
        else if (hasNotifiedRetryReg[1] || hasTimeOutRetryReg[1]) begin
            if (
                retryCntExceedLimit(retryReasonReg) ||
                retryCntExceedLimit(RETRY_REASON_TIME_OUT)
            ) begin
                retryHandleStateReg <= RETRY_ST_RETRY_LIMIT_EXC;
            end
            else begin
                retryHandleStateReg <= RETRY_ST_RNR_CHECK;
                pendingWorkReqScan.scanStart;

                // If both notified retry and timeout retry,
                // the notified retry has priority.
                if (hasNotifiedRetryReg[1]) begin
                    decRetryCnt(retryReasonReg);
                end
                else if (hasTimeOutRetryReg[1]) begin
                    decRetryCnt(RETRY_REASON_TIME_OUT);
                    retryReasonReg <= RETRY_REASON_TIME_OUT;
                end
            end
        end
    endrule

    rule rnrCheck if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_RNR_CHECK);
        let curRetryWR = pendingWorkReqScan.current;
        if (retryReasonReg != RETRY_REASON_TIME_OUT) begin
            dynAssert(
                retryWorkReqIdReg == curRetryWR.wr.id,
                "retryWorkReqIdReg assertion @ mkRespHandleSQ",
                $format(
                    "retryWorkReqIdReg=%h should == curRetryWR.wr.id=%h",
                    retryWorkReqIdReg, curRetryWR.wr.id
                )
            );
        end

        // Clear retry notification
        hasNotifiedRetryReg[0] <= False;
        hasTimeOutRetryReg[0] <= False;

        let startPSN = unwrapMaybe(curRetryWR.startPSN);
        let wrLen    = curRetryWR.wr.len;
        let laddr    = curRetryWR.wr.laddr;
        let raddr    = curRetryWR.wr.raddr;
        psnDiffReg  <= calcPsnDiff(retryStartPsnReg, startPSN);

        let rnrTimer = cntrl.getMinRnrTimer;
        if (retryReasonReg == RETRY_REASON_RNR) begin
            rnrTimer = retryRnrTimerReg > rnrTimer ? retryRnrTimerReg : rnrTimer;
            rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(rnrTimer));
            retryHandleStateReg <= RETRY_ST_RNR_WAIT;
        end
        else begin
            retryHandleStateReg <= RETRY_ST_PARTIAL_RETRY_WR;
        end
    endrule

    rule rnrWait if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_RNR_WAIT);
        if (isZero(rnrWaitCntReg)) begin
            retryHandleStateReg <= RETRY_ST_PARTIAL_RETRY_WR;
        end
        else begin
            rnrWaitCntReg <= rnrWaitCntReg - 1;
        end
    endrule

    rule partialRetryWR if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_PARTIAL_RETRY_WR);
        let curRetryWR = pendingWorkReqScan.current;
        pendingWorkReqScan.scanNext;

        let wrLen    = curRetryWR.wr.len;
        let laddr    = curRetryWR.wr.laddr;
        let raddr    = curRetryWR.wr.raddr;
        let retryWorkReqLen = lenSubtractPsnMultiplyPMTU(wrLen, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqLocalAddr = addrAddPsnMultiplyPMTU(laddr, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqRmtAddr = addrAddPsnMultiplyPMTU(raddr, psnDiffReg, cntrl.getPMTU);
        curRetryWR.startPSN = tagged Valid retryStartPsnReg;
        curRetryWR.wr.len = retryWorkReqLen;
        curRetryWR.wr.laddr = retryWorkReqLocalAddr;
        curRetryWR.wr.raddr = retryWorkReqRmtAddr;

        retryPendingWorkReqOutQ.enq(curRetryWR);
        retryHandleStateReg <= RETRY_ST_FULL_RETRY_WR;
    endrule

    rule fullRetryWR if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_FULL_RETRY_WR);
        if (pendingWorkReqScan.scanDone) begin
            retryHandleStateReg <= RETRY_ST_NOT_RETRY;
        end
        else begin
            let curRetryWR = pendingWorkReqScan.current;
            pendingWorkReqScan.scanNext;
            retryPendingWorkReqOutQ.enq(curRetryWR);
        end
    endrule

    method Bool hasRetryErr() = retryErr;
    method Bool isRetryDone() = retryHandleStateReg == RETRY_ST_NOT_RETRY;
    method Bool  retryBegin() = retryHandleStateReg == RETRY_ST_PARTIAL_RETRY_WR;

    method Action resetRetryCntBySQ() if (cntrl.isRTS && notRetrying);
        resetRetryCntReg[0] <= True;
    endmethod
    method Action resetTimeOutBySQ() if (cntrl.isRTS);
        resetTimeOutReg[0] <= True;
    endmethod

    method Action notifyRetryFromSQ(
        WorkReqID        wrID,
        PSN              retryStartPSN,
        RetryReason      retryReason,
        Maybe#(RnrTimer) retryRnrTimer
    ) if (cntrl.isRTS && notRetrying && !hasNotifiedRetryReg[0]);
        hasNotifiedRetryReg[0] <= True;

        retryWorkReqIdReg   <= wrID;
        retryStartPsnReg    <= retryStartPSN;
        retryReasonReg      <= retryReason;

        if (retryReason == RETRY_REASON_RNR) begin
            dynAssert(
                isValid(retryRnrTimer),
                "retryRnrTimer assertion @ mkRetryHandleSQ",
                $format(
                    "retryRnrTimer=", fshow(retryRnrTimer),
                    " should be valid when retryReason=",
                    fshow(retryReason)
                )
            );
            retryRnrTimerReg <= unwrapMaybe(retryRnrTimer);
        end
    endmethod

    interface retryWorkReqPipeOut = retryPendingWorkReqPipeOut;
endmodule
