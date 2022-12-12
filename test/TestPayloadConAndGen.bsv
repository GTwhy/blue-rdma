import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

(* synthesize *)
module mkTestPayloadConAndGenNormalCase(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    FIFOF#(PayloadConReq) payloadConReqQ <- mkFIFOF;
    FIFOF#(PSN) payloadConReqPsnQ <- mkFIFOF;

    let cntrl <- mkSimController(qpType, pmtu);

    Vector#(2, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];
    let pktLenPipeOut4Con = pktLenPipeOutVec[1];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let payloadGenerator <- mkPayloadGenerator(cntrl, simDmaReadSrv.dmaReadSrv);
    let payloadDataStreamPipeOut <- mkFunc2Pipe(
        getDataStreamFromPayloadGenRespPipeOut,
        payloadGenerator.respPipeOut
    );

    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        payloadDataStreamPipeOut,
        simDmaWriteSrv.dmaWriteSrv,
        convertFifo2PipeOut(payloadConReqQ)
    );

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - pktLenPipeOut4Con
    // - payloadGenerator.respPipeOut
    // - payloadDataStreamPipeOut
    // - simDmaReadSrvDataStreamPipeOut
    // - simDmaWriteSrvDataStreamPipeOut
    // - payloadConsumer.respPipeOut

    rule genPayloadGenReq if (cntrl.isRTRorRTSorSQD);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            initiator    : OP_INIT_SQ_RD,
            addPadding   : False,
            dmaReadReq   : DmaReadReq {
                sqpn     : cntrl.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenerator.request(payloadGenReq);
    endrule

    rule genPayloadConReq if (cntrl.isRTRorRTSorSQD);
        let pktLen = pktLenPipeOut4Con.first;
        pktLenPipeOut4Con.deq;

        let startPktSeqNum = cntrl.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
            startPktSeqNum,
            zeroExtend(pktLen),
            cntrl.getPMTU
        );
        cntrl.setNPSN(nextPktSeqNum);

        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(zeroExtend(pktLen));

        let payloadConReq = PayloadConReq {
            initiator    : OP_INIT_SQ_WR,
            fragNum      : truncate(totalFragNum),
            consumeInfo  : tagged ReadRespInfo DmaWriteMetaData {
                sqpn     : cntrl.getSQPN,
                startAddr: dontCareValue,
                len      : pktLen,
                psn      : startPktSeqNum
            }
        };
        payloadConReqQ.enq(payloadConReq);
        payloadConReqPsnQ.enq(startPktSeqNum);
    endrule

    rule comparePayloadConResp;
        let payloadConResp = payloadConsumer.respPipeOut.first;
        payloadConsumer.respPipeOut.deq;

        let expectedPSN = payloadConReqPsnQ.first;
        payloadConReqPsnQ.deq;

        dynAssert(
            payloadConResp.dmaWriteResp.psn == expectedPSN,
            "payloadConResp PSN assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadConResp.dmaWriteResp.psn=%h should == expectedPSN=%h",
                payloadConResp.dmaWriteResp.psn, expectedPSN
            )
        );
        $display(
            "time=%0d: payloadConResp.dmaWriteResp.psn=%h should == expectedPSN=%h",
            $time, payloadConResp.dmaWriteResp.psn, expectedPSN
        );
    endrule

    rule comparePayloadDataStream;
        let dmaReadPayload = simDmaReadSrvDataStreamPipeOut.first;
        simDmaReadSrvDataStreamPipeOut.deq;
        let dmaWritePayload = simDmaWriteSrvDataStreamPipeOut.first;
        simDmaWriteSrvDataStreamPipeOut.deq;

        dynAssert(
            dmaReadPayload == dmaWritePayload,
            "dmaReadPayload == dmaWritePayload assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "dmaReadPayload=", fshow(dmaReadPayload),
                " should == dmaWritePayload=", fshow(dmaWritePayload)
            )
        );
    endrule
endmodule