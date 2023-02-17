import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import Utils :: *;

function Bool checkZeroFields4BTH(BTH bth);
    let bthRsvdCheck =
        isZero(pack(bth.tver))  &&
        isZero(pack(bth.fecn))  &&
        isZero(pack(bth.becn))  &&
        isZero(pack(bth.resv6)) &&
        isZero(pack(bth.resv7));
    return bthRsvdCheck;
endfunction

function Bool padCntCheckReqHeader(BTH bth);
    let zeroPadCntCheck = isZero(bth.padCnt);

    return case (bth.opcode)
        SEND_FIRST, SEND_MIDDLE            : zeroPadCntCheck;
        SEND_LAST, SEND_ONLY               ,
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           ,
        SEND_LAST_WITH_INVALIDATE          ,
        SEND_ONLY_WITH_INVALIDATE          : True;

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: zeroPadCntCheck;
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE     ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : True;

        RDMA_READ_REQUEST                  ,
        COMPARE_SWAP                       ,
        FETCH_ADD                          : zeroPadCntCheck;

        default                            : False;
    endcase;
endfunction

// TODO: verify that read/atomic response can only have normal AETH code
function Bool padCntCheckRespHeader(BTH bth, AETH aeth);
    let zeroPadCntCheck = isZero(bth.padCnt);

    case (bth.opcode)
        RDMA_READ_RESPONSE_MIDDLE: return zeroPadCntCheck;
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : return aeth.code == AETH_CODE_ACK;
        RDMA_READ_RESPONSE_FIRST ,
        ATOMIC_ACKNOWLEDGE       : return aeth.code == AETH_CODE_ACK && zeroPadCntCheck;
        ACKNOWLEDGE              : case (aeth.code)
            AETH_CODE_ACK,
            AETH_CODE_RNR: return zeroPadCntCheck;
            AETH_CODE_NAK: return case (aeth.value)
                zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                zeroExtend(pack(AETH_NAK_INV_REQ)),
                zeroExtend(pack(AETH_NAK_RMT_ACC)),
                zeroExtend(pack(AETH_NAK_RMT_OP)) ,
                zeroExtend(pack(AETH_NAK_INV_RD)) : zeroPadCntCheck;
                default                           : False;
            endcase;
            // AETH_CODE_RSVD
            default: return False;
        endcase
        default: return False;
    endcase
endfunction

function Bool validateHeader(TransType transType, QKEY qkey, Controller cntrl, Bool isRespPkt);
    let transTypeMatch = transTypeMatchQpType(transType, cntrl.getQpType);
    let qpStateMatch = isRespPkt ? cntrl.isRTS : cntrl.isNonErr;
    // UD has no responses
    let qKeyMatch = transType == TRANS_TYPE_UD ? qkey == cntrl.getQKEY : True;
    // TODO: verify RoCEv2 only use default PKEY
    // let pKeyMatch = isDefaultPKEY(cntrl.getPKEY);
    return transTypeMatch && qpStateMatch && qKeyMatch;
endfunction

interface HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut;
    interface HeaderDataStreamAndMetaDataPipeOut headerAndMetaData;
    interface DataStreamPipeOut payload;
endinterface

// After extract header from rdmaPktPipeIn,
// it outputs header DataStream and payload DataStream,
// and every header DataStream has corresponding payload DataStream,
// if header has no payload, then output empty payload DataStream.
// This module will not discard invalid packet.
module mkExtractHeaderFromRdmaPktPipeOut#(
    DataStreamPipeOut rdmaPktPipeIn
)(HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut);
    FIFOF#(HeaderMetaData) headerMetaDataInQ <- mkFIFOF;
    FIFOF#(DataStream) dataInQ <- mkFIFOF;

    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(headerMetaDataInQ));
    let headerMetaDataPipeIn = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut = headerMetaDataPipeOutVec[1];
    let dataPipeIn = convertFifo2PipeOut(dataInQ);
    let headerAndPayloadPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataPipeIn, headerMetaDataPipeIn
    );

    rule extractHeader;
        let rdmaPktDataStream = rdmaPktPipeIn.first;
        rdmaPktPipeIn.deq;
        dataInQ.enq(rdmaPktDataStream);

        if (rdmaPktDataStream.isFirst) begin
            let { transType, rdmaOpCode } =
                extractTranTypeAndRdmaOpCode(rdmaPktDataStream.data);

            let headerHasPayload = rdmaOpCodeHasPayload(rdmaOpCode);
            HeaderByteNum headerLen = fromInteger(
                calcHeaderLenByTransTypeAndRdmaOpCode(transType, rdmaOpCode)
            );
            immAssert(
                !isZero(headerLen),
                "!isZero(headerLen) assertion @ mkExtractHeaderFromRdmaPktPipeOut",
                $format(
                    "headerLen=%0d should not be zero, transType=",
                    headerLen, fshow(transType),
                    ", rdmaOpCode=", fshow(rdmaOpCode)
                )
            );

            let headerMetaData = genHeaderMetaData(headerLen, headerHasPayload);
            headerMetaDataInQ.enq(headerMetaData);
            // $display(
            //     "time=%0t: extractHeader", $time,
            //     ", headerLen=%0d, transType=", headerLen, fshow(transType),
            //     ", rdmaOpCode=", fshow(rdmaOpCode),
            //     ", rdmaPktDataStream=", fshow(rdmaPktDataStream),
            //     ", headerHasPayload=", fshow(headerHasPayload),
            //     ", headerMetaData=", fshow(headerMetaData)
            // );
        end
        // $display("time=%0t: rdmaPktDataStream=", $time, fshow(rdmaPktDataStream));
    endrule

    interface headerAndMetaData = interface HeaderDataStreamAndMetaDataPipeOut;
        interface headerDataStream = headerAndPayloadPipeOut.header;
        interface headerMetaData = headerMetaDataPipeOut;
    endinterface;
    interface payload = headerAndPayloadPipeOut.payload;
endmodule

interface RdmaPktMetaDataAndPayloadPipeOut;
    interface PipeOut#(RdmaPktMetaData) pktMetaData;
    interface DataStreamPipeOut payload;
endinterface

interface InputRdmaPktBuf;
    interface RdmaPktMetaDataAndPayloadPipeOut reqPktPipeOut;
    interface RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut;
    interface PipeOut#(BTH) cnpPipeOut;
endinterface

typedef enum {
    RDMA_PKT_BUF_ST_RECV_FRAG,
    RDMA_PKT_BUF_ST_DISCARD_FRAG
} RdmaPktBufState deriving(Bits, Eq);
// This module will discard:
// - invalid packet that header is without payload but packet has payload;
// TODO: check write requests have non-zero RETH.dlen but without payload
// TODO: check remote XRC domain and XRCETH valid?
// TODO: reset mkInputRdmaPktBufAndHeaderValidation when error or retry?
module mkInputRdmaPktBufAndHeaderValidation#(
    // Only output payload when packet has non-zero payload,
    // otherwise output packet header/metadata only,
    // namely header and payload are not one-to-one mapping,
    // and packet header/metadata is aligned to the last fragment of payload.
    HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut pipeIn,
    MetaDataQPs qpMetaData
)(InputRdmaPktBuf);
    FIFOF#(BTH)                         cnpOutQ <- mkFIFOF;
    FIFOF#(DataStream)           reqPayloadOutQ <- mkFIFOF;
    FIFOF#(RdmaPktMetaData)  reqPktMetaDataOutQ <- mkFIFOF;
    FIFOF#(DataStream)          respPayloadOutQ <- mkFIFOF;
    FIFOF#(RdmaPktMetaData) respPktMetaDataOutQ <- mkFIFOF;

    // Pipeline buffers
    FIFOF#(Tuple2#(RdmaHeader, BTH))                   rdmaHeaderValidationQ <- mkFIFOF;
    FIFOF#(DataStream)                                    payloadValidationQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaHeader, BTH, PdHandler, PMTU)) rdmaHeaderFragLenCalcQ <- mkFIFOF;
    FIFOF#(DataStream)                                   payloadFragLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaHeader, BTH, PdHandler, PMTU))  rdmaHeaderPktlenCalcQ <- mkFIFOF;
    FIFOF#(Tuple5#(DataStream, ByteEnBitNum, ByteEnBitNum, Bool, Bool)) payloadPktlenCalcQ <- mkFIFOF;

    Reg#(Bool)        isValidPktReg <- mkRegU;
    Reg#(PAD)          bthPadCntReg <- mkRegU;
    Reg#(PmtuFragNum) pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    Reg#(RdmaPktBufState) pktBufStateReg <- mkReg(RDMA_PKT_BUF_ST_RECV_FRAG);

    let payloadPipeIn <- mkBufferN(2, pipeIn.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        pipeIn.headerAndMetaData.headerDataStream,
        pipeIn.headerAndMetaData.headerMetaData
    );

    rule recvPktFrag if (pktBufStateReg == RDMA_PKT_BUF_ST_RECV_FRAG);
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;
        let payloadHasSingleFrag = payloadFrag.isFirst && payloadFrag.isLast;
        let fragHasNoData = isZero(payloadFrag.byteEn);

        let rdmaHeader = rdmaHeaderPipeOut.first;
        let bth        = extractBTH(rdmaHeader.headerData);
        let aeth       = extractAETH(rdmaHeader.headerData);

        let bthCheckResult = checkZeroFields4BTH(bth);
        let headerCheckResult =
            padCntCheckReqHeader(bth) || padCntCheckRespHeader(bth, aeth);
        // Discard packet that should not have payload
        let nonPayloadHeaderShouldHaveNoPayload =
            rdmaHeader.headerMetaData.hasPayload ?
                True : (payloadHasSingleFrag && fragHasNoData);
        // TODO: find out why following display leads to deadlock?
        // $display(
        //     "time=%0t: bthCheckResult=", $time, fshow(bthCheckResult),
        //     ", headerCheckResult=", fshow(headerCheckResult),
        //     ", nonPayloadHeaderShouldHaveNoPayload=", fshow(nonPayloadHeaderShouldHaveNoPayload),
        //     ", bth=", fshow(bth), ", aeth=", fshow(aeth)
        // );

        if (payloadFrag.isFirst) begin
            rdmaHeaderPipeOut.deq;

            if (bthCheckResult && headerCheckResult && nonPayloadHeaderShouldHaveNoPayload) begin
                // Packet header is valid
                rdmaHeaderValidationQ.enq(tuple2(rdmaHeader, bth));
                payloadValidationQ.enq(payloadFrag);

                // $display(
                //     "time=%0t: bth=", $time, fshow(bth),
                //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData),
                //     "\ntime=%0t: payloadFrag=", $time, fshow(payloadFrag)
                // );
            end
            else begin
                if (!payloadFrag.isLast) begin
                    $warning(
                        "time=%0t: discard invalid RDMA packet of multi-fragment payload", $time
                    );
                    pktBufStateReg <= RDMA_PKT_BUF_ST_DISCARD_FRAG;
                end
                else begin
                    $warning(
                        "time=%0t: discard invalid RDMA packet of single-fragment payload", $time
                    );
                end
            end
        end
        else begin
            payloadValidationQ.enq(payloadFrag);
            // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    rule discardInvalidFrag if (pktBufStateReg == RDMA_PKT_BUF_ST_DISCARD_FRAG);
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        if (payload.isLast) begin
            pktBufStateReg <= RDMA_PKT_BUF_ST_RECV_FRAG;
        end
    endrule

    rule checkQpMetaData;
        let payloadFrag = payloadValidationQ.first;
        payloadValidationQ.deq;

        let isValidPkt = isValidPktReg;

        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth } = rdmaHeaderValidationQ.first;
            rdmaHeaderValidationQ.deq;

            let isCNP = isCongestionNotificationPkt(bth);
            let deth = extractDETH(rdmaHeader.headerData);
            let xrceth = extractXRCETH(rdmaHeader.headerData);

            // CNP is also RDMA response
            let isRespPkt = isRdmaRespOpCode(bth.opcode) || isCNP;
            // If XRC requests, DQPN is defined in XRCETH, otherwise in BTH
            let dqpn = (bth.trans == TRANS_TYPE_XRC && !isRespPkt) ? xrceth.srqn : bth.dqpn;

            let maybePdHandler = qpMetaData.getPD(dqpn);
            // let isValidDQPN = isValid(maybePdHandler);
            let cntrl = qpMetaData.getCntrl(dqpn);
            if (maybePdHandler matches tagged Valid .pdHandler) begin
                let validateResult = validateHeader(bth.trans, deth.qkey, cntrl, isRespPkt);
                if (validateResult) begin
                    if (!isCNP) begin
                        rdmaHeaderFragLenCalcQ.enq(tuple4(
                            rdmaHeader, bth, pdHandler, cntrl.getPMTU
                        ));
                    end
                    else begin
                        cnpOutQ.enq(bth);
                    end
                end
                isValidPkt = validateResult && !isCNP;
            end

            isValidPktReg <= isValidPkt;
        end

        if (isValidPkt) begin
            payloadFragLenCalcQ.enq(payloadFrag);
        end
    endrule

    rule calcFraglen;
        let payloadFrag = payloadFragLenCalcQ.first;
        payloadFragLenCalcQ.deq;

        let bthPadCnt = bthPadCntReg;
        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth, pdHandler, pmtu } = rdmaHeaderFragLenCalcQ.first;
            rdmaHeaderFragLenCalcQ.deq;

            // let bth = extractBTH(rdmaHeader.headerData);
            bthPadCnt = bth.padCnt;
            bthPadCntReg <= bthPadCnt;

            rdmaHeaderPktlenCalcQ.enq(tuple4(rdmaHeader, bth, pdHandler, pmtu));

            // $display(
            //     "time=%0t: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
            //     $time, payloadFrag.byteEn, fshow(payloadFrag.isFirst),
            //     ", payloadFrag.isLast=", payloadFrag.isLast, ", bth.psn=%h", bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode), ", bth.padCnt=%h", bth.padCnt,
            //     ", payloadFrag.data=%h", payloadFrag.data
            // );
        end

        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        immAssert(
            isValid(payloadFragLen),
            "isValid(payloadFragLen) assertion @ mkInputRdmaPktBufAndHeaderValidation",
            $format(
                "payloadFragLen=", fshow(payloadFragLen), " should be valid"
            )
        );
        let fragLen         = unwrapMaybe(payloadFragLen);
        let isByteEnNonZero = !isZero(fragLen);
        let isByteEnAllOne  = isAllOnes(payloadFrag.byteEn);
        ByteEnBitNum fragLenWithOutPad = fragLen - zeroExtend(bthPadCnt);

        payloadPktlenCalcQ.enq(tuple5(
            payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        ));
    endrule

    rule calcPktLen;
        let {
            payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        } = payloadPktlenCalcQ.first;
        payloadPktlenCalcQ.deq;

        let { rdmaHeader, bth, pdHandler, pmtu } = rdmaHeaderPktlenCalcQ.first;
        let isRespPkt       = isRdmaRespOpCode(bth.opcode);
        let isLastPkt       = isLastRdmaOpCode(bth.opcode);
        let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);
        let isLastOrOnlyPkt = isLastOrOnlyRdmaOpCode(bth.opcode);

        // $display(
        //     "time=%0t: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
        //     $time, payloadFrag.byteEn, fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", payloadFrag.isLast, ", bth.psn=%h", bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode), ", bth.padCnt=%h", bth.padCnt,
        //     ", payloadFrag.data=%h", payloadFrag.data
        // );

        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;

        PktLen fragLenExt = zeroExtend(fragLen);
        PktLen fragLenExtWithOutPad = zeroExtend(fragLenWithOutPad);
        case ({ pack(payloadFrag.isFirst), pack(payloadFrag.isLast) })
            2'b11: begin // payloadFrag.isFirst && payloadFrag.isLast
                pktLen = fragLenExtWithOutPad;
                pktFragNum = 1;
                pktValid = (isFirstOrMidPkt ? False : (isLastPkt ? isByteEnNonZero : True));
            end
            2'b10: begin // payloadFrag.isFirst && !payloadFrag.isLast
                pktLen = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = 1;
                pktValid = isByteEnAllOne;
            end
            2'b01: begin // !payloadFrag.isFirst && payloadFrag.islast
                pktLen = pktLenReg + fragLenExtWithOutPad;
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg;
            end
            2'b00: begin // !payloadFrag.isFirst && !payloadFrag.islast
                // TODO: reduce addition bit-wideth
                pktLen = pktLenReg + fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg && isByteEnAllOne;
            end
        endcase

        pktLenReg <= pktLen;
        pktFragNumReg <= pktFragNum;
        pktValidReg <= pktValid;
        // $display(
        //     "time=%0t: pktLen=%0d, pktFragNum=%0d", $time, pktLen, pktFragNum,
        //     ", byteEn=%h", payloadFrag.byteEn, ", isByteEnAllOne=", fshow(isByteEnAllOne),
        //     ", pktValid=", fshow(pktValid),
        //     ", payloadOutQ.notFull=", fshow(payloadOutQ.notFull)
        //     // ", pktMetaDataOutQ.notFull=", fshow(pktMetaDataOutQ.notFull),
        //     ", DATA_STREAM_FRAG_BUF_SIZE=%0d", valueOf(DATA_STREAM_FRAG_BUF_SIZE),
        //     ", PKT_META_DATA_BUF_SIZE=%0d", valueOf(PKT_META_DATA_BUF_SIZE)
        // );

        let pktStatus = PKT_ST_VALID;
        if (payloadFrag.isLast) begin
            rdmaHeaderPktlenCalcQ.deq;

            let isZeroPayloadLen = isZero(pktLen);
            if (!isZeroPayloadLen) begin
                if (isRespPkt) begin
                    respPayloadOutQ.enq(payloadFrag);
                end
                else begin
                    reqPayloadOutQ.enq(payloadFrag);
                end
                // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
            end
            else begin
                // Discard zero length payload no matter packet has payload or not
                // $info("time=%0t: discard zero-length payload for RDMA packet", $time);
            end

            if (pktValid) begin
                pktValid =
                    (isFirstOrMidPkt && pktLenEqPMTU(pktLen, pmtu)) ||
                    (isLastOrOnlyPkt && !pktLenGtPMTU(pktLen, pmtu));
                // $display(
                //     "time=%0t: pktLen=%0d", $time, pktLen,
                //     ", pmtu=", fshow(pmtu), ", pktValid=", fshow(pktValid)
                // );
            end
            if (!pktValid) begin
                // Invalid packet length
                pktStatus = PKT_ST_LEN_ERR;
            end
            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen: pktLen,
                pktFragNum   : (isZeroPayloadLen ? 0 : pktFragNum),
                pktHeader    : rdmaHeader,
                pdHandler    : pdHandler,
                pktValid     : pktValid,
                pktStatus    : pktStatus
            };
            if (isRespPkt) begin
                respPktMetaDataOutQ.enq(pktMetaData);
            end
            else begin
                reqPktMetaDataOutQ.enq(pktMetaData);
            end
            // $display(
            //     "time=%0t: bth=", $time, fshow(bth), ", pktMetaData=", fshow(pktMetaData)
            // );
        end
        else begin
            if (isRespPkt) begin
                respPayloadOutQ.enq(payloadFrag);
            end
            else begin
                reqPayloadOutQ.enq(payloadFrag);
            end
            // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    interface reqPktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
        interface pktMetaData = convertFifo2PipeOut(reqPktMetaDataOutQ);
        interface payload     = convertFifo2PipeOut(reqPayloadOutQ);
    endinterface;

    interface respPktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
        interface pktMetaData = convertFifo2PipeOut(respPktMetaDataOutQ);
        interface payload     = convertFifo2PipeOut(respPayloadOutQ);
    endinterface;

    interface cnpPipeOut  = convertFifo2PipeOut(cnpOutQ);
endmodule
