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

(* synthesize *)
module mkTestReceiveCNP(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);
    let qpn = dontCareValue;
    let cntrl = qpMetaData.getCntrl(qpn);
    let cnpDataStream = buildCNP(cntrl);
    let cnpDataStreamPipeIn <- mkConstantPipeOut(cnpDataStream);
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        cnpDataStreamPipeIn
    );
    let dut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let reqPktMetaDataAndPayloadPipeOut = dut.reqPktPipeOut;
    let respPktMetaDataAndPayloadPipeOut = dut.respPktPipeOut;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkCNP;
        let cnpBth = dut.cnpPipeOut.first;
        dut.cnpPipeOut.deq;
        immAssert(
            { pack(cnpBth.trans), pack(cnpBth.opcode) } == fromInteger(valueOf(ROCE_CNP)),
            "CNP assertion @ mkTestReceiveCNP",
            $format(
                "cnpBth.trans=", fshow(cnpBth.trans),
                " cnpBth.opcode=", fshow(cnpBth.opcode),
                " not match ROCE_CNP=%h", valueOf(ROCE_CNP)
            )
        );

        immAssert(
            !reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
            !reqPktMetaDataAndPayloadPipeOut.payload.notEmpty,
            "reqPktMetaDataAndPayloadPipeOut assertion @ mkSimInputPktBuf",
            $format(
                "reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                fshow(reqPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                " and reqPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                fshow(reqPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                " should both be false"
            )
        );

        immAssert(
            !respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty &&
            !respPktMetaDataAndPayloadPipeOut.payload.notEmpty,
            "respPktMetaDataAndPayloadPipeOut assertion @ mkSimInputPktBuf",
            $format(
                "respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty=",
                fshow(respPktMetaDataAndPayloadPipeOut.pktMetaData.notEmpty),
                " and respPktMetaDataAndPayloadPipeOut.payload.notEmpty=",
                fshow(respPktMetaDataAndPayloadPipeOut.payload.notEmpty),
                " should both be false"
            )
        );
        // immAssert(
        //     !dut.pktMetaData.notEmpty && !dut.payload.notEmpty,
        //     "no PktMetaData and payload assertion @ mkTestReceiveCNP",
        //     $format(
        //         "dut.pktMetaData.notEmpty=", fshow(dut.pktMetaData.notEmpty),
        //         " and dut.payload.notEmpty=", fshow(dut.payload.notEmpty),
        //         " should both be false"
        //     )
        // );
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

    // QP metadata
    let qpMetaData <- mkSimMetaDataQPs(qpType, pmtu);

    // DUT
    let isRespPktPipeIn = False;
    let dut <- mkSimInputPktBuf(isRespPktPipeIn, rdmaReqPipeOut, qpMetaData);
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
            // $display("time=%0t: PendingWorkReq=", $time, fshow(pendingWR));

            if (isReadWorkReq(pendingWR.wr.opcode) || isAtomicWorkReq(pendingWR.wr.opcode)) begin
                immAssert(
                    isZero(pktLenSum),
                    "pktLenSum assertion @ mkTestCalculatePktLen",
                    $format("pktLenSum=%0d should be zero", pktLenSum)
                );
            end
            else begin
                // Length pktPadCnt = zeroExtend(bth.padCnt);
                immAssert(
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

        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(bth.opcode, pendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestCalculatePktLen",
            $format(
                "rdmaOpCode=", fshow(bth.opcode),
                " should match workReqOpCode=", fshow(pendingWR.wr.opcode)
            )
        );

        countDown.decr;
        // $display("time=%0t: pending WR=", $time, fshow(pendingWR));
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
