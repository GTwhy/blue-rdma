import FIFOF :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

// WC for SQ

function Maybe#(WorkComp) genWorkComp4WorkReq(
    Controller cntrl, WorkCompGenReqSQ wcGenReqSQ
);
    let wr = wcGenReqSQ.wr;
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
            dqpn    : cntrl.getSQPN,
            sqpn    : cntrl.getDQPN,
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
            dqpn    : cntrl.getSQPN,
            sqpn    : cntrl.getDQPN,
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
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromReqGenInSQ,
    PipeOut#(WorkCompGenReqSQ) wcGenReqPipeInFromRespHandleInSQ,
    PipeOut#(WorkCompStatus) workCompStatusPipeInFromRQ
)(PipeOut#(WorkComp));
    FIFOF#(WorkComp)             workCompOutQ4SQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkCompGenReqSQ) pendingWorkCompQ4SQ <- mkSizedFIFOF(valueOf(MAX_PENDING_WORK_COMP_NUM));

    PulseWire                    pulseHasErrFromRQ <- mkPulseWire;
    Reg#(WorkCompGenState)     workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);
    Reg#(Bool)      isFirstErrPartialAckWorkReqReg <- mkRegU;
    Reg#(WorkReqID) firstErrPartialAckWorkReqIdReg <- mkRegU;

    (* no_implicit_conditions, fire_when_enabled *)
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
            //     "time=%0t: wcGenReqPipeInFromRespHandleInSQ.notEmpty=",
            //     $time, fshow(wcGenReqPipeInFromRespHandleInSQ.notEmpty),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    rule recvWorkCompStatusRQ if (workCompGenStateReg == WC_GEN_ST_NORMAL);
        let wcStatusRQ = workCompStatusPipeInFromRQ.first;
        workCompStatusPipeInFromRQ.deq;

        if (wcStatusRQ != IBV_WC_SUCCESS) begin
            pulseHasErrFromRQ.send;
        end
    endrule

    rule genWorkCompNormalCase if (
        cntrl.isRTS && workCompGenStateReg == WC_GEN_ST_NORMAL
    );
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;
        pendingWorkCompQ4SQ.deq;

        let wcWaitDmaResp = wcGenReqSQ.wcWaitDmaResp;
        let wcReqType = wcGenReqSQ.wcReqType;
        let dmaWriteRespMatchPSN = wcGenReqSQ.triggerPSN;

        let maybeWorkComp = genWorkComp4WorkReq(cntrl, wcGenReqSQ);
        let needWorkCompWhenNormal =
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_FULL_ACK &&
            (workReqNeedWorkCompSQ(wcGenReqSQ.wr) || cntrl.getSigAll);

        immAssert(
            isValid(maybeWorkComp),
            "maybeWorkComp assertion @ mkWorkCompGenSQ",
            $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
        );
        let workComp          = unwrapMaybe(maybeWorkComp);
        let isWorkCompSuccess = workComp.status == IBV_WC_SUCCESS;
        // let isCompQueueFull   = False;

        // $display(
        //     "time=%0t: wcGenReqSQ=", $time, fshow(wcGenReqSQ),
        //     ", needWorkCompWhenNormal=", fshow(needWorkCompWhenNormal)
        // );

        if (isWorkCompSuccess) begin
            if (wcWaitDmaResp) begin
                // TODO: report error if waiting too long for DMA write response
                let payloadConResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;

                // TODO: better error handling
                let dmaRespPsnMatch = payloadConResp.dmaWriteResp.psn == wcGenReqSQ.triggerPSN;
                immAssert (
                    dmaRespPsnMatch,
                    "dmaWriteRespMatchPSN assertion @ mkWorkCompGenSQ",
                    $format(
                        "dmaRespPsnMatch=", fshow(dmaRespPsnMatch),
                        " should either be true, payloadConResp.dmaWriteResp.psn=%h should == wcGenReqSQ.triggerPSN=%h",
                        payloadConResp.dmaWriteResp.psn, wcGenReqSQ.triggerPSN
                    )
                );
            end

            if (needWorkCompWhenNormal) begin
                // if (workCompOutQ4SQ.notFull) begin
                workCompOutQ4SQ.enq(workComp);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
        end
        else begin
            // if (workCompOutQ4SQ.notFull) begin
            workCompOutQ4SQ.enq(workComp);
            // end
            // else begin
            //     isCompQueueFull = True;
            // end
        end

        // TODO: handle CQ full
        let hasErrWorkCompOrCompQueueFullSQ = !isWorkCompSuccess; // || isCompQueueFull;
        if (hasErrWorkCompOrCompQueueFullSQ || pulseHasErrFromRQ) begin
            cntrl.setStateErr;
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;
            isFirstErrPartialAckWorkReqReg <=
                wcGenReqSQ.wcReqType == WC_REQ_TYPE_PARTIAL_ACK;
            firstErrPartialAckWorkReqIdReg <= wcGenReqSQ.wr.id;
            // $display(
            //     "time=%0t: hasErrWorkCompOrCompQueueFullSQ=",
            //     $time, fshow(hasErrWorkCompOrCompQueueFullSQ),
            //     ", pulseHasErrFromRQ=", fshow(pulseHasErrFromRQ),
            //     ", wcGenReqSQ=", fshow(wcGenReqSQ)
            // );
        end
    endrule

    rule errFlushSQ if (workCompGenStateReg == WC_GEN_ST_ERR_FLUSH);
        let wcGenReqSQ = pendingWorkCompQ4SQ.first;
        pendingWorkCompQ4SQ.deq;

        // TODO: use formal to check no partial ACK after NAK
        immAssert(
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_FULL_ACK,
            "wcGenReqSQ.wcReqType assertion @ mkWorkCompGenSQ",
            $format(
                "wcGenReqSQ.wcReqType=", fshow(wcGenReqSQ.wcReqType),
                " should == WC_REQ_TYPE_FULL_ACK, when error flush"
            )
        );

        let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, wcGenReqSQ.wr);
        immAssert(
            isValid(maybeErrFlushWC),
            "maybeErrFlushWC assertion @ mkWorkCompGenSQ",
            $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
        );
        let errFlushWC = unwrapMaybe(maybeErrFlushWC);

        // let isCompQueueFull = False;
        if (isFirstErrPartialAckWorkReqReg) begin
            // If the first error response is partial ACK to WR,
            // then skip the first full ACK to the WR,
            // since the WR has generated error WC.
            isFirstErrPartialAckWorkReqReg <= False;
            immAssert(
                wcGenReqSQ.wr.id == firstErrPartialAckWorkReqIdReg,
                "wcGenReqSQ.wr.id assertion @ mkWorkCompGenSQ",
                $format(
                    "wcGenReqSQ.wr.id=%h should == firstErrPartialAckWorkReqIdReg=%h",
                    wcGenReqSQ.wr.id, firstErrPartialAckWorkReqIdReg,
                    ", when error flush and isFirstErrPartialAckWorkReqReg=",
                    fshow(isFirstErrPartialAckWorkReqReg)
                )
            );
        end
        // else if (workCompOutQ4SQ.notFull) begin
        //     isCompQueueFull = True;
        // end
        else begin
            workCompOutQ4SQ.enq(errFlushWC);
        end
        // $display(
        //     "time=%0t: flush pendingWorkCompQ4SQ, errFlushWC=",
        //     $time, fshow(errFlushWC), ", wcGenReqSQ=", fshow(wcGenReqSQ)
        // );
    endrule

    rule discardPayloadConResp if (workCompGenStateReg == WC_GEN_ST_ERR_FLUSH);
        let payloadConResp = payloadConRespPipeIn.first;
        payloadConRespPipeIn.deq;
    endrule

    return convertFifo2PipeOut(workCompOutQ4SQ);
endmodule

// WC for RQ

function Maybe#(WorkComp) genWorkComp4RecvReq(
    Controller cntrl, WorkCompGenReqRQ wcGenReqRQ
);
    let maybeWorkCompOpCode = rdmaOpCode2WorkCompOpCode4RQ(wcGenReqRQ.reqOpCode);
    let wcFlags = rdmaOpCode2WorkCompFlagsRQ(wcGenReqRQ.reqOpCode);
    if (
        maybeWorkCompOpCode matches tagged Valid .opcode &&&
        wcGenReqRQ.rrID matches tagged Valid .rrID
    ) begin
        let workComp = WorkComp {
            id      : rrID,
            opcode  : opcode,
            flags   : wcFlags,
            status  : wcGenReqRQ.wcStatus,
            len     : wcGenReqRQ.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getSQPN,
            sqpn    : cntrl.getDQPN,
            immDt   : wcGenReqRQ.immDt,
            rkey2Inv: wcGenReqRQ.rkey2Inv
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(WorkComp) genErrFlushWorkComp4WorkCompGenReqRQ(
    Controller cntrl, WorkCompGenReqRQ wcGenReqRQ
);
    let maybeWorkCompOpCode = rdmaOpCode2WorkCompOpCode4RQ(wcGenReqRQ.reqOpCode);
    let wcFlags = rdmaOpCode2WorkCompFlagsRQ(wcGenReqRQ.reqOpCode);

    if (
        maybeWorkCompOpCode matches tagged Valid .opcode &&&
        wcGenReqRQ.rrID matches tagged Valid .rrID
    ) begin
        let workComp = WorkComp {
            id      : rrID,
            opcode  : opcode,
            flags   : wcFlags,
            status  : IBV_WC_WR_FLUSH_ERR,
            len     : wcGenReqRQ.len,
            pkey    : cntrl.getPKEY,
            dqpn    : cntrl.getSQPN,
            sqpn    : cntrl.getDQPN,
            immDt   : wcGenReqRQ.immDt,
            rkey2Inv: wcGenReqRQ.rkey2Inv
        };
        return tagged Valid workComp;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function WorkComp genErrFlushWorkComp4RecvReq(
    Controller cntrl, RecvReq rr
);
    let workComp = WorkComp {
        id      : rr.id,
        opcode  : IBV_WC_RECV,
        flags   : IBV_WC_NO_FLAGS,
        status  : IBV_WC_WR_FLUSH_ERR,
        len     : rr.len,
        pkey    : cntrl.getPKEY,
        dqpn    : cntrl.getSQPN,
        sqpn    : cntrl.getDQPN,
        immDt   : tagged Invalid,
        rkey2Inv: tagged Invalid
    };
    return workComp;
endfunction

interface WorkCompGenRQ;
    interface PipeOut#(WorkComp) workCompPipeOut;
    interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkWorkCompGenRQ#(
    Controller cntrl,
    PipeOut#(PayloadConResp) payloadConRespPipeIn,
    // RecvReqBuf recvReqBuf,
    PipeOut#(WorkCompGenReqRQ) wcGenReqPipeInFromRQ
)(WorkCompGenRQ);
    FIFOF#(WorkComp)    workCompOutQ4RQ <- mkSizedFIFOF(valueOf(MAX_CQE));
    FIFOF#(WorkCompStatus) wcStatusQ4SQ <- mkFIFOF;

    Reg#(WorkCompGenState) workCompGenStateReg <- mkReg(WC_GEN_ST_STOP);

    (* no_implicit_conditions, fire_when_enabled *)
    rule start if (cntrl.isNonErr && workCompGenStateReg == WC_GEN_ST_STOP);
        workCompGenStateReg <= WC_GEN_ST_NORMAL;
    endrule

    rule discardPayloadConResp if (
        workCompGenStateReg == WC_GEN_ST_ERR_FLUSH
    );
        let payloadConsumeResp = payloadConRespPipeIn.first;
        payloadConRespPipeIn.deq;
    endrule

    rule genWorkCompRQ if (
        cntrl.isNonErr && workCompGenStateReg == WC_GEN_ST_NORMAL
    );
        let wcGenReqRQ = wcGenReqPipeInFromRQ.first;
        wcGenReqPipeInFromRQ.deq;

        let reqOpCode   = wcGenReqRQ.reqOpCode;
        let isSendReq   = isSendReqRdmaOpCode(reqOpCode);
        let isWriteReq  = isWriteReqRdmaOpCode(reqOpCode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(reqOpCode);
        let isLastOrOnlyReq  = isLastOrOnlyRdmaOpCode(reqOpCode);

        let maybeWorkComp             = genWorkComp4RecvReq(cntrl, wcGenReqRQ);
        let isWorkCompSuccess         = wcGenReqRQ.wcStatus == IBV_WC_SUCCESS;
        // let isCompQueueFull           = False;
        let needWaitDmaRespWhenNormal = !wcGenReqRQ.isZeroDmaLen && (isSendReq || isWriteReq);

        // TODO: handle CQ full
        if (isWorkCompSuccess) begin
            if (isLastOrOnlyReq && (isSendReq || isWriteImmReq)) begin
                immAssert(
                    isValid(maybeWorkComp),
                    "maybeWorkComp assertion @ mkWorkCompGenRQ",
                    $format(
                        "maybeWorkComp=", fshow(maybeWorkComp),
                        " should be valid when wcGenReqRQ=", fshow(wcGenReqRQ)
                    )
                );
                let workComp = unwrapMaybe(maybeWorkComp);

                // if (workCompOutQ4RQ.notFull) begin
                workCompOutQ4RQ.enq(workComp);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end

            if (needWaitDmaRespWhenNormal) begin
                // TODO: report error if waiting too long for DMA write response
                let payloadConsumeResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;

                // TODO: better error handling
                let dmaRespPsnMatch = payloadConsumeResp.dmaWriteResp.psn == wcGenReqRQ.reqPSN;
                immAssert (
                    dmaRespPsnMatch,
                    "dmaWriteRespMatchPSN assertion @ mkWorkCompGenRQ",
                    $format(
                        "dmaRespPsnMatch=", fshow(dmaRespPsnMatch),
                        " should either be true, payloadConsumeResp.dmaWriteResp.psn=%h should == wcGenReqRQ.reqPSN=%h",
                        payloadConsumeResp.dmaWriteResp.psn, wcGenReqRQ.reqPSN,
                        ", reqOpCode=", fshow(reqOpCode)
                    )
                );
                // $display(
                //     "time=%0t: payloadConsumeResp=", $time, fshow(payloadConsumeResp),
                //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
                // );
            end
        end
        else begin
            wcStatusQ4SQ.enq(wcGenReqRQ.wcStatus);
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;

            if (maybeWorkComp matches tagged Valid .workComp) begin
                // if (workCompOutQ4RQ.notFull) begin
                workCompOutQ4RQ.enq(workComp);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
        end
        // $display(
        //     "time=%0t: wcGenReqRQ=", $time, fshow(wcGenReqRQ),
        //     ", maybeWorkComp=", fshow(maybeWorkComp),
        //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
        // );
    endrule

    rule errFlushRQ if (workCompGenStateReg == WC_GEN_ST_ERR_FLUSH);
        let wcGenReqRQ = wcGenReqPipeInFromRQ.first;
        wcGenReqPipeInFromRQ.deq;

        let reqOpCode   = wcGenReqRQ.reqOpCode;
        let isSendReq   = isSendReqRdmaOpCode(reqOpCode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(reqOpCode);
        let isFirstOrOnlyReq = isFirstOrOnlyRdmaOpCode(reqOpCode);
        // let isCompQueueFull  = False;

        let maybeErrFlushWC = genErrFlushWorkComp4WorkCompGenReqRQ(cntrl, wcGenReqRQ);
        if (maybeErrFlushWC matches tagged Valid .errFlushWC) begin
            immAssert(
                isSendReq || isWriteImmReq,
                "isSendReq or isWriteImmReq assertion @ mkWorkCompGenRQ",
                $format(
                    "maybeErrFlushWC=", fshow(maybeErrFlushWC),
                    " should be valid, when reqOpCode=", fshow(reqOpCode),
                    " should be send or write with imm"
                )
            );

            if (wcGenReqRQ.wcStatus != IBV_WC_WR_FLUSH_ERR) begin
                // When error, generate WC in RQ on first or only send request packets,
                // since the middle or last send request packets might be discarded.
                if ((isSendReq && isFirstOrOnlyReq) || isWriteImmReq) begin
                    // if (workCompOutQ4RQ.notFull) begin
                    workCompOutQ4RQ.enq(errFlushWC);
                    // end
                    // else begin
                    //     isCompQueueFull = True;
                    // end
                end
            end
            else begin
                // if (workCompOutQ4RQ.notFull) begin
                workCompOutQ4RQ.enq(errFlushWC);
                // end
                // else begin
                //     isCompQueueFull = True;
                // end
            end
        end

        // $display(
        //     "time=%0t: flush wcGenReqPipeInFromRQ, wcGenReqRQ=",
        //     $time, fshow(wcGenReqRQ),
        //     ", maybeErrFlushWC=", fshow(maybeErrFlushWC)
        // );
    endrule

    interface workCompPipeOut         = convertFifo2PipeOut(workCompOutQ4RQ);
    interface workCompStatusPipeOutRQ = convertFifo2PipeOut(wcStatusQ4SQ);
endmodule
