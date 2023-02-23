import Arbiter :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import PrimUtils :: *;
import Utils :: *;

module mkServerArbiter#(
    Server#(reqType, respType) srv,
    function Bool reqHasLockFunc(reqType request),
    function Bool respHasLockFunc(respType response)
)(Vector#(portSz, Server#(reqType, respType)))
provisos(
    Bits#(reqType, reqSz),
    Bits#(respType, respSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    Reg#(Bool) lockArbiterReg <- mkReg(False);
    Arbiter_IFC#(portSz) arbiter <- mkArbiter(lockArbiterReg);
    FIFOF#(Bit#(TLog#(portSz))) preGrantIdxQ <- mkFIFOF;

    Vector#(portSz, FIFOF#(reqType))   reqVec <- replicateM(mkFIFOF);
    Vector#(portSz, FIFOF#(respType)) respVec <- replicateM(mkFIFOF);

    function Bool portHasReqFunc(FIFOF#(reqType) portReqQ) = portReqQ.notEmpty;

    // function Bool portHasReqLockFunc(FIFOF#(reqType) portReqQ);
    //     return portReqQ.notEmpty ? reqHasLockFunc(portReqQ.first) : False;
    // endfunction

    // function Tuple2#(Bool, Bool) clientHasReqAndLockFunc(
    //     function Bool reqHasLockFunc(reqType request),
    //     FIFOF#(reqType) portReqQ
    // );
    //     return portReqQ.notEmpty ?
    //         tuple2(True, reqHasLockFunc(portReqQ.first)) :
    //         tuple2(False, False);
    // endfunction

    function Server#(reqType, respType) fifoTuple2Server(
        Tuple2#(FIFOF#(reqType), FIFOF#(respType)) fifoTuple
    );
        return toGPServer(getTupleFirst(fifoTuple), getTupleSecond(fifoTuple));
    endfunction

    rule arbitrateRequest;
        // ReqBits#(portSz) reqBits = pack(map(portHasReqFunc, reqVec));
        // LockBits#(portSz) lockBits = pack(map(portHasReqLockFunc, reqVec));
        // let { notLocked, grantBits } <- arbiter.arbitrate(reqBits, lockBits);
        // if (notLocked) begin
        //     preGrantQ.enq(grantBits);
        // end

        for (Integer idx = 0; idx < valueOf(portSz); idx = idx + 1) begin
            let hasReq = portHasReqFunc(reqVec[idx]);
            // let { hasReq, hasLock } = clientHasReqAndLockFunc(
            //     reqHasLockFunc, reqVec[idx]
            // );
            if (hasReq) begin
                arbiter.clients[idx].request;
            end
        end
    endrule

    rule grantRequest;
        let grantIdx = arbiter.grant_id;
        let granted  = arbiter.clients[grantIdx].grant;
        // let grantHasLock = arbiter.clients[grantIdx].lock;
        if (granted) begin
            let req = reqVec[grantIdx].first;
            reqVec[grantIdx].deq;
            srv.request.put(req);

            let reqHasLock = reqHasLockFunc(req);
            lockArbiterReg <= reqHasLock;
            // Save grant index only when no need to lock
            if (!reqHasLock) begin
                preGrantIdxQ.enq(grantIdx);
            end
            // immAssert(
            //     grantHasLock == reqHasLock,
            //     "grantHasLock assertion @ mkServerArbiterAndDispatcher",
            //     $format(
            //         "grantHasLock=", fshow(grantHasLock),
            //         " should == reqHasLock=", fshow(reqHasLock)
            //     )
            // );
        end
    endrule

    rule dispatchResponse;
        let preGrantIdx = preGrantIdxQ.first;
        let resp <- srv.response.get;
        // Vector#(portSz, Bool) preGrantVec = unpack(preGrantBits);
        // let maybeIdx = findElem(True, preGrantVec);
        // immAssert(
        //     isValid(maybeIdx),
        //     "maybeIdx assertion @ mkServerArbiter",
        //     $format("maybeIdx=", fshow(maybeIdx), " should be valid")
        // );

        let respHasLock = respHasLockFunc(resp);
        // if (maybeIdx matches tagged Valid. grantIdx) begin
        respVec[preGrantIdx].enq(resp);
        // Pop current grant index only when no need to lock
        if (!respHasLock) begin
            preGrantIdxQ.deq;
        end
        // end
    endrule

    return map(fifoTuple2Server, zip(reqVec, respVec));
endmodule

module mkPipeOutArbiter#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool reqHasLockFunc(anytype pipePayload)
)(PipeOut#(anytype))
provisos(
    Bits#(anytype, tSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    Reg#(Bool) lockArbiterReg <- mkReg(False);
    Arbiter_IFC#(portSz) arbiter <- mkArbiter(lockArbiterReg);
    FIFOF#(anytype) pipeOutQ <- mkFIFOF;

    function Bool portHasReqFunc(PipeOut#(anytype) pipeIn) = pipeIn.notEmpty;

    // function Bool portHasReqLockFunc(PipeOut#(anytype) pipeIn);
    //     return pipeIn.notEmpty ? reqHasLockFunc(pipeIn.first) : False;
    // endfunction

    // function Tuple2#(Bool, Bool) clientHasReqAndLockFunc(
    //     function Bool reqHasLockFunc(reqType request),
    //     PipeOut#(reqType) portReqQ
    // );
    //     return portReqQ.notEmpty ?
    //         tuple2(True, reqHasLockFunc(portReqQ.first)) :
    //         tuple2(False, False);
    // endfunction

    rule arbitrateRequest;
        // ReqBits#(portSz) reqBits = pack(map(portHasReqFunc, inputPipeOutVec));
        // LockBits#(portSz) lockBits = pack(map(portHasReqLockFunc, inputPipeOutVec));
        // let { notLocked, grantBits } <- arbiter.arbitrate(reqBits, lockBits);

        for (Integer idx = 0; idx < valueOf(portSz); idx = idx + 1) begin
            let hasReq = portHasReqFunc(inputPipeOutVec[idx]);
            // let { hasReq, hasLock } = clientHasReqAndLockFunc(
            //     reqHasLockFunc, inputPipeOutVec[idx]
            // );
            if (hasReq) begin
                arbiter.clients[idx].request;
            end
        end
    endrule

    rule grantRequest;
        let grantIdx = arbiter.grant_id;
        let granted = arbiter.clients[grantIdx].grant;
        let grantHasLock = arbiter.clients[grantIdx].lock;
        if (granted) begin
            let pipePayload = inputPipeOutVec[grantIdx].first;
            inputPipeOutVec[grantIdx].deq;
            pipeOutQ.enq(pipePayload);

            let reqHasLock = reqHasLockFunc(pipePayload);
            lockArbiterReg <= reqHasLock;
            // immAssert(
            //     grantHasLock == reqHasLock,
            //     "grantHasLock assertion @ mkPipeOutArbiter",
            //     $format(
            //         "grantHasLock=", fshow(grantHasLock),
            //         " should == reqHasLock=", fshow(reqHasLock)
            //     )
            // );
        end
    endrule

    return convertFifo2PipeOut(pipeOutQ);
endmodule
