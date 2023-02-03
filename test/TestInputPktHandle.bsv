import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import Settings :: *;
import SimGenRdmaReqAndResp :: *;
import Utils :: *;
import Utils4Test :: *;

module mkInputPktBuf#(
    DataStreamPipeOut rdmaPktPipeIn,
    MetaDataQPs qpMetaData
)(RdmaPktMetaDataAndPayloadPipeOut);
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaPktPipeIn
    );
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    return pktMetaDataAndPayloadPipeOut;
endmodule

(* synthesize *)
module mkTestReceiveCNP(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);
    let cnpDataStream = buildCNP(cntrl);
    let cnpDataStreamPipeIn <- mkConstantPipeOut(cnpDataStream);
    let dut <- mkInputPktBuf(cnpDataStreamPipeIn, qpMetaData);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkCNP;
        let cnpBth = dut.cnpPipeOut.first;
        dut.cnpPipeOut.deq;
        dynAssert(
            { pack(cnpBth.trans), pack(cnpBth.opcode) } == fromInteger(valueOf(ROCE_CNP)),
            "CNP assertion @ mkTestReceiveCNP",
            $format(
                "cnpBth.trans=", fshow(cnpBth.trans),
                " cnpBth.opcode=", fshow(cnpBth.opcode),
                " not match ROCE_CNP=%h", valueOf(ROCE_CNP)
            )
        );
        dynAssert(
            !dut.pktMetaData.notEmpty && !dut.payload.notEmpty,
            "no PktMetaData and payload assertion @ mkTestReceiveCNP",
            $format(
                "dut.pktMetaData.notEmpty=", fshow(dut.pktMetaData.notEmpty),
                " and dut.payload.notEmpty=", fshow(dut.payload.notEmpty),
                " should both be false"
            )
        );
        countDown.decr;
    endrule
endmodule

module mkTestCalculatePktLen#(
    QpType qpType,
    PMTU pmtu,
    Length minPayloadLen,
    Length maxPayloadLen
)(Empty);
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);

    // Generate RDMA requests
    let reqGenSQ <- mkSimGenRdmaReq(
        newPendingWorkReqPipeOut, qpType, pmtu
    );
    let pendingWorkReqPipeOut4Ref <- mkBufferN(4, reqGenSQ.pendingWorkReqPipeOut);
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );

    // QP metadata
    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);

    // DUT
    let dut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let pktMetaDataPipeOut = dut.pktMetaData;

    // Payload sink
    let payloadSink <- mkSink(dut.payload);
    Reg#(Length) pktLenSumReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareWorkReqLen;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        let pktMetaData = pktMetaDataPipeOut.first;
        pktMetaDataPipeOut.deq;

        let bth = extractBTH(pktMetaData.pktHeader.headerData);
        let pktLenSum = pktLenSumReg;
        if (isFirstOrOnlyRdmaOpCode(bth.opcode)) begin
            pktLenSum = zeroExtend(pktMetaData.pktPayloadLen);
        end
        else begin
            pktLenSum = pktLenSumReg + zeroExtend(pktMetaData.pktPayloadLen);
        end
        pktLenSumReg <= pktLenSum;

        if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
            pendingWorkReqPipeOut4Ref.deq;
            // $display("time=%0d: PendingWorkReq=", $time, fshow(pendingWR));

            if (isReadWorkReq(pendingWR.wr.opcode) || isAtomicWorkReq(pendingWR.wr.opcode)) begin
                dynAssert(
                    isZero(pktLenSum),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format("pktLenSum=%0d should be zero", pktLenSum)
                );
            end
            else begin
                // Length pktPadCnt = zeroExtend(bth.padCnt);
                dynAssert(
                    pktLenSum == pendingWR.wr.len,
                    // pktLenSum == (pendingWR.wr.len + pktPadCnt),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format(
                        "pktLenSum=%0d should == pendingWR.wr.len=%0d",
                        pktLenSum, pendingWR.wr.len
                        // "pktLenSum=%0d should == pendingWR.wr.len=%0d + pktPadCnt=%0d",
                        // pktLenSum, pendingWR.wr.len, pktPadCnt
                    )
                );
            end
        end

        dynAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(bth.opcode, pendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestCalculatePktLen",
            $format(
                "rdmaOpCode=", fshow(bth.opcode),
                " should match workReqOpCode=", fshow(pendingWR.wr.opcode)
            )
        );

        // Decrement the count down counter when zero payload length,
        // since ReqGenSQ will not send zero payload length request to DMA.
        if (maxPayloadLen == 0) begin
            countDown.decr;
        end
        // $display("time=%0d: pending WR=", $time, fshow(pendingWR));
    endrule
endmodule

(* synthesize *)
module mkTestCalculateRandomPktLen(Empty);
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;
    Length minPayloadLen = 1;
    Length maxPayloadLen = 1025;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* synthesize *)
module mkTestCalculatePktLenEqPMTU(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = fromInteger(getPmtuLogValue(pmtu));
    Length maxPayloadLen = fromInteger(getPmtuLogValue(pmtu));

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule

(* synthesize *)
module mkTestCalculateZeroPktLen(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;
    Length minPayloadLen = 0;
    Length maxPayloadLen = 0;

    let ret <- mkTestCalculatePktLen(
        qpType, pmtu, minPayloadLen, maxPayloadLen
    );
endmodule
