import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import Utils :: *;

function Maybe#(QPN) getMaybeDestQpnSQ(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_RC      ,
        IBV_QPT_UC      ,
        IBV_QPT_XRC_SEND: tagged Valid cntrl.getDQPN;
        IBV_QPT_UD      : wr.dqpn;
        default         : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyReqRdmaOpCode(WorkReqOpCode wrOpCode, Bool isOnlyReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY                : RDMA_WRITE_FIRST);
        IBV_WR_RDMA_WRITE_WITH_IMM : tagged Valid (isOnlyReqPkt ? RDMA_WRITE_ONLY_WITH_IMMEDIATE : RDMA_WRITE_FIRST);
        IBV_WR_SEND                : tagged Valid (isOnlyReqPkt ? SEND_ONLY                      : SEND_FIRST);
        IBV_WR_SEND_WITH_IMM       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_IMMEDIATE       : SEND_FIRST);
        IBV_WR_SEND_WITH_INV       : tagged Valid (isOnlyReqPkt ? SEND_ONLY_WITH_INVALIDATE      : SEND_FIRST);
        IBV_WR_RDMA_READ           : tagged Valid RDMA_READ_REQUEST;
        IBV_WR_ATOMIC_CMP_AND_SWP  : tagged Valid COMPARE_SWAP;
        IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid FETCH_ADD;
        default                    : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastReqRdmaOpCode(WorkReqOpCode wrOpCode, Bool isLastReqPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE         : tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST                : RDMA_WRITE_MIDDLE);
        IBV_WR_RDMA_WRITE_WITH_IMM: tagged Valid (isLastReqPkt ? RDMA_WRITE_LAST_WITH_IMMEDIATE : RDMA_WRITE_MIDDLE);
        IBV_WR_SEND               : tagged Valid (isLastReqPkt ? SEND_LAST                      : SEND_MIDDLE);
        IBV_WR_SEND_WITH_IMM      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_IMMEDIATE       : SEND_MIDDLE);
        IBV_WR_SEND_WITH_INV      : tagged Valid (isLastReqPkt ? SEND_LAST_WITH_INVALIDATE      : SEND_MIDDLE);
        default                   : tagged Invalid;
    endcase;
endfunction

function Maybe#(XRCETH) genXRCETH(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_XRC_SEND: tagged Valid XRCETH {
            srqn: unwrapMaybe(wr.srqn),
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(DETH) genDETH(WorkReq wr, Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_UD: tagged Valid DETH {
            qkey: unwrapMaybe(wr.qkey),
            sqpn: cntrl.getSQPN,
            rsvd: unpack(0)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RETH) genRETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE, IBV_WR_RDMA_WRITE_WITH_IMM, IBV_WR_RDMA_READ: tagged Valid RETH {
            va: wr.raddr,
            rkey: wr.rkey,
            dlen: wr.len
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(AtomicEth) genAtomicEth(WorkReq wr);
    if (wr.swap matches tagged Valid .swap &&& wr.comp matches tagged Valid .comp) begin
        return case (wr.opcode)
            IBV_WR_ATOMIC_CMP_AND_SWP, IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid AtomicEth {
                va: wr.raddr,
                rkey: wr.rkey,
                swap: swap,
                comp: comp
            };
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(ImmDt) genImmDt(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM, IBV_WR_SEND_WITH_IMM: tagged Valid ImmDt {
            data: unwrapMaybe(wr.immDt)
        };
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(IETH) genIETH(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_SEND_WITH_INV: (tagged Valid IETH {
            rkey: unwrapMaybe(wr.rkey2Inv)
        });
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaHeader) genFirstOrOnlyReqHeader(WorkReq wr, Controller cntrl, PSN psn, Bool isOnlyReqPkt);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genFirstOrOnlyReqRdmaOpCode(wr.opcode, isOnlyReqPkt);
    let maybeDQPN   = getMaybeDestQpnSQ(wr, cntrl);

    let isReadOrAtomicWR = isReadOrAtomicWorkReq(wr.opcode);
    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : (isOnlyReqPkt && !isReadOrAtomicWR) ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrl.getSigAll || (isOnlyReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : psn
        };

        let xrcEth = genXRCETH(wr, cntrl);
        let deth = genDETH(wr, cntrl);
        let reth = genRETH(wr);
        let atomicEth = genAtomicEth(wr);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        // If WR has zero length, then no payload, no matter what kind of opcode
        let hasPayload = workReqHasPayload(wr);
        case (wr.opcode)
            IBV_WR_RDMA_WRITE: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth))}),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(reth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(reth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC,
                    IBV_QPT_UC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_UD: tagged Valid genRdmaHeader(
                        // UD always has only pkt
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(deth)), pack(unwrapMaybe(immDt)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(DETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isOnlyReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        isOnlyReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_READ: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(reth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(RETH_BYTE_WIDTH)),
                        False // Read requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_ATOMIC_CMP_AND_SWP  ,
            IBV_WR_ATOMIC_FETCH_AND_ADD: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(atomicEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(ATOMIC_ETH_BYTE_WIDTH)),
                        False // Atomic requests have no payload
                    );
                    default: tagged Invalid;
                endcase;
            end
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(RdmaHeader) genMiddleOrLastReqHeader(WorkReq wr, Controller cntrl, PSN psn, Bool isLastReqPkt);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genMiddleOrLastReqRdmaOpCode(wr.opcode, isLastReqPkt);
    let maybeDQPN   = getMaybeDestQpnSQ(wr, cntrl);

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: wr.solicited,
            migReq   : unpack(0),
            padCnt   : isLastReqPkt ? calcPadCnt(wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : cntrl.getSigAll || (isLastReqPkt && workReqRequireAck(wr)),
            resv7    : unpack(0),
            psn      : psn
        };

        let xrcEth = genXRCETH(wr, cntrl);
        let immDt = genImmDt(wr);
        let ieth = genIETH(wr);

        let hasPayload = True;
        case (wr.opcode)
            IBV_WR_RDMA_WRITE:begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_RDMA_WRITE_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt))}) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        zeroExtendLSB(pack(bth)),
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_IMM: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(immDt)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IMM_DT_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            IBV_WR_SEND_WITH_INV: begin
                return case (cntrl.getQpType)
                    IBV_QPT_RC: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB(pack(bth)),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH)),
                        hasPayload
                    );
                    IBV_QPT_XRC_SEND: tagged Valid genRdmaHeader(
                        isLastReqPkt ?
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)), pack(unwrapMaybe(ieth)) }) :
                            zeroExtendLSB({ pack(bth), pack(unwrapMaybe(xrcEth)) }),
                        isLastReqPkt ?
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH) + valueOf(IETH_BYTE_WIDTH)) :
                            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(XRCETH_BYTE_WIDTH)),
                        hasPayload
                    );
                    default: tagged Invalid;
                endcase;
            end
            default: return tagged Invalid;
        endcase
    end
    else begin
        return tagged Invalid;
    end
endfunction

interface ReqGenSQ;
    interface PipeOut#(PendingWorkReq) pendingWorkReqPipeOut;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
endinterface

module mkReqGenSQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    Bool pendingWorkReqBufNotEmpty
)(ReqGenSQ);
    FIFOF#(PayloadGenReq)     payloadGenReqOutQ <- mkFIFOF;
    FIFOF#(PendingWorkReq)   pendingWorkReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    FIFOF#(PendingWorkReq) pendingReqGenQ <- mkFIFOF;
    FIFOF#(RdmaHeader)         reqHeaderQ <- mkFIFOF;

    Reg#(PktNum)         pktNumReg <- mkRegU;
    Reg#(PSN)            curPsnReg <- mkRegU;
    Reg#(Bool) isGenMultiPktReqReg <- mkReg(False);

    let payloadGenerator <- mkPayloadGenerator(
        cntrl, dmaReadSrv, convertFifo2PipeOut(payloadGenReqOutQ)
    );
    let payloadDataStreamPipeOut <- mkFunc2Pipe(
        getDataStreamFromPayloadGenRespPipeOut,
        payloadGenerator.respPipeOut
    );

    // Generate header DataStream
    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(reqHeaderQ)
    );
    // Prepend header to payload if any
    let rdmaReqPipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        payloadDataStreamPipeOut
    );

    rule deqWorkReqPipeOut if (cntrl.isRTS);
        let qpType = cntrl.getQpType;
        dynAssert(
            qpType == IBV_QPT_RC || qpType == IBV_QPT_UC ||
            qpType == IBV_QPT_XRC_SEND || qpType == IBV_QPT_UD,
            "qpType assertion @ mkReqGenSQ",
            $format(
                "qpType=", fshow(qpType), " unsupported"
            )
        );

        let shouldDeqPendingWR = False;
        let curPendingWR = pendingWorkReqPipeIn.first;
        if (
            cntrl.isSQD ||
            compareWorkReqFlags(curPendingWR.wr.flags, IBV_SEND_FENCE)
        ) begin
            if (pendingWorkReqBufNotEmpty) begin
                $info(
                    "time=%0d: wait pendingWorkReqBufNotEmpty=",
                    $time, fshow(pendingWorkReqBufNotEmpty),
                    " to be false, when IBV_QPS_SQD or IBV_SEND_FENCE"
                );
            end
            else begin
                shouldDeqPendingWR = True;
            end
        end
        else begin
            shouldDeqPendingWR = True;
        end

        dynAssert(
            curPendingWR.wr.sqpn == cntrl.getSQPN,
            "curPendingWR.wr.sqpn assertion @ mkWorkReq2RdmaReq",
            $format(
                "curPendingWR.wr.sqpn=%h should == cntrl.getSQPN=%h",
                curPendingWR.wr.sqpn, cntrl.getSQPN
            )
        );

        if (isAtomicWorkReq(curPendingWR.wr.opcode)) begin
            dynAssert(
                curPendingWR.wr.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                "curPendingWR.wr.len assertion @ mkWorkReq2RdmaReq",
                $format(
                    "curPendingWR.wr.len=%0d should be %0d for atomic WR=",
                    curPendingWR.wr.len, valueOf(ATOMIC_WORK_REQ_LEN), fshow(curPendingWR)
                )
            );
        end
        // TODO: handle pending read/atomic request number limit

        if (shouldDeqPendingWR) begin
            pendingWorkReqPipeIn.deq;
            // $display("time=%0d: received PendingWorkReq=", $time, fshow(curPendingWR));

            let isNewWorkReq = False;
            let isValidWorkReq = True;
            if (isValid(curPendingWR.isOnlyReqPkt)) begin
                // Should be retry WorkReq
                dynAssert(
                    isValid(curPendingWR.startPSN) &&
                    isValid(curPendingWR.endPSN)   &&
                    isValid(curPendingWR.pktNum)   &&
                    isValid(curPendingWR.isOnlyReqPkt),
                    "curPendingWR assertion @ mkWorkReq2Headers",
                    $format(
                        "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                        fshow(curPendingWR)
                    )
                );
            end
            else begin
                let startPktSeqNum = cntrl.getNPSN;
                let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
                    startPktSeqNum, curPendingWR.wr.len, cntrl.getPMTU
                );
                dynAssert(
                    startPktSeqNum <= endPktSeqNum && (endPktSeqNum + 1 == nextPktSeqNum),
                    "startPSN, endPSN, nextPSN assertion @ mkReqGenSQ",
                    $format(
                        "startPSN=%h should <= endPSN=%h, and endPSN=%h + 1 should == nextPSN=%h",
                        startPktSeqNum, endPktSeqNum, endPktSeqNum, nextPktSeqNum
                    )
                );

                cntrl.setNPSN(nextPktSeqNum);
                let hasOnlyReqPkt = isOnlyPkt || isReadWorkReq(curPendingWR.wr.opcode);

                curPendingWR.startPSN = tagged Valid startPktSeqNum;
                curPendingWR.endPSN = tagged Valid endPktSeqNum;
                curPendingWR.pktNum = tagged Valid totalPktNum;
                curPendingWR.isOnlyReqPkt = tagged Valid hasOnlyReqPkt;

                isValidWorkReq = qpType == IBV_QPT_UD ? isLessOrEqOne(totalPktNum) : True;
                isNewWorkReq = True;
                // $display(
                //     "time=%0d: curPendingWR=", $time, fshow(curPendingWR), ", nPSN=%h", nextPktSeqNum
                // );
            end

            if (isValidWorkReq) begin
                // Only for RC and XRC output new WR as pending WR, not retry WR
                if (isNewWorkReq && (qpType == IBV_QPT_RC || qpType == IBV_QPT_XRC_SEND)) begin
                    pendingWorkReqOutQ.enq(curPendingWR);
                end

                pendingReqGenQ.enq(curPendingWR);
            end
        end
    endrule

    rule genFirstOrOnlyReqHeader if (cntrl.isRTS && !isGenMultiPktReqReg);
        let pendingWorkReq = pendingReqGenQ.first;

        PSN startPSN = unwrapMaybe(pendingWorkReq.startPSN);
        PktNum pktNum = unwrapMaybe(pendingWorkReq.pktNum);
        Bool isOnlyReqPkt = unwrapMaybe(pendingWorkReq.isOnlyReqPkt);
        if (isOnlyReqPkt) begin
            pendingReqGenQ.deq;
        end
        else begin
            // curPendingWorkReqReg <= pendingWorkReq;
            curPsnReg <= startPSN + 1;
            // Current cycle output first/only packet,
            // so the remaining pktNum = totalPktNum - 2
            pktNumReg <= pktNum - 2;
        end

        let qpType = cntrl.getQpType;
        let maybeFirstOrOnlyHeader = genFirstOrOnlyReqHeader(
            pendingWorkReq.wr, cntrl, startPSN, isOnlyReqPkt
        );
        // TODO: remove this assertion, just report error by WC
        dynAssert(
            isValid(maybeFirstOrOnlyHeader),
            "maybeFirstOrOnlyHeader assertion @ mkReqGenSQ",
            $format(
                "maybeFirstOrOnlyHeader=", fshow(maybeFirstOrOnlyHeader),
                " is not valid, and current WR=", fshow(pendingWorkReq)
            )
        );

        if (maybeFirstOrOnlyHeader matches tagged Valid .firstOrOnlyHeader) begin
            // Check WR length cannot be larger than PMTU for UD
            let isValidRdmaReq = qpType == IBV_QPT_UD ? isOnlyReqPkt : True;
            if (isValidRdmaReq) begin
                if (workReqNeedDmaReadSQ(pendingWorkReq.wr)) begin
                    let payloadGenReq = PayloadGenReq {
                        initiator    : OP_INIT_SQ_RD,
                        addPadding   : True,
                        segment      : True,
                        pmtu         : cntrl.getPMTU,
                        dmaReadReq   : DmaReadReq {
                            sqpn     : cntrl.getSQPN,
                            startAddr: pendingWorkReq.wr.laddr,
                            len      : pendingWorkReq.wr.len,
                            wrID     : pendingWorkReq.wr.id
                        }
                    };
                    payloadGenReqOutQ.enq(payloadGenReq);
                    // payloadGenerator.request(payloadGenReq);
                end

                reqHeaderQ.enq(firstOrOnlyHeader);
                isGenMultiPktReqReg <= !isOnlyReqPkt;

                // $display(
                //     "time=%0d: output PendingWorkReq=", $time, fshow(pendingWorkReq),
                //     ", output header=", fshow(firstOrOnlyHeader)
                // );
            end
            else begin
                $info(
                    "time=%0d: discard PendingWorkReq with length=%0d",
                    $time, pendingWorkReq.wr.len,
                    " larger than PMTU when QpType=", fshow(qpType)
                );
            end
        end
        else begin
            let wcWaitDmaResp     = False;
            // Partial WR ACK because this WR has inserted into pending WR buffer.
            let wcReqType         = WC_REQ_TYPE_PARTIAL_ACK;
            let wcStatus          = IBV_WC_LOC_QP_OP_ERR;
            let errWorkCompGenReq = WorkCompGenReqSQ {
                pendingWR    : pendingWorkReq,
                wcWaitDmaResp: wcWaitDmaResp,
                wcReqType    : wcReqType,
                triggerPSN   : startPSN,
                wcStatus     : wcStatus
            };
            workCompGenReqOutQ.enq(errWorkCompGenReq);
        end
    endrule

    rule genMiddleOrLastReqHeader if (cntrl.isRTS && isGenMultiPktReqReg);
        let pendingWorkReq = pendingReqGenQ.first;

        let qpType = cntrl.getQpType;
        dynAssert(
            qpType == IBV_QPT_RC || qpType == IBV_QPT_UC || qpType == IBV_QPT_XRC_SEND,
            "qpType assertion @ mkReqGenSQ",
            $format(
                "qpType=", fshow(qpType), " cannot generate multi-packet requests"
            )
        );

        let nextPSN = curPsnReg + 1;
        let remainingPktNum = pktNumReg - 1;
        curPsnReg <= nextPSN;
        pktNumReg <= remainingPktNum;
        let isLastReqPkt = isZero(pktNumReg);

        let maybeMiddleOrLastHeader = genMiddleOrLastReqHeader(
            pendingWorkReq.wr, cntrl, curPsnReg, isLastReqPkt
        );
        dynAssert(
            isValid(maybeMiddleOrLastHeader),
            "maybeMiddleOrLastHeader assertion @ mkReqGenSQ",
            $format(
                "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                " is not valid, and current WR=", fshow(pendingWorkReq)
            )
        );
        if (maybeMiddleOrLastHeader matches tagged Valid .middleOrLastHeader) begin
            reqHeaderQ.enq(middleOrLastHeader);
        end
        else begin
            let wcWaitDmaResp     = False;
            // Partial WR ACK because this WR has inserted into pending WR buffer.
            let wcReqType         = WC_REQ_TYPE_PARTIAL_ACK;
            let wcStatus          = IBV_WC_LOC_QP_OP_ERR;
            let errWorkCompGenReq = WorkCompGenReqSQ {
                pendingWR    : pendingWorkReq,
                wcWaitDmaResp: wcWaitDmaResp,
                wcReqType    : wcReqType,
                triggerPSN   : nextPSN,
                wcStatus     : wcStatus
            };
            workCompGenReqOutQ.enq(errWorkCompGenReq);
        end
        // $display(
        //     "time=%0d: curPsnReg=%h, pktNumReg=%0d, isLastReqPkt=%b",
        //     $time, curPsnReg, pktNumReg, isLastReqPkt
        // );

        if (isLastReqPkt) begin
            pendingReqGenQ.deq;
            isGenMultiPktReqReg <= !isLastReqPkt;
            let endPSN = unwrapMaybe(pendingWorkReq.endPSN);
            dynAssert(
                curPsnReg == endPSN,
                "endPSN assertion @ mkWorkReq2Headers",
                $format(
                    "curPsnReg=%h should == pendingWorkReq.endPSN=%h",
                    curPsnReg, endPSN,
                    ", pendingWorkReq=", fshow(pendingWorkReq)
                )
            );
        end
    endrule

    interface pendingWorkReqPipeOut    = convertFifo2PipeOut(pendingWorkReqOutQ);
    interface rdmaReqDataStreamPipeOut = rdmaReqPipeOut;
    interface workCompGenReqPipeOut    = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
