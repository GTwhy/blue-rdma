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

    rule recvWorkCompStatusRQ if (workCompGenStateReg == WC_GEN_ST_NORMAL);
        let wcStatusRQ = workCompStatusPipeInFromRQ.first;
        workCompStatusPipeInFromRQ.deq;

        if (wcStatusRQ != IBV_WC_SUCCESS) begin
            pulseHasErrFromRQ.send;
        end
    endrule

    rule discardPayloadConResp if (workCompGenStateReg == WC_GEN_ST_ERR_FLUSH);
        let payloadConResp = payloadConRespPipeIn.first;
        payloadConRespPipeIn.deq;
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
            (workReqNeedWorkCompSQ(wcGenReqSQ.pendingWR.wr) || cntrl.getSigAll);

        dynAssert(
            isValid(maybeWorkComp),
            "maybeWorkComp assertion @ mkWorkCompGenSQ",
            $format("maybeWorkComp=", fshow(maybeWorkComp), " should be valid")
        );
        let workComp = unwrapMaybe(maybeWorkComp);
        let isWorkCompSuccess = workComp.status == IBV_WC_SUCCESS;
        let isCompQueueFull = False;

        // $display(
        //     "time=%0d: wcGenReqSQ=", $time, fshow(wcGenReqSQ),
        //     ", needWorkCompWhenNormal=", fshow(needWorkCompWhenNormal)
        // );

        if (isWorkCompSuccess) begin
            if (wcWaitDmaResp) begin
                // TODO: report error if waiting too long for DMA write response
                let payloadConResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;

                // TODO: better error handling
                let dmaRespPsnMatch = payloadConResp.dmaWriteResp.psn == wcGenReqSQ.triggerPSN;
                dynAssert (
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
                if (workCompOutQ4SQ.notFull) begin
                    workCompOutQ4SQ.enq(workComp);
                end
                else begin
                    isCompQueueFull = True;
                end
            end
        end
        else begin
            if (workCompOutQ4SQ.notFull) begin
                workCompOutQ4SQ.enq(workComp);
            end
            else begin
                isCompQueueFull = True;
            end
        end

        let hasErrWorkCompOrCompQueueFullSQ = !isWorkCompSuccess || isCompQueueFull;
        if (hasErrWorkCompOrCompQueueFullSQ || pulseHasErrFromRQ) begin
            cntrl.setStateErr;
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;
            isFirstErrPartialAckWorkReqReg <=
                wcGenReqSQ.wcReqType == WC_REQ_TYPE_PARTIAL_ACK;
            firstErrPartialAckWorkReqIdReg <= wcGenReqSQ.pendingWR.wr.id;
            // $display(
            //     "time=%0d: hasErrWorkCompOrCompQueueFullSQ=",
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
        dynAssert(
            wcGenReqSQ.wcReqType == WC_REQ_TYPE_FULL_ACK,
            "wcGenReqSQ.wcReqType assertion @ mkWorkCompGenSQ",
            $format(
                "wcGenReqSQ.wcReqType=", fshow(wcGenReqSQ.wcReqType),
                " should == WC_REQ_TYPE_FULL_ACK, when error flush"
            )
        );

        let maybeErrFlushWC = genErrFlushWorkComp4WorkReq(cntrl, wcGenReqSQ.pendingWR.wr);
        dynAssert(
            isValid(maybeErrFlushWC),
            "maybeErrFlushWC assertion @ mkWorkCompGenSQ",
            $format("maybeErrFlushWC=", fshow(maybeErrFlushWC), " should be valid")
        );
        let errFlushWC = unwrapMaybe(maybeErrFlushWC);

        let isCompQueueFull = False;
        if (isFirstErrPartialAckWorkReqReg) begin
            // If the first error response is partial ACK to WR,
            // then skip the first full ACK to the WR,
            // since the WR has generated error WC.
            isFirstErrPartialAckWorkReqReg <= False;
            dynAssert(
                wcGenReqSQ.pendingWR.wr.id == firstErrPartialAckWorkReqIdReg,
                "wcGenReqSQ.pendingWR.wr.id assertion @ mkWorkCompGenSQ",
                $format(
                    "wcGenReqSQ.pendingWR.wr.id=%h should == firstErrPartialAckWorkReqIdReg=%h",
                    wcGenReqSQ.pendingWR.wr.id, firstErrPartialAckWorkReqIdReg,
                    ", when error flush and isFirstErrPartialAckWorkReqReg=",
                    fshow(isFirstErrPartialAckWorkReqReg)
                )
            );
        end
        else if (workCompOutQ4SQ.notFull) begin
            workCompOutQ4SQ.enq(errFlushWC);
        end
        else begin
            isCompQueueFull = True;
        end
        // $display(
        //     "time=%0d: flush pendingWorkCompQ4SQ, errFlushWC=",
        //     $time, fshow(errFlushWC), ", wcGenReqSQ=", fshow(wcGenReqSQ)
        // );
    endrule

    return convertFifo2PipeOut(workCompOutQ4SQ);
endmodule