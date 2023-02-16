import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import InputPktHandle :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import ReqGenSQ :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

interface RdmaReqAndSendWritePayloadAndPendingWorkReq;
    interface PipeOut#(PendingWorkReq) pendingWorkReqPipeOut;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface DataStreamPipeOut sendWriteReqPayloadPipeOut;
endinterface

module mkSimGenRdmaReqAndSendWritePayloadPipeOut#(
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    QpType qpType,
    PMTU pmtu
)(RdmaReqAndSendWritePayloadAndPendingWorkReq);
    let cntrl <- mkSimController(qpType, pmtu);
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // Assume no pending WR
    let pendingWorkReqBufNotEmpty = False;
    let reqGenSQ <- mkReqGenSQ(
        cntrl, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeIn,
        pendingWorkReqBufNotEmpty
    );

    rule noErrWC;
        immAssert(
            !reqGenSQ.workCompGenReqPipeOut.notEmpty,
            "No error WC assertion @ mkSimGenRdmaReq",
            $format(
                "reqGenSQ.workCompGenReqPipeOut.notEmpty=",
                fshow(reqGenSQ.workCompGenReqPipeOut.notEmpty),
                " should be false, since it should have no error WC"
            )
        );
    endrule

    interface pendingWorkReqPipeOut      = reqGenSQ.pendingWorkReqPipeOut;
    interface rdmaReqDataStreamPipeOut   = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface sendWriteReqPayloadPipeOut = simDmaReadSrv.dataStream;
endmodule

interface RdmaReqAndPendingWorkReq;
    interface PipeOut#(PendingWorkReq) pendingWorkReqPipeOut;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
endinterface

module mkSimGenRdmaReq#(
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    QpType qpType,
    PMTU pmtu
)(RdmaReqAndPendingWorkReq);
    let simReqGen <- mkSimGenRdmaReqAndSendWritePayloadPipeOut(
        pendingWorkReqPipeIn, qpType, pmtu
    );
    let sinkSendWritePayload <- mkSink(simReqGen.sendWriteReqPayloadPipeOut);

    interface pendingWorkReqPipeOut    = simReqGen.pendingWorkReqPipeOut;
    interface rdmaReqDataStreamPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
endmodule

function Bool isNonZeroReadWorkReq(WorkReq wr);
    return !(isZero(wr.len)) && isReadWorkReq(wr.opcode);
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyRdmaOpCode(WorkReqOpCode wrOpCode, Bool isOnlyRespPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          ,
        IBV_WR_RDMA_WRITE_WITH_IMM ,
        IBV_WR_SEND                ,
        IBV_WR_SEND_WITH_IMM       ,
        IBV_WR_SEND_WITH_INV       : tagged Valid ACKNOWLEDGE;
        IBV_WR_RDMA_READ           : tagged Valid (isOnlyRespPkt ? RDMA_READ_RESPONSE_ONLY : RDMA_READ_RESPONSE_FIRST);
        IBV_WR_ATOMIC_CMP_AND_SWP  ,
        IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid ATOMIC_ACKNOWLEDGE;
        default                    : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastRdmaOpCode(WorkReqOpCode wrOpCode, Bool isLastRespPkt);
    return case (wrOpCode)
        IBV_WR_RDMA_READ : tagged Valid (isLastRespPkt ? RDMA_READ_RESPONSE_LAST : RDMA_READ_RESPONSE_MIDDLE);
        default          : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaHeader) genFirstOrOnlyRespHeader(PendingWorkReq pendingWR, Controller cntrl, Bool isOnlyRespPkt, MSN msn);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genFirstOrOnlyRdmaOpCode(pendingWR.wr.opcode, isOnlyRespPkt);
    let isReadWR = isReadWorkReq(pendingWR.wr.opcode);

    if (
        maybeTrans matches tagged Valid .trans &&&
        maybeOpCode matches tagged Valid .opcode &&&
        pendingWR.startPSN matches tagged Valid .startPSN &&&
        pendingWR.endPSN matches tagged Valid .endPSN
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False, // TODO: should response have solicited event?
            migReq   : unpack(0),
            padCnt   : (isOnlyRespPkt && isReadWR) ? calcPadCnt(pendingWR.wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : cntrl.getSQPN, // DQPN of response is SQPN
            ackReq   : False,
            resv7    : unpack(0),
            psn      : isReadWR ? startPSN : endPSN
        };
        let aeth = AETH {
            rsvd : unpack(0),
            code : AETH_CODE_ACK,
            value: pack(AETH_ACK_VALUE_INVALID_CREDIT_CNT),
            msn  : msn
        };
        let atomicAckEth = AtomicAckEth {
            orig: dontCareValue
        };
        let isZeroLenWR = isZero(pendingWR.wr.len);

        return case (pendingWR.wr.opcode)
            IBV_WR_RDMA_WRITE, IBV_WR_RDMA_WRITE_WITH_IMM, IBV_WR_SEND, IBV_WR_SEND_WITH_IMM, IBV_WR_SEND_WITH_INV: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    False // Non-read responses have no payload
                );
            end
            IBV_WR_RDMA_READ: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    !isZeroLenWR // Read responses might have payload
                );
            end
            IBV_WR_ATOMIC_CMP_AND_SWP, IBV_WR_ATOMIC_FETCH_AND_ADD: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth), pack(atomicAckEth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH) + valueOf(ATOMIC_ACK_ETH_BYTE_WIDTH)),
                    False // Atomic responses have no payload
                );
            end
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(RdmaHeader) genMiddleOrLastRespHeader(
    PendingWorkReq pendingWR, Controller cntrl, PSN psn, Bool isLastRespPkt, MSN msn
);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genMiddleOrLastRdmaOpCode(pendingWR.wr.opcode, isLastRespPkt);
    let isReadWR = isReadWorkReq(pendingWR.wr.opcode);
    let isZeroLenWR = isZero(pendingWR.wr.len);

    if (
        maybeTrans matches tagged Valid .trans &&&
        maybeOpCode matches tagged Valid .opcode &&&
        pendingWR.startPSN matches tagged Valid .startPSN &&&
        pendingWR.endPSN matches tagged Valid .endPSN &&&
        isReadWR &&& !isZeroLenWR
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False, // TODO: should response have solicited event?
            migReq   : unpack(0),
            padCnt   : isLastRespPkt ? calcPadCnt(pendingWR.wr.len) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : cntrl.getSQPN, // DQPN of response is SQPN
            ackReq   : False,
            resv7    : unpack(0),
            psn      : psn
        };
        let aeth = AETH {
            rsvd : unpack(0),
            code : AETH_CODE_ACK,
            value: pack(AETH_ACK_VALUE_INVALID_CREDIT_CNT),
            msn  : msn
        };

        return case (pendingWR.wr.opcode)
            IBV_WR_RDMA_READ: begin
                tagged Valid genRdmaHeader(
                    isLastRespPkt ?
                        zeroExtendLSB({ pack(bth), pack(aeth) }) :
                        zeroExtendLSB( pack(bth) ), // Middle read responses have no AETH
                    isLastRespPkt ?
                        fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)) :
                        fromInteger(valueOf(BTH_BYTE_WIDTH)),
                    True // Middle or last read responses must have payload
                );
            end
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function DataStream buildCNP(Controller cntrl)
provisos(
    NumAlias#(TAdd#(BTH_BYTE_WIDTH, CNP_PAYLOAD_BYTE_WIDTH), cnpPktByteSz),
    Add#(cnpPktByteSz, anysize, DATA_BUS_BYTE_WIDTH) // cnpPktByteSz <= DATA_BUS_BYTE_WIDTH
);
    let bth = BTH {
        trans    : TRANS_TYPE_CNP,
        opcode   : SEND_MIDDLE, // ROCE_CNP = 8b'10000001
        solicited: False,
        migReq   : unpack(0),
        padCnt   : 0,
        tver     : unpack(0),
        pkey     : cntrl.getPKEY,
        fecn     : unpack(0),
        becn     : unpack(0),
        resv6    : unpack(0),
        dqpn     : cntrl.getSQPN, // DQPN of response is SQPN
        ackReq   : False,
        resv7    : unpack(0),
        psn      : 0
    };
    let payloadCNP = PayloadCNP {
        rsvd1: unpack(0),
        rsvd2: unpack(0)
    };
    return DataStream {
        data   : zeroExtendLSB({ pack(bth), pack(payloadCNP) }),
        byteEn : genByteEn(fromInteger(valueOf(cnpPktByteSz))),
        isFirst: True,
        isLast : True
    };
endfunction

interface RdmaRespHeaderAndDataStreamPipeOut;
    interface PipeOut#(RdmaHeader) respHeader;
    interface DataStreamPipeOut rdmaResp;
endinterface

module mkSimGenRdmaRespHeaderAndDataStream#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(RdmaRespHeaderAndDataStreamPipeOut);
    FIFOF#(Tuple2#(PendingWorkReq, RdmaHeader)) pendingReqHeaderQ <- mkFIFOF;
    FIFOF#(RdmaHeader)     respHeaderOutQ <- mkFIFOF;
    FIFOF#(RdmaHeader) respHeaderOutQ4Ref <- mkFIFOF;
    FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;

    Reg#(PendingWorkReq) curPendingWorkReqReg <- mkRegU;
    Reg#(PktNum)                    pktNumReg <- mkRegU;
    Reg#(PSN)                       curPsnReg <- mkRegU;
    Reg#(MSN)                          msnReg <- mkReg(0);
    Reg#(Bool)                        busyReg <- mkReg(False);

    let payloadGenerator <- mkPayloadGenerator(
        cntrl, dmaReadSrv, convertFifo2PipeOut(payloadGenReqQ)
    );
    // let payloadDataStreamPipeOut <- mkFunc2Pipe(
    //     getDataStreamFromPayloadGenRespPipeOut,
    //     payloadGenerator.respPipeOut
    // );
    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(respHeaderOutQ)
    );
    let rdmaRespPipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        payloadGenerator.payloadDataStreamPipeOut
    );

    // (* fire_when_enabled *)
    rule deqWorkReqPipeOut if (!busyReg);
        let curPendingWR = pendingWorkReqPipeIn.first;
        pendingWorkReqPipeIn.deq;
        // $display("time=%0t: received PendingWorkReq=", $time, fshow(curPendingWR));

        immAssert(
            curPendingWR.wr.sqpn == cntrl.getSQPN,
            "curPendingWR.wr.sqpn assertion @ mkSimGenRdmaRespHeaderAndDataStream",
            $format(
                "curPendingWR.wr.sqpn=%h should == cntrl.getSQPN=%h",
                curPendingWR.wr.sqpn, cntrl.getSQPN
            )
        );
        immAssert(
            isValid(curPendingWR.startPSN) &&
            isValid(curPendingWR.endPSN) &&
            isValid(curPendingWR.pktNum) &&
            isValid(curPendingWR.isOnlyReqPkt),
            "curPendingWR assertion @ mkSimGenRdmaRespHeaderAndDataStream",
            $format(
                "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                fshow(curPendingWR)
            )
        );

        PSN startPSN = unwrapMaybe(curPendingWR.startPSN);
        PktNum pktNum = unwrapMaybe(curPendingWR.pktNum);
        Bool isOnlyPkt = isLessOrEqOne(pktNum);
        Bool hasOnlyRespPkt = isOnlyPkt || !isReadWorkReq(curPendingWR.wr.opcode);
        MSN msn = hasOnlyRespPkt ? (msnReg + 1) : msnReg;
        curPendingWorkReqReg <= curPendingWR;
        curPsnReg <= startPSN + 1;
        // Current cycle output first/only packet,
        // so the remaining pktNum = totalPktNum - 2
        pktNumReg <= pktNum - 2;
        msnReg <= msn;

        let maybeFirstOrOnlyHeader = genFirstOrOnlyRespHeader(curPendingWR, cntrl, hasOnlyRespPkt, msn);
        immAssert(
            isValid(maybeFirstOrOnlyHeader),
            "maybeFirstOrOnlyHeader assertion @ mkSimGenRdmaRespHeaderAndDataStream",
            $format(
                "maybeFirstOrOnlyHeader=", fshow(maybeFirstOrOnlyHeader),
                " is not valid, and current WR=", fshow(curPendingWR)
            )
        );
        if (maybeFirstOrOnlyHeader matches tagged Valid .firstOrOnlyHeader) begin
            // TODO: generate atomic WR response payload
            if (isNonZeroReadWorkReq(curPendingWR.wr)) begin
                let payloadGenReq = PayloadGenReq {
                    initiator    : OP_INIT_SQ_RD,
                    addPadding   : True,
                    segment      : True,
                    pmtu         : cntrl.getPMTU,
                    dmaReadReq   : DmaReadReq {
                        sqpn     : cntrl.getSQPN,
                        startAddr: curPendingWR.wr.laddr,
                        len      : curPendingWR.wr.len,
                        wrID     : curPendingWR.wr.id
                    }
                };
                payloadGenReqQ.enq(payloadGenReq);
            end

            pendingReqHeaderQ.enq(tuple2(curPendingWR, firstOrOnlyHeader));
            // headerOutQ.enq(firstOrOnlyHeader);
            busyReg <= !hasOnlyRespPkt;

            // $display(
            //     "time=%0t: msnReg=%0d, PendingWorkReq=", $time, msnReg, fshow(curPendingWR),
            //     ", hasOnlyRespPkt=", fshow(hasOnlyRespPkt), ", busyReg=", fshow(busyReg),
            //     ", output header=", fshow(firstOrOnlyHeader)
            // );
        end
    endrule

    rule genHeaders if (busyReg);
        let nextPSN = curPsnReg + 1;
        curPsnReg <= nextPSN;
        let remainingPktNum = pktNumReg - 1;
        pktNumReg <= remainingPktNum;
        let isLastRespPkt = isZero(pktNumReg);
        MSN msn = isLastRespPkt ? (msnReg + 1) : msnReg;
        msnReg <= msn;
        busyReg <= !isLastRespPkt;

        let maybeMiddleOrLastHeader = genMiddleOrLastRespHeader(
            curPendingWorkReqReg, cntrl, curPsnReg, isLastRespPkt, msn
        );
        immAssert(
            isValid(maybeMiddleOrLastHeader),
            "maybeMiddleOrLastHeader assertion @ mkSimGenRdmaRespHeaderAndDataStream",
            $format(
                "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                " is not valid, and current WR=", fshow(curPendingWorkReqReg)
            )
        );
        if (maybeMiddleOrLastHeader matches tagged Valid .middleOrLastHeader) begin
            pendingReqHeaderQ.enq(tuple2(curPendingWorkReqReg, middleOrLastHeader));
            // headerOutQ.enq(middleOrLastHeader);
        end

        // $display(
        //     "time=%0t: pktNumReg=%0d, msnReg=%0d, isLastRespPkt=%b, busyReg=",
        //     $time, pktNumReg, msnReg, isLastRespPkt, fshow(busyReg)
        // );
    endrule

    rule recvPayloadGenResp;
        let { pendingWR, reqHeader } = pendingReqHeaderQ.first;
        pendingReqHeaderQ.deq;

        // TODO: generate atomic WR response payload
        if (isNonZeroReadWorkReq(pendingWR.wr)) begin
            let payloadGenResp = payloadGenerator.respPipeOut.first;
            payloadGenerator.respPipeOut.deq;

            immAssert(
                !payloadGenResp.isRespErr,
                "payloadGenResp error assertion @ mkSimGenRdmaRespHeaderAndDataStream",
                $format(
                    "payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr),
                    " should be false"
                )
            );
        end

        respHeaderOutQ.enq(reqHeader);
        respHeaderOutQ4Ref.enq(reqHeader);
    endrule

    interface respHeader = convertFifo2PipeOut(respHeaderOutQ4Ref);
    interface rdmaResp = rdmaRespPipeOut;
endmodule

module mkSimGenRdmaRespDataStream#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(DataStreamPipeOut);
    let simGenRdmaResp <- mkSimGenRdmaRespHeaderAndDataStream(
        cntrl, dmaReadSrv, pendingWorkReqPipeIn
    );
    let sinkRespHeader <- mkSink(simGenRdmaResp.respHeader);
    return simGenRdmaResp.rdmaResp;
endmodule

typedef enum {
    GEN_RDMA_RESP_ACK_NORMAL,
    GEN_RDMA_RESP_ACK_ERROR,
    GEN_RDMA_RESP_ACK_RNR,
    GEN_RDMA_RESP_ACK_SEQ_ERR
} RdmaRespAckGenType deriving(Bits, Eq);

module mkGenNormalOrErrOrRetryRdmaRespAck#(
    Controller cntrl,
    RdmaRespAckGenType genAckType,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(DataStreamPipeOut);
    FIFOF#(RdmaHeader) headerQ <- mkFIFOF;

    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(headerQ)
    );
    let sinkHeaderMetaData <- mkSink(
        headerDataStreamAndMetaDataPipeOut.headerMetaData
    );

    rule genRespAck;
        let maybeTrans  = qpType2TransType(cntrl.getQpType);
        immAssert(
            isValid(maybeTrans),
            "maybeTrans assertion @ mkGenErrRdmaResp",
            $format(
                "isValid(maybeTrans)=", fshow(maybeTrans),
                " should be valid"
            )
        );
        let transType = unwrapMaybe(maybeTrans);
        immAssert(
            transType == TRANS_TYPE_RC || transType == TRANS_TYPE_XRC,
            "transType assertion @ mkGenErrRdmaResp",
            $format(
                "transType=", fshow(transType),
                " must be RC or XRC to generate responses"
            )
        );

        let pendingWR = pendingWorkReqPipeIn.first;
        pendingWorkReqPipeIn.deq;

        immAssert(
            isValid(pendingWR.startPSN),
            "pendingWR.startPSN assertion @ mkGenErrRdmaResp",
            $format(
                "isValid(pendingWR.startPSN)=", fshow(pendingWR.startPSN),
                " should be valid"
            )
        );
        let startPSN = unwrapMaybe(pendingWR.startPSN);
        let endPSN   = unwrapMaybe(pendingWR.endPSN);
        let bthPSN   = case (genAckType)
            GEN_RDMA_RESP_ACK_ERROR  ,
            GEN_RDMA_RESP_ACK_RNR    : startPSN;
            // GEN_RDMA_RESP_ACK_NORMAL,
            // GEN_RDMA_RESP_ACK_SEQ_ERR,
            default              : endPSN;
        endcase;

        let bth = BTH {
            trans    : transType,
            opcode   : ACKNOWLEDGE,
            solicited: False, // TODO: should response have solicited event?
            migReq   : unpack(0),
            padCnt   : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : cntrl.getSQPN, // DQPN of response is SQPN
            ackReq   : False,
            resv7    : unpack(0),
            psn      : bthPSN
        };
        let aeth = case (genAckType)
            GEN_RDMA_RESP_ACK_ERROR: AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_RMT_OP)),
                msn  : dontCareValue
            };
            GEN_RDMA_RESP_ACK_RNR: AETH {
                rsvd : unpack(0),
                code : AETH_CODE_RNR,
                value: cntrl.getMinRnrTimer,
                msn  : dontCareValue
            };
            GEN_RDMA_RESP_ACK_SEQ_ERR: AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                msn  : dontCareValue
            };
            default: AETH {
                rsvd : unpack(0),
                code : AETH_CODE_ACK,
                value: pack(AETH_ACK_VALUE_INVALID_CREDIT_CNT),
                msn  : dontCareValue
            };
        endcase;
        let respHeader = genRdmaHeader(
            zeroExtendLSB({ pack(bth), pack(aeth) }),
            fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
            False // Error or retry responses have no payload
        );
        headerQ.enq(respHeader);
        // $display(
        //     "time=%0t: genRespAck", $time,
        //     ", BTH=", fshow(bth), ", AETH=", fshow(aeth),
        //     ", pendingWR.wr.id=%h", pendingWR.wr.id
        // );
    endrule

    return headerDataStreamAndMetaDataPipeOut.headerDataStream;
endmodule

(* synthesize *)
module mkTestSimGenRdmaResp(Empty);
    let minDmaLength = 128;
    let maxDmaLength = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Ref <- mkBufferN(4, existingPendingWorkReqPipeOutVec[1]);

    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        simDmaReadSrv.dataStream, pmtuPipeOut
    );
    let segDataStreamPipeOut4Ref <- mkBufferN(4, segDataStreamPipeOut);

    // Generate RDMA responses
    let rdmaRespAndHeaderPipeOut <- mkSimGenRdmaRespHeaderAndDataStream(
        cntrl, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeOut4RespGen
    );
    let rdmaRespHeaderPipeOut4Ref <- mkBufferN(2, rdmaRespAndHeaderPipeOut.respHeader);
    Vector#(2, PipeOut#(RdmaHeader)) rdmaRespHeaderPipeOut4RefVec <-
        mkForkVector(rdmaRespHeaderPipeOut4Ref);
    let rdmaRespHeaderPipeOut4HeaderCmpRef = rdmaRespHeaderPipeOut4RefVec[0];
    let rdmaRespHeaderPipeOut4WorkReqCmpRef = rdmaRespHeaderPipeOut4RefVec[1];

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespAndHeaderPipeOut.rdmaResp
    );
    // Convert header DataStream to RdmaHeader
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );
    // Remove empty payload DataStream
    let filteredPayloadDataStreamPipeOut <- mkPipeFilter(
        filterEmptyDataStream,
        headerAndMetaDataAndPayloadPipeOut.payload
    );

    Reg#(MSN) curMsnReg <- mkReg(0);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareRdmaRespHeader;
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        // $display("time=%0t: BTH=", $time, fshow(bth));

        let refHeader = rdmaRespHeaderPipeOut4HeaderCmpRef.first;
        rdmaRespHeaderPipeOut4HeaderCmpRef.deq;

        immAssert(
            rdmaHeader.headerByteEn == refHeader.headerByteEn,
            "rdmaHeader.headerByteEn assertion @ mkTestRdmaRespGenInSim",
            $format(
                "rdmaHeader.headerByteEn=%h should == refHeader.headerByteEn=%h",
                rdmaHeader.headerByteEn, refHeader.headerByteEn
            )
        );

        immAssert(
            compareRdmaHeaderDataInSim(
                rdmaHeader.headerData,
                refHeader.headerData,
                rdmaHeader.headerMetaData.headerLen
            ),
            "rdmaHeader.headerData assertion @ mkTestRdmaRespGenInSim",
            $format(
                "rdmaHeader.headerData=%h should == refHeader.headerData=%h",
                rdmaHeader.headerData, refHeader.headerData,
                ", rdmaHeader.headerByteEn=%h should == refHeader.headerByteEn=%h",
                rdmaHeader.headerByteEn, refHeader.headerByteEn
            )
        );
    endrule

    rule compareRespHeaderAndWorkReq;
        let rdmaHeader = rdmaRespHeaderPipeOut4WorkReqCmpRef.first;
        rdmaRespHeaderPipeOut4WorkReqCmpRef.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        let aeth = extractAETH(rdmaHeader.headerData);
        let msn = isLastOrOnlyRdmaOpCode(bth.opcode) ? (curMsnReg + 1) : curMsnReg;
        curMsnReg <= msn;
        // $display("time=%0t: BTH=", $time, fshow(bth), ", AETH=", fshow(aeth));

        let refPendingWR = pendingWorkReqPipeOut4Ref.first;
        let wrStartPSN = unwrapMaybe(refPendingWR.startPSN);
        let wrEndPSN = unwrapMaybe(refPendingWR.endPSN);

        let respHasAeth = True;
        if (isOnlyRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            immAssert(
                bth.psn == wrEndPSN,
                "bth.psn only response packet assertion @ mkTestRdmaRespGenInSim",
                $format(
                    "bth.psn=%h should == wrStartPSN=%h == wrEndPSN=%h",
                    bth.psn, wrStartPSN, wrEndPSN,
                    ", when refPendingWR.wr.opcode=",
                    fshow(refPendingWR.wr.opcode)
                )
            );
        end
        else if (isLastRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            immAssert(
                bth.psn == wrEndPSN,
                "bth.psn last response packet assertion @ mkTestRdmaRespGenInSim",
                $format("bth.psn=%h shoud == wrEndPSN=%h", bth.psn, wrEndPSN)
            );
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn first response packet assertion @ mkTestRdmaRespGenInSim",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            respHasAeth = False; // Middle responses have no AETH

            immAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle packet assertion @ mkTestRdmaRespGenInSim",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA response opcode"
                )
            );
            immAssert(
                psnInRangeExclusive(bth.psn, wrStartPSN, wrEndPSN),
                "bth.psn between wrStartPSN and wrEndPSN assertion @ mkTestRdmaRespGenInSim",
                $format(
                    "bth.psn=%h should > wrStartPSN=%h and bth.psn=%h should < wrEndPSN=%h",
                    bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                    ", when refPendingWR.wr.opcode=", fshow(refPendingWR.wr.opcode),
                    " and rdmaOpCode=", fshow(rdmaOpCode)
                )
            );
        end

        if (respHasAeth) begin
            immAssert(
                aeth.msn == msn,
                "aeth.msn assertion @ mkTestRdmaRespGenInSim",
                $format("aeth.msn=%h should == msn=%h", aeth.msn, msn)
            );
        end

        immAssert(
            transTypeMatchQpType(transType, qpType),
            "transTypeMatchQpType assertion @ mkTestRdmaRespGenInSim",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(qpType)
            )
        );
        immAssert(
            rdmaRespOpCodeMatchWorkReqOpCode(rdmaOpCode, refPendingWR.wr.opcode),
            "rdmaRespOpCodeMatchWorkReqOpCode assertion @ mkTestRdmaRespGenInSim",
            $format(
                "RDMA response opcode=", fshow(rdmaOpCode),
                " should match workReqOpCode=", fshow(refPendingWR.wr.opcode)
            )
        );
    endrule

    rule compareRdmaRespPayload;
        let payloadDataStream = filteredPayloadDataStreamPipeOut.first;
        filteredPayloadDataStreamPipeOut.deq;

        let refDataStream = segDataStreamPipeOut4Ref.first;
        segDataStreamPipeOut4Ref.deq;

        // $display(
        //     "time=%0t: payloadDataStream=", $time, fshow(payloadDataStream),
        //     " should == refDataStream=", fshow(refDataStream)
        // );

        if (refDataStream.isLast) begin
            let lastFragValidByteNum = calcByteEnBitNumInSim(refDataStream.byteEn);
            let padCnt = calcPadCnt(zeroExtend(lastFragValidByteNum));
            let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
            let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);

            // $display(
            //     "time=%0t: refDataStream.byteEn=%h, padCnt=%0d",
            //     $time, refDataStream.byteEn, padCnt
            // );
            refDataStream.byteEn = lastFragByteEnWithPadding;
        end
        immAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestRdmaRespGenInSim",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
    endrule
endmodule
