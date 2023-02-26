import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Arbitration :: *;
import PrimUtils :: *;
import Utils :: *;
import Utils4Test :: *;

typedef 16 CLIENT_NUM;
// typedef 8 MAX_FRAG_NUM;

typedef Bit#(TLog#(CLIENT_NUM)) ClientIndex;
typedef Tuple2#(Bit#(TLog#(CLIENT_NUM)), Bool) ReqType;
typedef Tuple2#(Bit#(TLog#(CLIENT_NUM)), Bool) RespType;
typedef Tuple2#(Bit#(TLog#(CLIENT_NUM)), Bool) PayloadType;

module mkEchoSrv(
    Server#(ReqType, RespType)
);
    let maxFragCnt = valueOf(CLIENT_NUM) - 1;

    FIFOF#(ReqType) reqQ <- mkFIFOF;
    FIFOF#(RespType) respQ <- mkFIFOF;
    FIFOF#(ReqType) pendingReqQ <- mkFIFOF;

    Count#(ClientIndex) reqFragCnt <- mkCount(0);
    // Count#(ClientIndex) respFragCnt <- mkCount(0);
    Count#(ClientIndex) expectClientIdxCnt <- mkCount(0);
    // Reg#(Bool) busyReg <- mkReg(False);

    rule getReq;
        let { clientIdx, isLast } = reqQ.first;
        reqQ.deq;

        let isLastRef = isZero(reqFragCnt);
        if (isLastRef) begin
            reqFragCnt.update(clientIdx + 1);
            expectClientIdxCnt.update(clientIdx + 1);
            // respFragCnt.update(clientIdx);
            // busyReg <= True;
        end
        else begin
            reqFragCnt.decr(1);
        end

        // $display(
        //     "time=%0d:", $time, " clientIdx=%0d", clientIdx,
        //     ", isLast=", fshow(isLast),
        //     ", reqFragCnt=%0d", reqFragCnt
        // );
        immAssert(
            clientIdx == expectClientIdxCnt,
            "clientIdx assertion @ mkEchoSrv",
            $format(
                "clientIdx=%0d should == expectClientIdxCnt=%0d",
                clientIdx, expectClientIdxCnt,
                ", reqFragCnt=%0d", reqFragCnt
            )
        );
        immAssert(
            isLast == isLastRef,
            "isLast assertion @ mkEchoSrv",
            $format(
                "isLast=", fshow(isLast), " should == isLastRef=", fshow(isLastRef),
                ", reqFragCnt=%0d", reqFragCnt
            )
        );

        pendingReqQ.enq(tuple2(clientIdx, isLast));
    endrule

    rule issueResp;
        // let isLast = isZero(respFragCnt);
        // if (isLast) begin
        //     busyReg <= False;
        //     expectClientIdxCnt.update(expectClientIdxCnt + 1);
        // end
        // else begin
        //     respFragCnt.decr(1);
        // end

        let { clientIdx, isLast } = pendingReqQ.first;
        pendingReqQ.deq;

        respQ.enq(tuple2(clientIdx, isLast));
    endrule

    return toGPServer(reqQ, respQ);
endmodule

(* synthesize *)
module mkTestServerArbiter(Empty);
    function Bool reqFinished(ReqType req) = getTupleSecond(req);
    function Bool respFinished(RespType resp) = getTupleSecond(resp);

    function genClientFragCnt(idx);
        return mkCount(fromInteger(idx));
    endfunction

    let maxFragCnt = valueOf(CLIENT_NUM) - 1;

    Vector#(CLIENT_NUM, Count#(ClientIndex))  reqFragCntVec <- genWithM(genClientFragCnt);
    Vector#(CLIENT_NUM, Count#(ClientIndex)) respFragCntVec <- genWithM(genClientFragCnt);

    let echoSrv <- mkEchoSrv;
    Vector#(CLIENT_NUM, Server#(ReqType, RespType)) dut <- mkServerArbiter(
        echoSrv, reqFinished, respFinished
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    for (Integer idx = 0; idx < valueOf(CLIENT_NUM); idx = idx + 1) begin
        rule clientReq;
            let srv = dut[idx];
            let clientIdx = fromInteger(idx);

            Count#(ClientIndex) reqFragCnt = reqFragCntVec[idx];

            let isLast = isZero(reqFragCnt);
            if (isLast) begin
                reqFragCnt.update(clientIdx);
            end
            else begin
                reqFragCnt.decr(1);
            end

            srv.request.put(tuple2(clientIdx, isLast));
        endrule
    end

    for (Integer idx = 0; idx < valueOf(CLIENT_NUM); idx = idx + 1) begin
        rule clientResp;
            let srv = dut[idx];
            let { clientIdx, isLast } <- srv.response.get;

            Count#(ClientIndex) respFragCnt = respFragCntVec[idx];
            let isLastRef = isZero(respFragCnt);
            if (isLastRef) begin
                respFragCnt.update(clientIdx);
            end
            else begin
                respFragCnt.decr(1);
            end

            immAssert(
                clientIdx == fromInteger(idx),
                "clientIdx assertion @ mkTestServerArbiter",
                $format(
                    "clientIdx=%0d should == idx=%0d",
                    clientIdx, idx,
                    ", respFragCnt=%0d", respFragCnt
                )
            );
            immAssert(
                isLast == isLastRef,
                "isLast assertion @ mkTestServerArbiter",
                $format(
                    "isLast=", fshow(isLast), " should == isLastRef=", fshow(isLastRef),
                    ", respFragCnt=%0d", respFragCnt
                )
            );

            if (idx == 0) begin
                countDown.decr;
            end

            // $display(
            //     "time=%0t:", $time,
            //     " clientIdx=%0d should == idx=%0d",
            //     clientIdx, idx,
            //     ", isLast=", fshow(isLast), " should == isLastRef=", fshow(isLastRef),
            //     ", respFragCnt=%0d", respFragCnt
            // );
        endrule
    end
endmodule

(* synthesize *)
module mkTestPipeOutArbiter(Empty);
    function Bool isPipePayloadFinished(
        PayloadType pipePayload
    ) = getTupleSecond(pipePayload);

    function genClientFragCnt(idx);
        return mkCount(fromInteger(idx));
    endfunction

    // let maxFragCnt = valueOf(MAX_FRAG_NUM) - 1;

    Vector#(CLIENT_NUM, FIFOF#(PayloadType)) pipeInPayloadVec <- replicateM(mkFIFOF);
    Vector#(CLIENT_NUM, Count#(ClientIndex)) pipeInFragCntVec <- genWithM(genClientFragCnt); // replicateM(mkCount(fromInteger(maxFragCnt)));

    let dut <- mkPipeOutArbiter(map(convertFifo2PipeOut, pipeInPayloadVec), isPipePayloadFinished);

    Count#(ClientIndex) expectedPipeOutValCnt <- mkCount(0);
    Count#(ClientIndex) expectedPipeFragLastCnt <- mkCount(0);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    for (Integer idx = 0; idx < valueOf(CLIENT_NUM); idx = idx + 1) begin
        rule clientPipeEnq;
            Count#(ClientIndex) pipeFragCnt = pipeInFragCntVec[idx];
            let pipeInQ = pipeInPayloadVec[idx];
            let isLast  = isZero(pipeFragCnt);

            if (isLast) begin
                pipeFragCnt.update(fromInteger(idx));
            end
            else begin
                pipeFragCnt.decr(1);
            end

            pipeInQ.enq(tuple2(fromInteger(idx), isLast));
        endrule
    end

    rule checkServerPipeOut;
        let { pipeOutVal, isLast } = dut.first;
        dut.deq;

        let isLastRef = isZero(expectedPipeFragLastCnt);
        if (isLastRef) begin
            expectedPipeFragLastCnt.update(expectedPipeOutValCnt + 1);
            expectedPipeOutValCnt.incr(1);
        end
        else begin
            expectedPipeFragLastCnt.decr(1);
        end

        immAssert(
            pipeOutVal == expectedPipeOutValCnt,
            "pipeOutVal assertion @ mkTestPipeOutArbiter",
            $format(
                "pipeOutVal=%h should == expectedPipeOutValCnt=%h",
                pipeOutVal, expectedPipeOutValCnt,
                ", and expectedPipeFragLastCnt=%0d",
                expectedPipeFragLastCnt
            )
        );

        immAssert(
            isLast == isLastRef,
            "isLast assertion @ mkTestPipeOutArbiter",
            $format(
                "isLast=", fshow(isLast), " should == isLastRef=", fshow(isLastRef),
                ", expectedPipeFragLastCnt=%0d", expectedPipeFragLastCnt
            )
        );

        countDown.decr;
    endrule
endmodule
