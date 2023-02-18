import FIFOF :: *;
import PAClib :: *;

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
    method Bool isRetrying();
    method Action resetRetryCntBySQ();
    method Action resetTimeOutBySQ();
    method Action notifyRetryFromSQ(
        WorkReqID        wrID,
        PSN              retryStartPSN,
        RetryReason      retryReason,
        Maybe#(RnrTimer) retryRnrTimer
    );
endinterface

typedef enum {
    RETRY_ST_NOT_RETRY,
    RETRY_ST_START_PRE_RETRY,
    RETRY_ST_RNR_CHECK,
    RETRY_ST_RNR_WAIT,
    RETRY_ST_MODIFY_PARTIAL_RETRY_WR,
    RETRY_ST_START_RETRY,
    RETRY_ST_WAIT_RETRY_DONE,
    RETRY_ST_RETRY_LIMIT_EXC
} RetryHandleState deriving(Bits, Eq, FShow);

module mkRetryHandleSQ#(
    Controller cntrl,
    Bool pendingWorkReqNotEmpty,
    ScanCntrlIfc#(PendingWorkReq) pendingWorkReqScanCntrl
)(RetryHandleSQ);
    Reg#(RnrWaitCycleCnt) rnrWaitCntReg <- mkRegU;
    Reg#(TimeOutCycleCnt) timeOutCntReg <- mkRegU;
    Reg#(Bool)        disableTimeOutReg <- mkRegU;
    Reg#(Bool)       disableRetryCntReg <- mkRegU;

    Reg#(Bool) resetRetryCntReg[2] <- mkCReg(2, False);
    Reg#(Bool)  resetTimeOutReg[2] <- mkCReg(2, False);

    Reg#(Bool) hasNotifiedRetryReg[2] <- mkCReg(2, False);

    Reg#(RetryReason) retryReasonReg[2] <- mkCRegU(2);
    Reg#(WorkReqID)   retryWorkReqIdReg <- mkRegU;
    Reg#(PSN)          retryStartPsnReg <- mkRegU;
    Reg#(PSN)                psnDiffReg <- mkRegU;
    Reg#(RnrTimer)     retryRnrTimerReg <- mkRegU;
    Reg#(RetryCnt)          retryCntReg <- mkRegU;
    Reg#(RetryCnt)            rnrCntReg <- mkRegU;

    Reg#(RetryCnt)    origMaxRetryCntReg <- mkRegU;
    Reg#(RetryCnt)      origMaxRnrCntReg <- mkRegU;
    Reg#(TimeOutTimer) origMaxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    origMinRnrTimerReg <- mkRegU;

    Reg#(RetryHandleState) retryHandleStateReg[2] <- mkCReg(2, RETRY_ST_NOT_RETRY);

    let notRetrying = retryHandleStateReg[0] == RETRY_ST_NOT_RETRY;
    let retryErr    = retryHandleStateReg[0] == RETRY_ST_RETRY_LIMIT_EXC;
    // Retry restart conflicts with partial retry state
    let retryingWR  = retryHandleStateReg[0] == RETRY_ST_WAIT_RETRY_DONE;

    function Bool retryCntExceedLimit(RetryReason retryReason);
        return case (retryReason)
            RETRY_REASON_RNR     : isZero(rnrCntReg);
            RETRY_REASON_SEQ_ERR ,
            RETRY_REASON_IMPLICIT,
            RETRY_REASON_TIMEOUT : isZero(retryCntReg);
            // RETRY_REASON_NOT_RETRY
            default              : False;
        endcase;
    endfunction

    function Action decRetryCntByReason(RetryReason retryReason);
        action
            case (retryReason)
                RETRY_REASON_SEQ_ERR ,
                RETRY_REASON_IMPLICIT,
                RETRY_REASON_TIMEOUT : begin
                    if (!disableRetryCntReg) begin
                        if (!isZero(retryCntReg)) begin
                            retryCntReg <= retryCntReg - 1;
                        end
                    end
                end
                RETRY_REASON_RNR: begin
                    if (!disableRetryCntReg) begin
                        if (!isZero(rnrCntReg)) begin
                            rnrCntReg <= rnrCntReg - 1;
                        end
                    end
                end
                default: begin
                    immFail(
                        "unreachible case in decRetryCntByReason() @ mkRetryHandleSQ",
                        $format("retryReason=", fshow(retryReason))
                    );
                end
            endcase
        endaction
    endfunction

    function Action resetRetryCntInternal();
        action
            retryCntReg         <= origMaxRetryCntReg; // cntrl.getMaxRetryCnt
            rnrCntReg           <= origMaxRnrCntReg;   // cntrl.getMaxRnrCnt
            disableRetryCntReg  <= origMaxRetryCntReg == fromInteger(valueOf(INFINITE_RETRY));
            resetRetryCntReg[1] <= False;
        endaction
    endfunction

    function Action resetTimeOutInternal();
        action
            timeOutCntReg      <= fromInteger(getTimeOutValue(origMaxTimeOutReg));
            disableTimeOutReg  <= isZero(origMaxTimeOutReg); // cntrl.getMaxTimeOut
            resetTimeOutReg[1] <= False;
            // $display("time=%0t: cntrl.getMaxTimeOut=%0d", $time, origMaxTimeOutReg);
        endaction
    endfunction

    // TODO: update retry counter and timer during runtime
    rule initRetryCntAndTimeOutTimer if (cntrl.isInit);
        origMaxRetryCntReg <= cntrl.getMaxRetryCnt;
        origMaxRnrCntReg   <= cntrl.getMaxRnrCnt;
        origMinRnrTimerReg <= cntrl.getMinRnrTimer;
        origMaxTimeOutReg  <= cntrl.getMaxTimeOut;
    endrule

    rule resetRetryCntAndTimeOutTimer if (cntrl.isRTR);
        resetRetryCntInternal;
        resetTimeOutInternal;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize if (
        cntrl.isRTS && retryHandleStateReg[1] != RETRY_ST_RETRY_LIMIT_EXC
    );
        // hasNotifiedRetry has priority over hasTimeOutRetry
        let hasTimeOutRetry = False;
        if (resetTimeOutReg[1] || hasNotifiedRetryReg[1]) begin
            resetTimeOutInternal;
        end
        else if (
            !disableTimeOutReg     &&
            pendingWorkReqNotEmpty &&                    // Enable timeout when having pending WR
            retryHandleStateReg[1] == RETRY_ST_NOT_RETRY // Enable timeout when not retry
        ) begin
            if (isZero(timeOutCntReg)) begin
                hasTimeOutRetry = True;
                resetTimeOutInternal;
            end
            else begin
                timeOutCntReg <= timeOutCntReg - 1;
            end
        end

        if (resetRetryCntReg[1]) begin
            resetRetryCntInternal;
            // immAssert(
            //     resetTimeOutReg[1],
            //     "resetTimeOutReg assertion @ mkRetryHandleSQ",
            //     $format(
            //         "resetTimeOutReg[1]=", fshow(resetTimeOutReg[1]),
            //         " should be true when resetRetryCntReg[1]=", fshow(resetRetryCntReg[1])
            //     )
            // );
        end
        else if (hasNotifiedRetryReg[1] || hasTimeOutRetry) begin
            // if (hasNotifiedRetryReg[1]) begin
            //     immAssert(
            //         resetTimeOutReg[1],
            //         "resetTimeOutReg assertion @ mkRetryHandleSQ",
            //         $format(
            //             "resetTimeOutReg[1]=", fshow(resetTimeOutReg[1]),
            //             " should be true when hasNotifiedRetryReg[1]=", fshow(hasNotifiedRetryReg[1])
            //         )
            //     );
            // end

            let retryReason = hasNotifiedRetryReg[1] ?
                retryReasonReg[1] : RETRY_REASON_TIMEOUT;
            decRetryCntByReason(retryReason);
            retryReasonReg[1]      <= retryReason;
            retryHandleStateReg[1] <= RETRY_ST_START_PRE_RETRY;

            $display(
                "time=%0t: retry start in canonicalize", $time,
                ", hasNotifiedRetryReg[1]=", fshow(hasNotifiedRetryReg[1]),
                ", hasTimeOutRetry=", fshow(hasTimeOutRetry)
            );
        end

        hasNotifiedRetryReg[1] <= False;
        // $display(
        //     "time=%0t: canonicalize", $time,
        //     ", resetRetryCntReg[1]=", fshow(resetRetryCntReg[1]),
        //     ", hasNotifiedRetryReg[1]=", fshow(hasNotifiedRetryReg[1]),
        //     ", hasTimeOutRetry=", fshow(hasTimeOutRetry)
        // );
    endrule

    rule startPreRetry if (
        cntrl.isRTS &&
        retryHandleStateReg[0] == RETRY_ST_START_PRE_RETRY
    );
        let retryReason = retryReasonReg[0];
        if (retryCntExceedLimit(retryReason)) begin
            retryHandleStateReg[0] <= RETRY_ST_RETRY_LIMIT_EXC;

            // $display("time=%0t: retry error occured", $time);
        end
        else begin
            retryHandleStateReg[0] <= RETRY_ST_RNR_CHECK;

            if (pendingWorkReqScanCntrl.isScanDone) begin
                pendingWorkReqScanCntrl.preScanStart;
                // $display(
                //     "time=%0t: pendingWorkReqScanCntrl.preScanStart", $time,
                //     " pendingWorkReqNotEmpty=", fshow(pendingWorkReqNotEmpty)
                // );
            end
            else begin
                pendingWorkReqScanCntrl.preScanRestart;
                // $display(
                //     "time=%0t: pendingWorkReqScanCntrl.preScanRestart", $time,
                //     " pendingWorkReqNotEmpty=", fshow(pendingWorkReqNotEmpty)
                // );
            end
        end
        $display(
            "time=%0t: startPreRetry", $time,
            ", retryHandleStateReg=", fshow(retryHandleStateReg[0]),
            ", retryErr=", fshow(retryErr),
            ", retryReason=", fshow(retryReason)
        );
    endrule

    rule rnrCheck if (cntrl.isRTS && retryHandleStateReg[0] == RETRY_ST_RNR_CHECK);
        let firstRetryWR = pendingWorkReqScanCntrl.getHead;

        let startPSN = unwrapMaybe(firstRetryWR.startPSN);
        let endPSN   = unwrapMaybe(firstRetryWR.endPSN);
        let wrLen    = firstRetryWR.wr.len;
        let laddr    = firstRetryWR.wr.laddr;
        let raddr    = firstRetryWR.wr.raddr;

        immAssert(
            retryReasonReg[0] != RETRY_REASON_NOT_RETRY,
            "retryReasonReg assertion @ mkRespHandleSQ",
            $format(
                "retryReasonReg=", fshow(retryReasonReg[0]),
                " should not be RETRY_REASON_NOT_RETRY"
            )
        );

        let retryStartPSN = retryStartPsnReg;
        if (retryReasonReg[0] == RETRY_REASON_TIMEOUT) begin
            retryStartPSN = startPSN;
        end
        else begin
            immAssert(
                retryWorkReqIdReg == firstRetryWR.wr.id,
                "retryWorkReqIdReg assertion @ mkRespHandleSQ",
                $format(
                    "retryWorkReqIdReg=%h should == firstRetryWR.wr.id=%h",
                    retryWorkReqIdReg, firstRetryWR.wr.id
                )
            );
        end

        psnDiffReg  <= calcPsnDiff(retryStartPSN, startPSN);
        immAssert(
            retryStartPSN == startPSN ||
            retryStartPSN == endPSN   ||
            psnInRangeExclusive(retryStartPSN, startPSN, endPSN),
            "retryStartPSN assertion @ mkRetryHandleSQ",
            $format(
                "retryStartPSN=%h should between startPSN=%h and endPSN=%h inclusively",
                retryStartPSN, startPSN, endPSN
            )
        );

        let rnrTimer = origMinRnrTimerReg; // cntrl.getMinRnrTimer
        if (retryReasonReg[0] == RETRY_REASON_RNR) begin
            rnrTimer = retryRnrTimerReg > rnrTimer ? retryRnrTimerReg : rnrTimer;
            rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(rnrTimer));
            retryHandleStateReg[0] <= RETRY_ST_RNR_WAIT;

            // $display("time=%0t: retry next state is RNR wait", $time);
        end
        else begin
            retryHandleStateReg[0] <= RETRY_ST_MODIFY_PARTIAL_RETRY_WR;

            // $display("time=%0t: retry next state is partial retry WR", $time);
        end
        $display(
            "time=%0t: rnrCheck", $time,
            ", retryReasonReg=", fshow(retryReasonReg[0]),
            ", hasNotifiedRetryReg[0]=", fshow(hasNotifiedRetryReg[0])
        );
    endrule

    rule rnrWait if (cntrl.isRTS && retryHandleStateReg[0] == RETRY_ST_RNR_WAIT);
        if (isZero(rnrWaitCntReg)) begin
            retryHandleStateReg[0] <= RETRY_ST_MODIFY_PARTIAL_RETRY_WR;
        end
        else begin
            rnrWaitCntReg <= rnrWaitCntReg - 1;
        end

        $display(
            "time=%0t: retry rnrWait", $time,
            ", rnrWaitCntReg=%h", rnrWaitCntReg
        );
    endrule

    rule modifyPartialRetryWR if (cntrl.isRTS && retryHandleStateReg[0] == RETRY_ST_MODIFY_PARTIAL_RETRY_WR);
        let firstRetryWR = pendingWorkReqScanCntrl.getHead;
        // pendingWorkReqScanCntrl.next;

        let wrLen = firstRetryWR.wr.len;
        let laddr = firstRetryWR.wr.laddr;
        let raddr = firstRetryWR.wr.raddr;
        let retryWorkReqLen       = lenSubtractPsnMultiplyPMTU(wrLen, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqLocalAddr = addrAddPsnMultiplyPMTU(laddr, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqRmtAddr   = addrAddPsnMultiplyPMTU(raddr, psnDiffReg, cntrl.getPMTU);
        if (retryReasonReg[0] != RETRY_REASON_TIMEOUT) begin
            firstRetryWR.startPSN = tagged Valid retryStartPsnReg;
        end
        firstRetryWR.wr.len   = retryWorkReqLen;
        firstRetryWR.wr.laddr = retryWorkReqLocalAddr;
        firstRetryWR.wr.raddr = retryWorkReqRmtAddr;

        pendingWorkReqScanCntrl.modifyHead(firstRetryWR);
        retryHandleStateReg[0] <= RETRY_ST_START_RETRY;
        $display("time=%0t:", $time, " partial retry WR ID=%h", firstRetryWR.wr.id);
    endrule

    rule startRetry if (cntrl.isRTS && retryHandleStateReg[0] == RETRY_ST_START_RETRY);
        pendingWorkReqScanCntrl.scanStart;
        retryHandleStateReg[0] <= RETRY_ST_WAIT_RETRY_DONE;
    endrule

    rule waitRetryDone if (cntrl.isRTS && retryHandleStateReg[0] == RETRY_ST_WAIT_RETRY_DONE);
        if (pendingWorkReqScanCntrl.isScanDone) begin
            retryHandleStateReg[0] <= RETRY_ST_NOT_RETRY;

            $display(
                "time=%0t: retry done", $time,
                ", cntrl.isRTS=", fshow(cntrl.isRTS)
            );
        end
    endrule

    method Bool hasRetryErr() = retryErr;
    method Bool isRetryDone() = notRetrying;
    method Bool  isRetrying() = retryingWR;

    method Action resetRetryCntBySQ() if (cntrl.isRTS);
        resetRetryCntReg[0] <= True;
    endmethod
    method Action resetTimeOutBySQ() if (cntrl.isRTS);
        resetTimeOutReg[0] <= True;
    endmethod

    method Action notifyRetryFromSQ(
        WorkReqID        retryWorkReqID,
        PSN              retryStartPSN,
        RetryReason      retryReason,
        Maybe#(RnrTimer) retryRnrTimer
    ) if (cntrl.isRTS);
        hasNotifiedRetryReg[0] <= True;

        retryWorkReqIdReg <= retryWorkReqID;
        retryStartPsnReg  <= retryStartPSN;
        retryReasonReg[0] <= retryReason;

        if (retryReason == RETRY_REASON_RNR) begin
            immAssert(
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
endmodule
