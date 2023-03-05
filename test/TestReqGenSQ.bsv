import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import InputPktHandle :: *;
import Headers :: *;
import PrimUtils :: *;
import ReqGenSQ :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

module mkTestReqGenNormalCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 1024;
    let result <- mkTestReqGenNormalAndZeroLenCase(minDmaLength, maxDmaLength);
endmodule

(* synthesize *)
module mkTestReqGenZeroLenCase(Empty);
    let minDmaLength = 0;
    let maxDmaLength = 0;
    let result <- mkTestReqGenNormalAndZeroLenCase(minDmaLength, maxDmaLength);
endmodule

module mkTestReqGenNormalAndZeroLenCase#(
    Length minDmaLength, Length maxDmaLength
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let setExpectedPsnAsNextPSN = False;
    let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);

    // WorkReq generation
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);
    let workReqPipeOut4Ref <- mkBufferN(4, workReqPipeOutVec[1]);

    // Request payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrv.dataStream, pmtuPipeOut
    );
    let segDataStreamPipeOut4Ref <- mkBufferN(4, segDataStreamPipeOut);

    let pendingWorkReqBufNotEmpty = True;
    // DUT
    let reqGenSQ <- mkReqGenSQ(
        cntrl,
        simDmaReadSrv.dmaReadSrv,
        newPendingWorkReqPipeOut,
        pendingWorkReqBufNotEmpty
    );
    Vector#(2, PipeOut#(PendingWorkReq)) pendingWorkReqPipeOutVec <-
        mkForkVector(reqGenSQ.pendingWorkReqPipeOut);
    let pendingWorkReqPipeOut4Comp = pendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Ref <- mkBufferN(2, pendingWorkReqPipeOutVec[1]);
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    // No error WC when normal case
    let errWorkCompGenReqPipeOut = reqGenSQ.workCompGenReqPipeOut;
    let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        errWorkCompGenReqPipeOut,
        "errWorkCompGenReqPipeOut empty assertion @ mkTestReqGenNormalCase"
    ));

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
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

    Reg#(PSN)    curPsnReg <- mkRegU;
    Reg#(Bool) validPsnReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareWorkReq;
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        immAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestReqGenNormalCase",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );
        // $display("time=%0t: WR=", $time, fshow(pendingWR.wr));
    endrule

    rule compareRdmaReqHeader;
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        // $display("time=%0t: BTH=", $time, fshow(bth));

        if (validPsnReg) begin
            curPsnReg <= curPsnReg + 1;

            immAssert(
                bth.psn == curPsnReg,
                "bth.psn correctness assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == curPsnReg=%h", bth.psn, curPsnReg)
            );
        end
        else begin
            curPsnReg <= bth.psn + 1;
        end

        let refPendingWR = pendingWorkReqPipeOut4Ref.first;
        let wrStartPSN = unwrapMaybe(refPendingWR.startPSN);
        let wrEndPSN = unwrapMaybe(refPendingWR.endPSN);

        if (isOnlyRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            let isReadWR = isReadWorkReq(refPendingWR.wr.opcode);
            if (isReadWR) begin
                immAssert(
                    bth.psn == wrStartPSN,
                    "bth.psn read request packet assertion @ mkTestReqGenNormalCase",
                    $format(
                        "bth.psn=%h should == wrStartPSN=%h when refPendingWR.wr.opcode=",
                        bth.psn, wrStartPSN, fshow(refPendingWR.wr.opcode)
                    )
                );
            end
            else begin
                immAssert(
                    bth.psn == wrStartPSN && bth.psn == wrEndPSN,
                    "bth.psn only request packet assertion @ mkTestReqGenNormalCase",
                    $format(
                        "bth.psn=%h should == wrStartPSN=%h and bth.psn=%h should == wrEndPSN=%h",
                        bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                        ", when refPendingWR.wr.opcode=",
                        fshow(refPendingWR.wr.opcode)
                    )
                );
            end
        end
        else if (isLastRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            immAssert(
                bth.psn == wrEndPSN,
                "bth.psn last request packet assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == wrEndPSN=%h", bth.psn, wrEndPSN)
            );
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn first request packet assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            immAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle request packet assertion @ mkTestReqGenNormalCase",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA request opcode"
                )
            );
            immAssert(
                psnInRangeExclusive(bth.psn, wrStartPSN, wrEndPSN),
                "bth.psn between wrStartPSN and wrEndPSN assertion @ mkTestReqGenNormalCase",
                $format(
                    "bth.psn=%h should > wrStartPSN=%h and bth.psn=%h should < wrEndPSN=%h",
                    bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                    ", when refPendingWR.wr.opcode=", fshow(refPendingWR.wr.opcode),
                    " and rdmaOpCode=", fshow(rdmaOpCode)
                )
            );
        end

        immAssert(
            transTypeMatchQpType(transType, qpType),
            "transTypeMatchQpType assertion @ mkTestReqGenNormalCase",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(qpType)
            )
        );
        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, refPendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestReqGenNormalCase",
            $format(
                "RDMA request opcode=", fshow(rdmaOpCode),
                " should match workReqOpCode=", fshow(refPendingWR.wr.opcode)
            )
        );

        // It must compare header not payload,
        // since WR might have zero length
        countDown.decr;
    endrule

    rule compareRdmaReqPayload;
        let payloadDataStream = filteredPayloadDataStreamPipeOut.first;
        filteredPayloadDataStreamPipeOut.deq;

        let refDataStream = segDataStreamPipeOut4Ref.first;
        segDataStreamPipeOut4Ref.deq;

        immAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestReqGenNormalCase",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule

(* synthesize *)
module mkTestReqGenDmaReadErrCase(Empty);
    let minDmaLength = 1024;
    let maxDmaLength = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let setExpectedPsnAsNextPSN = False;
    let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);
    Reg#(Bool) genErrWorkCompReg <- mkReg(False);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    // let { workReqPipeOut4Flush, workReqPipeOut4Dut } = deMuxPipeOut(
    //     genErrWorkCompReg, workReqPipeOutVec[0]
    // );
    let workReqPipeOut4Dut = workReqPipeOutVec[0];
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec4Dut <-
        mkForkVector(workReqPipeOut4Dut);
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec4Dut[0]);
    let workReqPipeOut4Ref = workReqPipeOutVec4Dut[1];

    // Request payload DataStream generation
    let hasDmaReadRespErr = True;
    let minErrLen = 512;
    let maxErrLen = 1024;
    let simDmaReadSrv <- mkSimDmaReadSrvWithErr(
        hasDmaReadRespErr, minErrLen, maxErrLen
    );

    let pendingWorkReqBufNotEmpty = True;
    // DUT
    let reqGenSQ <- mkReqGenSQ(
        cntrl, simDmaReadSrv, newPendingWorkReqPipeOut, pendingWorkReqBufNotEmpty
    );
    let pendingWorkReqPipeOut4Comp = reqGenSQ.pendingWorkReqPipeOut;
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    // Error WC
    let errWorkCompGenReqPipeOut = reqGenSQ.workCompGenReqPipeOut;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkErrWorkComp;
        if (genErrWorkCompReg) begin
            immAssert(
                !errWorkCompGenReqPipeOut.notEmpty,
                "errWorkCompGenReqPipeOut empty assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "errWorkCompGenReqPipeOut.notEmpty=",
                    fshow(errWorkCompGenReqPipeOut.notEmpty),
                    " should be false"
                )
            );

            countDown.decr;
        end
        else begin
            let errWorkCompReq = errWorkCompGenReqPipeOut.first;
            errWorkCompGenReqPipeOut.deq;

            genErrWorkCompReg <= True;

            immAssert(
                errWorkCompReq.wcStatus == IBV_WC_LOC_QP_OP_ERR,
                "errWorkCompReq status assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "errWorkCompReq.wcStatus=", fshow(errWorkCompReq.wcStatus),
                    " should be IBV_WC_LOC_QP_OP_ERR"
                )
            );
        end
        // $display("time=%0t: error WC request=", $time, fshow(errWorkCompReq));
    endrule
/*
    rule flushWorkReqAfterFatalErr if (genErrWorkCompReg);
        workReqPipeOut4Flush.deq;

        immAssert(
            !errWorkCompGenReqPipeOut.notEmpty,
            "errWorkCompGenReqPipeOut empty assertion @ mkTestReqGenDmaReadErrCase",
            $format(
                "errWorkCompGenReqPipeOut.notEmpty=",
                fshow(errWorkCompGenReqPipeOut.notEmpty),
                " should be false"
            )
        );

        countDown.decr;
    endrule
*/
    rule compareWorkReq; // BeforeFatalErr if (!genErrWorkCompReg);
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        immAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestReqGenDmaReadErrCase",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );
        // $display("time=%0t: WR=", $time, fshow(pendingWR.wr));
    endrule
endmodule
