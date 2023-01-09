import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;

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
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
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
            dqpn    : cntrl.getDQPN,
            sqpn    : cntrl.getSQPN,
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
        dqpn    : cntrl.getDQPN,
        sqpn    : cntrl.getSQPN,
        immDt   : tagged Invalid,
        rkey2Inv: tagged Invalid
    };
    return workComp;
endfunction

typedef enum {
    WC_GEN_ST_STOP,
    WC_GEN_ST_NORMAL,
    WC_GEN_ST_ERR_FLUSH
} WorkCompGenState deriving(Bits, Eq);

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

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
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

        let isCompQueueFull           = False;
        let maybeWorkComp             = genWorkComp4RecvReq(cntrl, wcGenReqRQ);
        let isWorkCompSuccess         = wcGenReqRQ.wcStatus == IBV_WC_SUCCESS;
        let needWaitDmaRespWhenNormal = !wcGenReqRQ.isZeroDmaLen && (isSendReq || isWriteReq);

        if (isWorkCompSuccess) begin
            if (isLastOrOnlyReq && (isSendReq || isWriteImmReq)) begin
                dynAssert(
                    isValid(maybeWorkComp),
                    "maybeWorkComp assertion @ mkWorkCompGenRQ",
                    $format(
                        "maybeWorkComp=", fshow(maybeWorkComp),
                        " should be valid when wcGenReqRQ=", fshow(wcGenReqRQ)
                    )
                );
                let workComp = unwrapMaybe(maybeWorkComp);

                if (workCompOutQ4RQ.notFull) begin
                    workCompOutQ4RQ.enq(workComp);
                end
                else begin
                    isCompQueueFull = True;
                end
            end

            if (needWaitDmaRespWhenNormal) begin
                // TODO: report error if waiting too long for DMA write response
                let payloadConsumeResp = payloadConRespPipeIn.first;
                payloadConRespPipeIn.deq;

                // TODO: better error handling
                let dmaRespPsnMatch = payloadConsumeResp.dmaWriteResp.psn == wcGenReqRQ.reqPSN;
                dynAssert (
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
                //     "time=%0d: payloadConsumeResp=", $time, fshow(payloadConsumeResp),
                //     ", needWaitDmaRespWhenNormal=", fshow(needWaitDmaRespWhenNormal)
                // );
            end
        end
        else begin
            wcStatusQ4SQ.enq(wcGenReqRQ.wcStatus);
            workCompGenStateReg <= WC_GEN_ST_ERR_FLUSH;

            if (maybeWorkComp matches tagged Valid .workComp) begin
                if (workCompOutQ4RQ.notFull) begin
                    workCompOutQ4RQ.enq(workComp);
                end
                else begin
                    isCompQueueFull = True;
                end
            end
        end
        // $display(
        //     "time=%0d: wcGenReqRQ=", $time, fshow(wcGenReqRQ),
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
        let isCompQueueFull  = False;

        let maybeErrFlushWC = genErrFlushWorkComp4WorkCompGenReqRQ(cntrl, wcGenReqRQ);
        if (maybeErrFlushWC matches tagged Valid .errFlushWC) begin
            dynAssert(
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
                    if (workCompOutQ4RQ.notFull) begin
                        workCompOutQ4RQ.enq(errFlushWC);
                    end
                    else begin
                        isCompQueueFull = True;
                    end
                end
            end
            else begin
                if (workCompOutQ4RQ.notFull) begin
                    workCompOutQ4RQ.enq(errFlushWC);
                end
                else begin
                    isCompQueueFull = True;
                end
            end
        end

        // $display(
        //     "time=%0d: flush wcGenReqPipeInFromRQ, wcGenReqRQ=",
        //     $time, fshow(wcGenReqRQ),
        //     ", maybeErrFlushWC=", fshow(maybeErrFlushWC)
        // );
    endrule

    interface workCompPipeOut         = convertFifo2PipeOut(workCompOutQ4RQ);
    interface workCompStatusPipeOutRQ = convertFifo2PipeOut(wcStatusQ4SQ);
endmodule
