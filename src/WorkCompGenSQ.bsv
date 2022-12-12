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

function Maybe#(WorkComp) genWorkComp4WorkReq(
    Controller cntrl, WorkCompGenReqSQ wcGenReqSQ
);
    let wr = wcGenReqSQ.pendingWR.wr;
    let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);
    // TODO: how to set WC flags in SQ?
    // let wcFlags = workReqOpCode2WorkCompFlags(wr.opcode);
    let wcFlags = IBV_WC_NO_FLAGS;

    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let workComp = WorkComp {
            id      : wr.id,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcGenReqSQ.wcStatus,
            len     : wr.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : tagged Invalid,
            rkey2Inv: tagged Invalid
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(WorkComp) genErrFlushWorkComp4WorkReq(
    Controller cntrl, WorkReq wr
);
    let maybeWorkCompOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);

    if (maybeWorkCompOpCode matches tagged Valid .opcode) begin
        let workComp = WorkComp {
            id      : wr.id,
            opcode  : opcode,
            flags   : IBV_WC_NO_FLAGS,
            status  : IBV_WC_WR_FLUSH_ERR,
            len     : wr.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
            immDt   : tagged Invalid,
            rkey2Inv: tagged Invalid
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

typedef enum {
    WC_GEN_ST_STOP,
    WC_GEN_ST_NORMAL,
    WC_GEN_ST_ERR_FLUSH
} WorkCompGenState deriving(Bits, Eq);

module mkWorkCompGenSQ#(
    Controller cntrl,
    PipeOut#(PayloadConResp) payloadConRespPipeIn,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromReqGenInSQ,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromRespHandleInSQ,
    PipeOut#(WorkComp) workCompPipeInFromRQ
)(PipeOut#(WorkComp));
    FIFOF#(WorkComp) workCompOutQ4SQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkComp) workCompOutQ4RQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ4SQ <- mkSizedFIFOF(valueOf(MAX_PENDING_WORK_COMP_NUM));

    PulseWire hasErrWorkCompRQPulse <- mkPulseWire;
    Reg#(WorkCompGenState) workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);

    function ActionValue#(Bool) submitWorkCompUntilFirstErr(
        Bool wcWaitDmaResp,
        Bool needWorkCompWhenNormal,
        WorkCompReqType wcReqType,
        PSN dmaWriteRespMatchPSN,
        Maybe#(WorkComp) maybeWorkComp,
        FIFOF#(WorkComp) workCompOutQ
    );
        actionvalue
            dynAssert(
                isValid(maybeWorkComp),
                "maybeWorkComp assertion @ mkWorkCompGenSQ",
                $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
            );
            let workComp = unwrapMaybe(maybeWorkComp);
            let isWorkCompSuccess = workComp.status == IBV_WC_SUCCESS;
            let isCompQueueFull = False;

            if (isWorkCompSuccess) begin
                if (wcWaitDmaResp) begin
                    // TODO: report error if waiting too long for DMA write response
                    let payloadConsumeResp = payloadConRespPipeIn.first;
                    payloadConRespPipeIn.deq;
                    dynAssert (
                        payloadConsumeResp.dmaWriteResp.psn == dmaWriteRespMatchPSN,
                        "dmaWriteRespMatchPSN assertion @ mkWorkCompGenSQ",
                        $format(
                            "payloadConsumeResp.dmaWriteResp.psn=%h should == dmaWriteRespMatchPSN=%h",
                            payloadConsumeResp.dmaWriteResp.psn, dmaWriteRespMatchPSN
                        )
                    );
                    // $display(
                    //     "time=%0d: payloadConsumeResp=", $time, fshow(payloadConsumeResp),
                    //     ", needWorkCompWhenNormal=", fshow(needWorkCompWhenNormal)
                    // );

                    if (needWorkCompWhenNormal) begin
                        if (workCompOutQ.notFull) begin
                            workCompOutQ.enq(workComp);
                        end
                        else begin
                            isCompQueueFull = True;
                        end
                    end
                end
                else begin
                    if (needWorkCompWhenNormal) begin
                        if (workCompOutQ.notFull) begin
                            workCompOutQ.enq(workComp);
                        end
                        else begin
                            isCompQueueFull = True;
                        end
                    end
                end
            end
            else begin
                if (workCompOutQ.notFull) begin
                    workCompOutQ.enq(workComp);
                end
                else begin
                    isCompQueueFull = True;
                end
            end

            return !isWorkCompSuccess || isCompQueueFull;
        endactionvalue
    endfunction

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule start if (cntrl.isRTS && workCompGenStateReg == WC_GEN_ST_STOP);
        workCompGenStateReg <= WC_GEN_ST_NORMAL;
    endrule

    rule recvWorkCompGenReqSQ if (
        workCompGenStateReg == WC_GEN_ST_NORMAL ||
        workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        if (wcGenReqPipeInFromReqGenInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromReqGenInSQ.first;
            wcGenReqPipeInFromReqGenInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);
        end
        else if (wcGenReqPipeInFromRespHandleInSQ.notEmpty) begin
            let wcGenReqSQ = wcGenReqPipeInFromRespHandleInSQ.first;
            wcGenReqPipeInFromRespHandleInSQ.deq;
            pendingWorkCompQ4SQ.enq(wcGenReqSQ);

            // $display(
            //     "time=%0d: wcGenReqPipeInFromRespHandleInSQ.notEmpty=",
            //     $time, fshow(wcGenReqPipeInFromRespHandleInSQ.notEmpty),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    rule recvWorkCompRQ if (workCompGenStateReg == WC_GEN_ST_NORMAL);
        let wcRQ = workCompPipeInFromRQ.first;
        workCompPipeInFromRQ.deq;

        if (wcRQ.status != IBV_WC_SUCCESS) begin
            hasErrWorkCompRQPulse.send;
        end
        workCompOutQ4RQ.enq(wcRQ);
    endrule

    rule flushWorkCompRQ if (workCompGenStateReg == WC_GEN_ST_ERR_FLUSH);
        let wcRQ = workCompPipeInFromRQ.first;
        workCompPipeInFromRQ.deq;

        wcRQ.status = IBV_WC_WR_FLUSH_ERR;
        workCompOutQ4RQ.enq(wcRQ);
    endrule

    rule genWorkCompNormalCase if (cntrl.isRTS && workCompGenStateReg == WC_GEN_ST_NORMAL);
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;
        pendingWorkCompQ4SQ.deq;

        let maybeWorkComp = genWorkComp4WorkReq(cntrl, wcGenReqSQ);
        let needWorkCompWhenNormal =
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_SUC_FULL_ACK &&
            (workReqNeedWorkComp(wcGenReqSQ.pendingWR.wr) || cntrl.getSigAll);

        let hasErrWorkCompOrCompQueueFullSQ <- submitWorkCompUntilFirstErr(
            wcGenReqSQ.wcWaitDmaResp,
            needWorkCompWhenNormal,
            wcGenReqSQ.wcReqType,
            wcGenReqSQ.triggerPSN,
            maybeWorkComp,
            workCompOutQ4SQ
        );

        if (hasErrWorkCompOrCompQueueFullSQ || hasErrWorkCompRQPulse) begin
            cntrl.setStateErr;
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;

            // $display(
            //     "time=%0d: hasErrWorkCompOrCompQueueFullSQ=",
            //     $time, fshow(hasErrWorkCompOrCompQueueFullSQ),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    rule errFlushPendingWorkCompGenReqSQ if (
        // cntrl.isERR &&
        workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;
        pendingWorkCompQ4SQ.deq;

        let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, wcGenReqSQ.pendingWR.wr);
        dynAssert(
            isValid(maybeErrFlushWC),
            "maybeErrFlushWC assertion @ mkWorkCompGenSQ",
            $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
        );
        let errFlushWC = unwrapMaybe(maybeErrFlushWC);

        if (
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_SUC_FULL_ACK ||
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_ERR_FULL_ACK
        ) begin
            if (workCompOutQ4SQ.notFull) begin
                workCompOutQ4SQ.enq(errFlushWC);
            end
        end

        $display(
            "time=%0d: flush pendingWorkCompQ4SQ, errFlushWC=",
            $time, fshow(errFlushWC)
        );
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule errFlushWorkReqSQ if (
        cntrl.isERR && !pendingWorkCompQ4SQ.notEmpty
    );
        if (pendingWorkReqPipeIn.notEmpty) begin
            let pendingWR = pendingWorkReqPipeIn.first;
            pendingWorkReqPipeIn.deq;

            let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, pendingWR.wr);
            dynAssert(
                isValid(maybeErrFlushWC),
                "maybeErrFlushWC assertion @ mkWorkCompGenSQ",
                $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
            );

            let errFlushWC = unwrapMaybe(maybeErrFlushWC);
            if (workCompOutQ4SQ.notFull) begin
                workCompOutQ4SQ.enq(errFlushWC);
            end

            // $display("time=%0d: flush pendingWorkReqBuf, errFlushWR=", $time, fshow(errFlushWC));
        end
        else begin
            // Notify controller when flush done
            cntrl.errFlushDone;
            // $display(
            //     "time=%0d: error flush done, pendingWorkReqBuf.count=%0d",
            //     $time, pendingWorkReqBuf.count
            // );
        end
    endrule

    return convertFifo2PipeOut(workCompOutQ4SQ);
endmodule
