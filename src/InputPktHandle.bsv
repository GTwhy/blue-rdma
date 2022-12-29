import BRAMFIFO :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import Utils :: *;

function Bool checkBTH(BTH bth);
    let bthRsvdCheck =
        isZero(pack(bth.tver))  &&
        isZero(pack(bth.fecn))  &&
        isZero(pack(bth.becn))  &&
        isZero(pack(bth.resv6)) &&
        isZero(pack(bth.resv7));
    return bthRsvdCheck;
endfunction

// TODO: implement request header verification
// TODO: check QP supported operation
function Bool checkRdmaReqHeader(BTH bth, RETH reth, AtomicEth atomicEth);
    let padCntCheck = isZero(bth.padCnt);

    return case (bth.opcode)
        SEND_FIRST, SEND_MIDDLE            : padCntCheck;
        SEND_LAST, SEND_ONLY               ,
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           ,
        SEND_LAST_WITH_INVALIDATE          ,
        SEND_ONLY_WITH_INVALIDATE          : True;

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: padCntCheck;
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE     ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : True;

        RDMA_READ_REQUEST                  ,
        COMPARE_SWAP                       ,
        FETCH_ADD                          : True;

        default                            : False;
    endcase;
endfunction

// TODO: verify that read/atomic response can only have normal AETH code
function Bool checkRdmaRespHeader(BTH bth, AETH aeth);
    let padCntCheck = isZero(bth.padCnt);

    case (bth.opcode)
        RDMA_READ_RESPONSE_MIDDLE: return padCntCheck;
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : return aeth.code == AETH_CODE_ACK;
        RDMA_READ_RESPONSE_FIRST ,
        ATOMIC_ACKNOWLEDGE       : return aeth.code == AETH_CODE_ACK && padCntCheck;
        ACKNOWLEDGE              : case (aeth.code)
            AETH_CODE_ACK: return padCntCheck;
            AETH_CODE_RNR: return padCntCheck;
            AETH_CODE_NAK: return case (aeth.value)
                zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                zeroExtend(pack(AETH_NAK_INV_REQ)),
                zeroExtend(pack(AETH_NAK_RMT_ACC)),
                zeroExtend(pack(AETH_NAK_RMT_OP)) ,
                zeroExtend(pack(AETH_NAK_INV_RD)) : padCntCheck;
                default                           : False;
            endcase;
            // AETH_CODE_RSVD
            default: return False;
        endcase
        default: return False;
    endcase
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
            dynAssert(
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
            //     "time=%0d: headerLen=%0d, transType=", $time, headerLen, fshow(transType),
            //     ", rdmaOpCode=", fshow(rdmaOpCode),
            //     ", rdmaPktDataStream=", fshow(rdmaPktDataStream),
            //     ", headerHasPayload=", fshow(headerHasPayload),
            //     ", headerMetaData=", fshow(headerMetaData)
            // );
        end
        // $display("time=%0d: rdmaPktDataStream=", $time, fshow(rdmaPktDataStream));
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

typedef enum {
    RDMA_PKT_BUF_RECV_FRAG,
    RDMA_PKT_BUF_DISCARD_FRAG
} RdmaPktBufState deriving(Bits, Eq);
// This module will discard:
// - invalid packet that header is without payload but packet has payload;
// TODO: add PD to RdmaPktMetaData
// TODO: receive packet when init state
// TODO: check unsupported TransType
// TODO: check QKEY match for UD, otherwise drop
// TODO: check RETH dlen less than PMTU if only requests
// TODO: check write requests have non-zero RETH.dlen but without payload
// TODO: check remote XRC domain and XRCETH valid?
// TODO: check PKEY match
// TODO: discard BTH or AETH with reserved value, and packet validation
// TODO: check read/atomic response AETH code abnormal, not RNR or NAK code
// TODO: reset mkInputRdmaPktBufAndHeaderValidation when error or retry
module mkInputRdmaPktBufAndHeaderValidation#(
    // Only output payload when packet has non-zero payload,
    // otherwise output packet header/metadata only,
    // namely header and payload are not one-to-one mapping,
    // and packet header/metadata is aligned to the last fragment of payload.
    HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut pipeIn,
    QPs qpMetaData
)(RdmaPktMetaDataAndPayloadPipeOut);
    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStream)          payloadOutQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    FIFOF#(RdmaPktMetaData) pktMetaDataOutQ <- mkSizedFIFOF(valueOf(PKT_META_DATA_BUF_SIZE));

    FIFOF#(Tuple2#(RdmaHeader, BTH))                   rdmaHeaderValidationQ <- mkFIFOF;
    FIFOF#(DataStream)                                    payloadValidationQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaHeader, BTH, PdHandler, PMTU)) rdmaHeaderFragLenCalcQ <- mkFIFOF;
    FIFOF#(DataStream)                                   payloadFragLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaHeader, BTH, PdHandler, PMTU))  rdmaHeaderPktlenCalcQ <- mkFIFOF;
    FIFOF#(Tuple5#(DataStream, ByteEnBitNum, ByteEnBitNum, Bool, Bool)) payloadPktlenCalcQ <- mkFIFOF;

    Reg#(Bool)         isValidQpReg <- mkRegU;
    Reg#(PAD)          bthPadCntReg <- mkRegU;
    Reg#(PmtuFragNum) pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    Reg#(RdmaPktBufState) pktBufStateReg <- mkReg(RDMA_PKT_BUF_RECV_FRAG);

    let payloadPipeIn <- mkBufferN(2, pipeIn.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        pipeIn.headerAndMetaData.headerDataStream,
        pipeIn.headerAndMetaData.headerMetaData
    );

    rule recvPktFrag if (pktBufStateReg == RDMA_PKT_BUF_RECV_FRAG);
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;
        let payloadHasSingleFrag = payloadFrag.isFirst && payloadFrag.isLast;
        let fragHasNoData = isZero(payloadFrag.byteEn);

        let rdmaHeader = rdmaHeaderPipeOut.first;
        let bth        = extractBTH(rdmaHeader.headerData);
        let aeth       = extractAETH(rdmaHeader.headerData);
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let bthCheckResult = checkBTH(bth);
        let headerCheckResult =
            checkRdmaReqHeader(bth, reth, atomicEth) ||
            checkRdmaRespHeader(bth, aeth);
        // Discard packet that should not have payload
        let nonPayloadHeaderShouldHaveNoPayload =
            rdmaHeader.headerMetaData.hasPayload ?
                True : (payloadHasSingleFrag && fragHasNoData);
        // TODO: find out why following display leads to deadlock?
        // $display(
        //     "time=%0d: bthCheckResult=", $time, fshow(bthCheckResult),
        //     ", headerCheckResult=", fshow(headerCheckResult),
        //     ", nonPayloadHeaderShouldHaveNoPayload=", fshow(nonPayloadHeaderShouldHaveNoPayload),
        //     ", bth=", fshow(bth), ", aeth=", fshow(aeth)
        // );

        if (payloadFrag.isFirst) begin
            rdmaHeaderPipeOut.deq;

            // if (!bthCheckResult || !headerCheckResult || !nonPayloadHeaderShouldHaveNoPayload) begin
            if (bthCheckResult && headerCheckResult && nonPayloadHeaderShouldHaveNoPayload) begin
                // Packet header is valid
                rdmaHeaderValidationQ.enq(tuple2(rdmaHeader, bth));
                payloadValidationQ.enq(payloadFrag);

                // $display(
                //     "time=%0d: bth=", $time, fshow(bth),
                //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData),
                //     "\ntime=%0d: payloadFrag=", $time, fshow(payloadFrag)
                // );
            end
            else begin
                if (!payloadFrag.isLast) begin
                    $warning(
                        "time=%0d: discard invalid RDMA packet of multi-fragment payload", $time
                    );
                    pktBufStateReg <= RDMA_PKT_BUF_DISCARD_FRAG;
                end
                else begin
                    $warning(
                        "time=%0d: discard invalid RDMA packet of single-fragment payload", $time
                    );
                end
            end
        end
        else begin
            payloadValidationQ.enq(payloadFrag);
            // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    rule discardInvalidFrag if (pktBufStateReg == RDMA_PKT_BUF_DISCARD_FRAG);
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        if (payload.isLast) begin
            pktBufStateReg <= RDMA_PKT_BUF_RECV_FRAG;
        end
    endrule

    rule checkQpMetaData;
        let payloadFrag = payloadValidationQ.first;
        payloadValidationQ.deq;

        let isValidQP = isValidQpReg;
        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth } = rdmaHeaderValidationQ.first;
            rdmaHeaderValidationQ.deq;

            let maybePdHandler = qpMetaData.getPD(bth.dqpn);
            isValidQP = isValid(maybePdHandler);
            let cntrl = qpMetaData.getCntrl(bth.dqpn);
            if (maybePdHandler matches tagged Valid .pdHandler) begin
                rdmaHeaderFragLenCalcQ.enq(tuple4(
                    rdmaHeader, bth, pdHandler, cntrl.getPMTU
                ));
            end

            isValidQpReg <= isValidQP;
        end

        if (isValidQP) begin
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
            //     "time=%0d: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
            //     $time, payloadFrag.byteEn, fshow(payloadFrag.isFirst),
            //     ", payloadFrag.isLast=", payloadFrag.isLast, ", bth.psn=%h", bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode), ", bth.padCnt=%h", bth.padCnt,
            //     ", payloadFrag.data=%h", payloadFrag.data
            // );
        end

        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        dynAssert(
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

        payloadPktlenCalcQ.enq(tuple5(payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne));
    endrule

    rule calcPktLen;
        let { payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne } = payloadPktlenCalcQ.first;
        payloadPktlenCalcQ.deq;

        let { rdmaHeader, bth, pdHandler, pmtu } = rdmaHeaderPktlenCalcQ.first;
        // let bth = extractBTH(rdmaHeader.headerData);
        let isLastPkt = isLastRdmaOpCode(bth.opcode);
        let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);

        // $display(
        //     "time=%0d: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
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
        //     "time=%0d: pktLen=%0d, pktFragNum=%0d", $time, pktLen, pktFragNum,
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
                payloadOutQ.enq(payloadFrag);
                // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));
            end
            else begin
                // Discard zero length payload no matter packet has payload or not
                // $info("time=%0d: discard zero-length payload for RDMA packet", $time);
            end

            if (pktValid && isFirstOrMidPkt) begin
                pktValid = pktLenEqPMTU(pktLen, pmtu);
                // $display(
                //     "time=%0d: pktLen=%0d", $time, pktLen,
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
            pktMetaDataOutQ.enq(pktMetaData);
            // $display(
            //     "time=%0d: bth=", $time, fshow(bth), ", pktMetaData=", fshow(pktMetaData)
            // );
        end
        else begin
            payloadOutQ.enq(payloadFrag);
            // $display("time=%0d: payloadFrag=", $time, fshow(payloadFrag));
        end
    endrule

    interface pktMetaData = convertFifo2PipeOut(pktMetaDataOutQ);
    interface payload     = convertFifo2PipeOut(payloadOutQ);
endmodule
