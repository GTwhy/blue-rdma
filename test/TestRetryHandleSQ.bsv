import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

typedef enum {
    TEST_RETRY_TRIGGERED,
    TEST_RETRY_STARTED,
    TEST_RETRY_RESTART_TRIGGERED,
    TEST_RETRY_RESTART,
    TEST_RETRY_DONE
} TestRetryHandlerState deriving(Bits, Eq, FShow);

typedef enum {
    TEST_RETRY_CASE_SEQ_ERR,        // Partial retry
    TEST_RETRY_CASE_IMPLICIT_RETRY, // Full retry
    TEST_RETRY_CASE_RNR,            // Full retry
    TEST_RETRY_CASE_TIMEOUT,        // Full retry
    TEST_RETRY_CASE_NESTED_RETRY    // Partial retry
} TestRetryCase deriving(Bits, Eq);

(* synthesize *)
module mkTestRetryHandleSeqErrCase(Empty);
    let retryCase = TEST_RETRY_CASE_SEQ_ERR;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleImplicitRetryCase(Empty);
    let retryCase = TEST_RETRY_CASE_IMPLICIT_RETRY;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleRnrCase(Empty);
    let retryCase = TEST_RETRY_CASE_RNR;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleTimeOutCase(Empty);
    let retryCase = TEST_RETRY_CASE_TIMEOUT;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleNestedRetryCase(Empty);
    let retryCase = TEST_RETRY_CASE_NESTED_RETRY;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

module mkTestRetryHandleSQ#(TestRetryCase retryCase)(Empty);
    let minPayloadLen = 1024;
    let maxPayloadLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimController(qpType, pmtu);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4RetryWR <- mkBufferN(
        valueOf(MAX_QP_WR), existingPendingWorkReqPipeOutVec[1]
    );
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        pendingWorkReqPipeOut4PendingQ, pendingWorkReqBuf
    );

    // DUT
    let dut <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf.scanIfc);

    Reg#(Bool) isPartialRetryWorkReqReg <- mkRegU;
    Reg#(TestRetryHandlerState) retryHandleTestStateReg <- mkReg(TEST_RETRY_DONE);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function RetryReason testRetryCase2RetryReason(TestRetryCase retryCase);
        return case (retryCase)
            TEST_RETRY_CASE_SEQ_ERR       : RETRY_REASON_SEQ_ERR;
            TEST_RETRY_CASE_IMPLICIT_RETRY: RETRY_REASON_IMPLICIT;
            TEST_RETRY_CASE_RNR           : RETRY_REASON_RNR;
            TEST_RETRY_CASE_TIMEOUT       : RETRY_REASON_TIMEOUT;
            TEST_RETRY_CASE_NESTED_RETRY  : RETRY_REASON_SEQ_ERR;
            default                       : RETRY_REASON_NOT_RETRY;
        endcase;
    endfunction

    rule triggerRetry if (
        !pendingWorkReqBuf.fifoIfc.notFull && retryHandleTestStateReg == TEST_RETRY_DONE
    );
        let firstRetryWR = pendingWorkReqBuf.fifoIfc.first;
        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        let retryReason = testRetryCase2RetryReason(retryCase);
        let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
        // If partial retry, then retry from wrEndPSN
        let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
        let retryRnrTimer = retryCase == TEST_RETRY_CASE_RNR ?
            tagged Valid cntrl.getMinRnrTimer : tagged Invalid;

        if (retryCase != TEST_RETRY_CASE_TIMEOUT) begin
            dut.notifyRetryFromSQ(
                firstRetryWR.wr.id,
                retryStartPSN,
                retryReason,
                retryRnrTimer
            );
        end
        isPartialRetryWorkReqReg <= isPartialRetry;
        retryHandleTestStateReg <= TEST_RETRY_TRIGGERED;
        // $display("time=%0d: test retry triggered", $time);
    endrule

    rule retryWait4Start if (
        dut.isRetrying && retryHandleTestStateReg == TEST_RETRY_TRIGGERED
    );
        if (retryCase == TEST_RETRY_CASE_NESTED_RETRY) begin
            retryHandleTestStateReg <= TEST_RETRY_RESTART;
        end
        else begin
            retryHandleTestStateReg <= TEST_RETRY_STARTED;
        end
    endrule

    rule retryRestart if (
        dut.isRetrying && retryHandleTestStateReg == TEST_RETRY_RESTART
    );
        let firstRetryWR = dut.retryWorkReqPipeOut.first;
        dut.retryWorkReqPipeOut.deq;

        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        let retryReason = testRetryCase2RetryReason(retryCase);
        let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
        // If partial retry, then retry from wrEndPSN
        let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
        let retryRnrTimer = tagged Invalid;

        dut.notifyRetryFromSQ(
            firstRetryWR.wr.id,
            retryStartPSN,
            retryReason,
            retryRnrTimer
        );

        retryHandleTestStateReg <= TEST_RETRY_RESTART_TRIGGERED;
        // $display(
        //     "time=%0d: test retry restarted", $time,
        //     ", firstRetryWR.wr.id=%h", firstRetryWR.wr.id
        // );
    endrule

    rule retryWait4Restart if (
        dut.isRetrying && retryHandleTestStateReg == TEST_RETRY_RESTART_TRIGGERED
    );
        retryHandleTestStateReg <= TEST_RETRY_STARTED;
    endrule

    rule compare if (retryHandleTestStateReg == TEST_RETRY_STARTED);
        let retryWR = dut.retryWorkReqPipeOut.first;
        dut.retryWorkReqPipeOut.deq;

        let refRetryWR = pendingWorkReqPipeOut4RetryWR.first;
        pendingWorkReqPipeOut4RetryWR.deq;

        let startPSN = unwrapMaybe(retryWR.startPSN);
        let endPSN = unwrapMaybe(retryWR.endPSN);
        let refStartPSN = unwrapMaybe(refRetryWR.startPSN);
        let refEndPSN = unwrapMaybe(refRetryWR.endPSN);

        dynAssert(
            retryWR.wr.id == refRetryWR.wr.id,
            "retryWR ID assertion @ mkTestRetryHandleSQ",
            $format(
                "retryWR.wr.id=%h == refRetryWR.wr.id=%h",
                retryWR.wr.id, refRetryWR.wr.id,
                ", retryWR=", fshow(retryWR),
                ", refRetryWR=", fshow(refRetryWR)
            )
        );

        dynAssert(
            retryWR.wr.id == refRetryWR.wr.id,
            "retryWR ID assertion @ mkTestRetryHandleSQ",
            $format(
                "retryWR.wr.id=%h == refRetryWR.wr.id=%h",
                retryWR.wr.id, refRetryWR.wr.id,
                ", retryWR=", fshow(retryWR),
                ", refRetryWR=", fshow(refRetryWR)
            )
        );

        if (isPartialRetryWorkReqReg) begin
            dynAssert(
                startPSN == refEndPSN && endPSN == refEndPSN,
                "retryWR partial retry PSN assertion @ mkTestRetryHandleSQ",
                $format(
                    "startPSN=%h should == refEndPSN=%h",
                    startPSN, refEndPSN,
                    ", endPSN=%h should == refEndPSN=%h",
                    endPSN, refEndPSN,
                    ", when isPartialRetryWorkReqReg=",
                    fshow(isPartialRetryWorkReqReg)
                )
            );
            isPartialRetryWorkReqReg <= False;
        end
        else begin
            dynAssert(
                startPSN == refStartPSN && endPSN == refEndPSN,
                "retryWR PSN assertion @ mkTestRetryHandleSQ",
                $format(
                    "startPSN=%h should == refStartPSN=%h",
                    startPSN, refStartPSN,
                    ", endPSN=%h should == refEndPSN=%h",
                    endPSN, refEndPSN
                )
            );
        end

        countDown.decr;
        // $display(
        //     "time=%0d: compare", $time,
        //     " retryWR.wr.id=%h == refRetryWR.wr.id=%h",
        //     retryWR.wr.id, refRetryWR.wr.id,
        //     ", retryHandleTestStateReg=", fshow(retryHandleTestStateReg)
        //     // ", retryWR=", fshow(retryWR),
        //     // ", refRetryWR=", fshow(refRetryWR)
        // );
    endrule

    rule retryDone if (
        dut.isRetryDone && retryHandleTestStateReg == TEST_RETRY_STARTED
    );
        retryHandleTestStateReg <= TEST_RETRY_DONE;
        pendingWorkReqBuf.fifoIfc.clear;
        dut.resetRetryCntBySQ;
        dut.resetTimeOutBySQ;
        // $display("time=%0d: test retry done", $time);
    endrule
endmodule
