import BRAMFIFO :: *;
import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import PrimUtils :: *;
import Utils :: *;

// interface Server#(type req_type, type resp_type);
//     interface Put#(req_type) request;
//     interface Get#(resp_type) response;
// endinterface: Server

// function DataStream getDataStreamFromPayloadGenRespPipeOut(
//     PayloadGenResp resp
// ) = resp.dmaReadResp.dataStream;

function Bool isDiscardPayload(PayloadConInfo payloadConInfo);
    return case (payloadConInfo) matches
        tagged DiscardPayload: True;
        default              : False;
    endcase;
endfunction

interface PayloadGenerator;
    interface DataStreamPipeOut payloadDataStreamPipeOut;
    interface PipeOut#(PayloadGenResp) respPipeOut;
endinterface

// If segment payload DataStream, then PayloadGenResp is sent
// at the last fragment of the segmented payload DataStream.
// If not segment, then PayloadGenResp is sent at the first
// fragment of the payload DataStream.
module mkPayloadGenerator#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PayloadGenReq) payloadGenReqPipeIn
)(PayloadGenerator);
    FIFOF#(PayloadGenResp) payloadGenRespQ <- mkFIFOF;
    FIFOF#(Tuple3#(PayloadGenReq, ByteEn, PmtuFragNum)) pendingPayloadGenReqQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    // let payloadBufPipeOut <- mkConnectPipeOut2Q(payloadPipeIn, payloadBufQ);

    Reg#(PmtuFragNum) pmtuFragCntReg <- mkRegU;
    Reg#(Bool)     shouldSetFirstReg <- mkReg(False);
    Reg#(Bool)      isNormalStateReg <- mkReg(True);

    rule recvPayloadGenReq if (cntrl.isNonErr && isNormalStateReg);
        let payloadGenReq = payloadGenReqPipeIn.first;
        payloadGenReqPipeIn.deq;
        immAssert(
            !isZero(payloadGenReq.dmaReadReq.len),
            "payloadGenReq.dmaReadReq.len assertion @ mkPayloadGenerator",
            $format(
                "payloadGenReq.dmaReadReq.len=%0d should not be zero",
                payloadGenReq.dmaReadReq.len
            )
        );
        // $display("time=%0t: payloadGenReq=", $time, fshow(payloadGenReq));

        let dmaLen = payloadGenReq.dmaReadReq.len;
        let padCnt = calcPadCnt(dmaLen);
        let lastFragValidByteNum = calcLastFragValidByteNum(dmaLen);
        let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
        let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
        let pmtuFragNum = calcFragNumByPmtu(payloadGenReq.pmtu);
        immAssert(
            !isZero(lastFragValidByteNumWithPadding),
            "lastFragValidByteNumWithPadding assertion @ mkPayloadGenerator",
            $format(
                "lastFragValidByteNumWithPadding=%0d should not be zero",
                lastFragValidByteNumWithPadding,
                ", dmaLen=%0d, lastFragValidByteNum=%0d, padCnt=%0d",
                dmaLen, lastFragValidByteNum, padCnt
            )
        );

        pendingPayloadGenReqQ.enq(tuple3(payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum));
        dmaReadSrv.request.put(payloadGenReq.dmaReadReq);
    endrule

    rule generatePayloadResp if (cntrl.isNonErr && isNormalStateReg);
        let dmaReadResp <- dmaReadSrv.response.get;
        let { payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum } = pendingPayloadGenReqQ.first;

        let curData = dmaReadResp.dataStream;
        if (curData.isLast) begin
            pendingPayloadGenReqQ.deq;

            if (payloadGenReq.addPadding) begin
                curData.byteEn = lastFragByteEnWithPadding;
            end
        end

        let generateResp = PayloadGenResp {
            initiator  : payloadGenReq.initiator,
            addPadding : payloadGenReq.addPadding,
            segment    : payloadGenReq.segment,
            isRespErr  : dmaReadResp.isRespErr
        };

        if (payloadGenReq.segment) begin
            Bool isFragCntZero = isZero(pmtuFragCntReg);
            if (shouldSetFirstReg || curData.isFirst) begin
                curData.isFirst = True;
                shouldSetFirstReg <= False;
                pmtuFragCntReg <= pmtuFragNum - 2;
            end
            else if (isFragCntZero) begin
                curData.isLast = True;
                shouldSetFirstReg <= True;
            end
            else if (!curData.isLast) begin
                pmtuFragCntReg <= pmtuFragCntReg - 1;
            end

            if (curData.isLast || dmaReadResp.isRespErr) begin
                // Generate PayloadGenResp when segmented last payload fragment,
                // or DMA read response error.
                payloadGenRespQ.enq(generateResp);
            end
        end
        else if (curData.isFirst) begin
            // PayloadGenResp ignores any error during DMA read responses,
            // if not segment payload DataStream.
            payloadGenRespQ.enq(generateResp);
        end

        isNormalStateReg <= !dmaReadResp.isRespErr;
        payloadBufQ.enq(curData);
        // $display("time=%0t: generateResp=", $time, fshow(generateResp));
        // if (dmaReadResp.isRespErr) begin
        //     $display(
        //         "time=%0t:", $time, " dmaReadResp.isRespErr=", fshow(dmaReadResp.isRespErr)
        //     );
        // end
    endrule

    rule flushDmaReadResp if (cntrl.isERR || !isNormalStateReg);
        let dmaReadResp <- dmaReadSrv.response.get;
    endrule

    rule flushPayloadGenReqPipeIn if (cntrl.isERR || !isNormalStateReg);
        payloadGenReqPipeIn.deq;
    endrule

    rule flushPendingReqQ if (cntrl.isERR || !isNormalStateReg);
        pendingPayloadGenReqQ.clear;
    endrule

    rule flushRespQ if (cntrl.isERR);
        // Response related queues cannot be cleared once isNormalStateReg is False,
        // since some payload DataStream in payloadBufQ might be still under processing.
        payloadGenRespQ.clear;
        payloadBufQ.clear;
    endrule

    interface payloadDataStreamPipeOut = convertFifo2PipeOut(payloadBufQ);
    interface respPipeOut = convertFifo2PipeOut(payloadGenRespQ);
endmodule

interface PayloadConsumer;
    interface PipeOut#(PayloadConResp) respPipeOut;
endinterface

// Flush DMA write responses when error
module mkPayloadConsumer#(
    Controller cntrl,
    DataStreamPipeOut payloadPipeIn,
    DmaWriteSrv dmaWriteSrv,
    PipeOut#(PayloadConReq) payloadConReqPipeIn
)(PayloadConsumer);
    FIFOF#(PayloadConReq)    consumeReqQ <- mkFIFOF;
    FIFOF#(PayloadConResp)  consumeRespQ <- mkFIFOF;
    FIFOF#(PayloadConReq) pendingConReqQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let payloadBufPipeOut <- mkConnectPipeOut2Q(payloadPipeIn, payloadBufQ);

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);

    function Action checkIsFirstPayloadDataStream(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            immAssert(
                payload.isFirst,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    function Action checkIsOnlyPayloadFragment(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            immAssert(
                payload.isFirst && payload.isLast,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    "and payload.isLast=", fshow(payload.isLast),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    function Action sendDmaWriteReq(
        PayloadConReq consumeReq, DataStream payload
    );
        action
            case (consumeReq.consumeInfo) matches
                tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                    let dmaWriteReq = DmaWriteReq {
                        metaData  : sendWriteReqReadRespInfo,
                        dataStream: payload
                    };
                    // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));
                    dmaWriteSrv.request.put(dmaWriteReq);
                end
                tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                    let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                    let dmaWriteReq = DmaWriteReq {
                        metaData   : atomicRespDmaWriteMetaData,
                        dataStream : DataStream {
                            data   : zeroExtendLSB(atomicRespPayload),
                            byteEn : genByteEn(fromInteger(valueOf(ATOMIC_WORK_REQ_LEN))),
                            isFirst: True,
                            isLast : True
                        }
                    };
                    dmaWriteSrv.request.put(dmaWriteReq);
                end
                default: begin
                    immAssert(
                        isDiscardPayload(consumeReq.consumeInfo),
                        "isDiscardPayload assertion @ mkPayloadConsumer",
                        $format(
                            "consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo),
                            " should be DiscardPayload"
                        )
                    );
                end
            endcase
        endaction
    endfunction

    // TODO: should receive discard request even when error state
    rule recvReq; // if (cntrl.isNonErr);
        let consumeReq = payloadConReqPipeIn.first;
        payloadConReqPipeIn.deq;

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayload: begin
                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is DiscardPayload",
                        consumeReq.fragNum
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                immAssert(
                    atomicRespDmaWriteMetaData.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                    "atomicRespDmaWriteMetaData.len assertion @ mkPayloadConsumer",
                    $format(
                        "atomicRespDmaWriteMetaData.len=%h should be %h when consumeInfo is AtomicRespInfoAndPayload",
                        atomicRespDmaWriteMetaData.len, valueOf(ATOMIC_WORK_REQ_LEN)
                    )
                );
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo    : begin
                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is SendWriteReqReadRespInfo",
                        consumeReq.fragNum
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        consumeReqQ.enq(consumeReq);
    endrule

    rule processReq if (!busyReg); // if (cntrl.isNonErr && !busyReg);
        let consumeReq = consumeReqQ.first;
        // $display("time=%0t: consumeReq=", $time, fshow(consumeReq));

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayload: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;

                if (isLessOrEqOne(consumeReq.fragNum)) begin
                    checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                    consumeReqQ.deq;
                    // pendingConReqQ.enq(consumeReq);
                end
                else begin
                    remainingFragNumReg <= consumeReq.fragNum - 2;
                    busyReg <= True;
                end
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                consumeReqQ.deq;
                pendingConReqQ.enq(consumeReq);
                sendDmaWriteReq(consumeReq, dontCareValue);
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;
                if (isLessOrEqOne(consumeReq.fragNum)) begin
                    checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                    consumeReqQ.deq;
                    pendingConReqQ.enq(consumeReq);
                    // $display(
                    //     "time=%0t: single packet response consumeReq.fragNum=%0d",
                    //     $time, consumeReq.fragNum
                    // );
                end
                else begin
                    // checkIsFirstPayloadDataStream(payload, consumeReq.consumeInfo);
                    immAssert(
                        payload.isFirst,
                        "only payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isFirst=", fshow(payload.isFirst),
                            " should be true when consumeInfo=",
                            fshow(consumeReq.consumeInfo)
                        )
                    );

                    remainingFragNumReg <= consumeReq.fragNum - 2;
                    busyReg <= True;
                    // $display(
                    //     "time=%0t: multi-packet response remainingFragNumReg=%0d, change to busy",
                    //     $time, consumeReq.fragNum - 1
                    // );
                end

                sendDmaWriteReq(consumeReq, payload);
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase
    endrule

    rule consumePayload if (busyReg); // if (cntrl.isNonErr && busyReg);
        let consumeReq = consumeReqQ.first;
        let payload = payloadBufPipeOut.first;
        payloadBufPipeOut.deq;
        remainingFragNumReg <= remainingFragNumReg - 1;
        // $display(
        //     "time=%0t: multi-packet response remainingFragNumReg=%0d, payload.isLast=",
        //     $time, remainingFragNumReg, fshow(payload.isLast)
        // );

        if (isZero(remainingFragNumReg)) begin
            immAssert(
                payload.isLast,
                "payload.isLast assertion @ mkPayloadConsumer",
                $format(
                    "payload.isLast=", fshow(payload.isLast),
                    " should be true when remainingFragNumReg=%h is zero",
                    remainingFragNumReg
                )
            );

            consumeReqQ.deq;
            if (consumeReq.consumeInfo matches tagged SendWriteReqReadRespInfo .info) begin
                // Only non-atomic might have multi-fragment payload data to consume
                pendingConReqQ.enq(consumeReq);
            end
            busyReg <= False;
        end

        sendDmaWriteReq(consumeReq, payload);
    endrule

    rule genResp if (cntrl.isNonErr);
        let dmaWriteResp <- dmaWriteSrv.response.get;
        let consumeReq = pendingConReqQ.first;
        pendingConReqQ.deq;
        // $display(
        //     "time=%0t: dmaWriteResp=", $time, fshow(dmaWriteResp),
        //     ", consumeReq=", fshow(consumeReq)
        // );

        case (consumeReq.consumeInfo) matches
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let consumeResp = PayloadConResp {
                    initiator    : consumeReq.initiator,
                    dmaWriteResp : DmaWriteResp {
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : sendWriteReqReadRespInfo.sqpn,
                        psn      : sendWriteReqReadRespInfo.psn
                    }
                };
                consumeRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == sendWriteReqReadRespInfo.sqpn &&
                    dmaWriteResp.psn  == sendWriteReqReadRespInfo.psn,
                    "dmaWriteResp SQPN and PSN assertion @ mkPayloadConsumer",
                    $format(
                        "dmaWriteResp.sqpn=%h should == sendWriteReqReadRespInfo.sqpn=%h",
                        dmaWriteResp.sqpn, sendWriteReqReadRespInfo.sqpn,
                        ", and dmaWriteResp.psn=%h should == sendWriteReqReadRespInfo.psn=%h",
                        dmaWriteResp.psn, sendWriteReqReadRespInfo.psn
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let consumeResp = PayloadConResp {
                    initiator    : consumeReq.initiator,
                    dmaWriteResp : DmaWriteResp {
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : atomicRespDmaWriteMetaData.sqpn,
                        psn      : atomicRespDmaWriteMetaData.psn
                    }
                };
                // $display("time=%0t: consumeResp=", $time, fshow(consumeResp));
                consumeRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == atomicRespDmaWriteMetaData.sqpn &&
                    dmaWriteResp.psn  == atomicRespDmaWriteMetaData.psn,
                    "dmaWriteResp SQPN and PSN assertion @ ",
                    $format(
                        "dmaWriteResp.sqpn=%h should == atomicRespDmaWriteMetaData.sqpn=%h",
                        dmaWriteResp.sqpn, atomicRespDmaWriteMetaData.sqpn,
                        ", and dmaWriteResp.psn=%h should == atomicRespDmaWriteMetaData.psn=%h",
                        dmaWriteResp.psn, atomicRespDmaWriteMetaData.psn
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase
    endrule

    rule flushPayloadConResp if (cntrl.isERR);
        consumeRespQ.clear;
    endrule
/*
    // TODO: safe error flush that finish pending requests before flush
    rule flushPayload if (cntrl.isERR);
        // When error, continue send DMA write requests,
        // so as to flush payload data properly laster.
        // But discard DMA write responses when error.
        if (payloadBufPipeOut.notEmpty) begin
            payloadBufPipeOut.deq;
        end
        consumeReqQ.clear;
        consumeRespQ.clear;
    endrule
*/
    interface respPipeOut = convertFifo2PipeOut(consumeRespQ);
endmodule

module mkAtomicOp#(
    PipeOut#(AtomicOpReq) atomicOpReqPipeIn
)(PipeOut#(AtomicOpResp));
    FIFOF#(AtomicOpResp) atomicOpRespQ <- mkFIFOF;

    rule genResp;
        let atomicOpReq = atomicOpReqPipeIn.first;
        atomicOpReqPipeIn.deq;
        // TODO: implement atomic operations
        let atomicOpResp = AtomicOpResp {
            initiator: atomicOpReq.initiator,
            original : atomicOpReq.compData,
            sqpn     : atomicOpReq.sqpn,
            psn      : atomicOpReq.psn
        };
        atomicOpRespQ.enq(atomicOpResp);
    endrule

    return convertFifo2PipeOut(atomicOpRespQ);
endmodule
