import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import PrimUtils :: *;
import Utils :: *;

function Tuple3#(Bool, Bit#(TLog#(portSz)), Vector#(portSz, Bool)) arbitrate(
    Vector#(portSz, Bool) priorityVec, Vector#(portSz, Bool) requestVec
);
    function Bool isTrue(Bool inputVal) = inputVal;

    let portNum = valueOf(portSz);

    Vector#(portSz, Bool) grantVec = replicate(False);
    Bit#(TLog#(portSz))   grantIdx = 0;

    Bool found   = True;
    Bool granted = False;
    for (Integer x = 0; x < (2 * portNum); x = x + 1) begin
        Integer y = (x % portNum);

        let hasReq = requestVec[y];
        let hasPriority = priorityVec[y];

        if (hasPriority) begin
            found = False;
        end

        if (!found && hasReq) begin
            grantVec[y] = True;
            grantIdx    = fromInteger(y);
            found   = True;
            granted = True;
        end
    end

    let nextPriorityVec = granted ? rotateR(grantVec) : priorityVec;
    return tuple3(granted, grantIdx, nextPriorityVec);
endfunction

module mkServerArbiter#(
    Server#(reqType, respType) srv,
    function Bool isReqFinished(reqType request),
    function Bool isRespFinished(respType response)
)(Vector#(portSz, Server#(reqType, respType))) provisos(
    FShow#(reqType), FShow#(respType),
    Bits#(reqType, reqSz),
    Bits#(respType, respSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    // Arbiter#(portSz) arbiter <- mkRoundRobinArbiter;
    Reg#(Bool) needArbitrationReg <- mkReg(True);
    FIFOF#(Bit#(TLog#(portSz))) preGrantIdxQ <- mkFIFOF;
    Reg#(Bit#(TLog#(portSz))) preGrantIdxReg <- mkRegU;

    // Initially, priority is given to client 0
    Vector#(portSz, Bool) initPriorityVec = replicate(False);
    initPriorityVec[0] = True;
    Reg#(Vector#(portSz, Bool)) priorityVecReg <- mkReg(initPriorityVec);

    Vector#(portSz, FIFOF#(reqType))   reqVec <- replicateM(mkFIFOF);
    Vector#(portSz, FIFOF#(respType)) respVec <- replicateM(mkFIFOF);

    function Bool portHasReqFunc(FIFOF#(reqType) portReqQ) = portReqQ.notEmpty;

    function Server#(reqType, respType) fifoTuple2Server(
        Tuple2#(FIFOF#(reqType), FIFOF#(respType)) fifoTuple
    );
        return toGPServer(getTupleFirst(fifoTuple), getTupleSecond(fifoTuple));
    endfunction

    rule arbitrateRequest;
        let requestVec = map(portHasReqFunc, reqVec);
        let { granted, grantIdx, nextPriorityVec } = arbitrate(priorityVecReg, requestVec);
        immAssert(
            needArbitrationReg || granted,
            "needArbitrationReg assertion @ mkServerArbiter",
            $format(
                "needArbitrationReg=", fshow(needArbitrationReg),
                " and granted=", fshow(granted),
                " should be true at least one"
            )
        );

        // $display("time=%0t: priority vector: %b", $time, priorityVecReg);
        // $display("time=%0t:  request vector: %b", $time, requestVec);
        // $display("time=%0t:    grant vector: %b", $time, grantVec);
        // $display("time=%0t:        grantIdx: %0d", $time, grantIdx);

        let curGrantIdx = needArbitrationReg ? grantIdx : preGrantIdxReg;
        let req = reqVec[curGrantIdx].first;
        reqVec[curGrantIdx].deq;
        srv.request.put(req);

        let reqFinished = isReqFinished(req);
        needArbitrationReg <= reqFinished;
        if (needArbitrationReg) begin
            preGrantIdxReg <= grantIdx;
            priorityVecReg <= nextPriorityVec;
            preGrantIdxQ.enq(curGrantIdx);
            // $display(
            //     "time=%0t:", $time,
            //     " grant to req=", fshow(req),
            //     ", grantIdx=%0d", grantIdx,
            //     ", granted=", fshow(granted),
            //     ", reqFinished=", fshow(reqFinished)
            // );
        end
        // else begin
        //     $display(
        //         "time=%0t:", $time,
        //         " stick to req=", fshow(req),
        //         " needArbitrationReg=", fshow(needArbitrationReg),
        //         ", curGrantIdx=%0d", curGrantIdx,
        //         ", preGrantIdxReg=%0d", preGrantIdxReg,
        //         ", reqFinished=", fshow(reqFinished)
        //     );
        // end
    endrule

    rule dispatchResponse;
        let preGrantIdx = preGrantIdxQ.first;
        let resp <- srv.response.get;

        let respFinished = isRespFinished(resp);
        respVec[preGrantIdx].enq(resp);
        if (respFinished) begin
            preGrantIdxQ.deq;
        end

        // $display(
        //     "time=%0t:", $time,
        //     " dispatch resp=", fshow(resp),
        //     ", preGrantIdx=%0d", preGrantIdx,
        //     ", respFinished=", fshow(respFinished)
        // );
    endrule

    return map(fifoTuple2Server, zip(reqVec, respVec));
endmodule

module mkPipeOutArbiter#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(
    FShow#(anytype),
    Bits#(anytype, tSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    // Arbiter#(portSz) arbiter <- mkRoundRobinArbiter;
    FIFOF#(anytype) pipeOutQ <- mkFIFOF;
    Reg#(Bool) needArbitrationReg <- mkReg(True);
    Reg#(Bit#(TLog#(portSz))) preGrantIdxReg <- mkRegU;

    // Initially, priority is given to client 0
    Vector#(portSz, Bool) initPriorityVec = replicate(False);
    initPriorityVec[0] = True;
    Reg#(Vector#(portSz, Bool)) priorityVecReg <- mkReg(initPriorityVec);

    function Bool portHasReqFunc(PipeOut#(anytype) pipeIn) = pipeIn.notEmpty;

    rule arbitrateRequest;
        let requestVec = map(portHasReqFunc, inputPipeOutVec);
        let { granted, grantIdx, nextPriorityVec } = arbitrate(priorityVecReg, requestVec);
        immAssert(
            needArbitrationReg || granted,
            "needArbitrationReg assertion @ mkPipeOutArbiter",
            $format(
                "needArbitrationReg=", fshow(needArbitrationReg),
                " and granted=", fshow(granted),
                " should be true at least one"
            )
        );

        // $display("time=%0t: priority vector: %b", $time, priorityVecReg);
        // $display("time=%0t:  request vector: %b", $time, requestVec);
        // $display("time=%0t:    grant vector: %b", $time, grantVec);
        // $display("time=%0t:        grantIdx: %0d", $time, grantIdx);

        let curGrantIdx = needArbitrationReg ? grantIdx : preGrantIdxReg;
        let pipePayload = inputPipeOutVec[curGrantIdx].first;
        inputPipeOutVec[curGrantIdx].deq;
        pipeOutQ.enq(pipePayload);

        let pipePayloadFinished = isPipePayloadFinished(pipePayload);
        needArbitrationReg <= pipePayloadFinished;
        if (needArbitrationReg) begin
            preGrantIdxReg <= grantIdx;
            priorityVecReg <= nextPriorityVec;
            $display(
                "time=%0t:", $time,
                " grant to pipePayload=", fshow(pipePayload),
                ", grantIdx=%0d", grantIdx,
                ", granted=", fshow(granted),
                ", pipePayloadFinished=", fshow(pipePayloadFinished)
            );
        end
        else begin
            $display(
                "time=%0t:", $time,
                " stick to pipePayload=", fshow(pipePayload),
                " needArbitrationReg=", fshow(needArbitrationReg),
                ", curGrantIdx=%0d", curGrantIdx,
                ", preGrantIdxReg=%0d", preGrantIdxReg,
                ", pipePayloadFinished=", fshow(pipePayloadFinished)
            );
        end
    endrule

    return convertFifo2PipeOut(pipeOutQ);
endmodule
