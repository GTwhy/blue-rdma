import Cntrs :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import PrimUtils :: *;

// function PipeOut#(anytype) scanQ2PipeOut(ScanIfc scanQ);
//     return interface PipeOut;
//         method anytype first() = scanQ.current;
//         method Action deq() = scanQ.scanNext;
//         method Bool notEmpty() = !scanQ.scanDone;
//     endinterface;
// endfunction

interface ScanIfc#(type anytype);
    method Action scanStart();
    method anytype current();
    method Action scanNext();
    method Bool scanDone();
    method Bool isEmpty();
endinterface

interface ScanFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifoIfc;
    interface ScanIfc#(anytype) scanIfc;
    method UInt#(TLog#(TAdd#(qSz, 1))) count;
endinterface

module mkScanFIFOF(ScanFIFOF#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(qSz), qLogSz),
    NumAlias#(TAdd#(qLogSz, 1), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Reg#(Bit#(cntSz))         enqPtrReg <- mkReg(0);
    Reg#(Bit#(cntSz))         deqPtrReg <- mkReg(0);
    Reg#(Bool)                 emptyReg <- mkReg(True);
    Reg#(Bool)                  fullReg <- mkReg(False);
    Count#(UInt#(cntSz))        itemCnt <- mkCount(0);
    Reg#(Bit#(cntSz))        scanPtrReg <- mkRegU;
    Reg#(Bool)              scanModeReg <- mkReg(False);

    Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             popReg[2] <- mkCReg(2, False);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);

    function Bool isFull(Bit#(cntSz) nextEnqPtr);
        return (getMSB(nextEnqPtr) != getMSB(deqPtrReg)) &&
            (removeMSB(nextEnqPtr) == removeMSB(deqPtrReg));
    endfunction

    function Bool isDeqPtrEqScanPtr();
        return scanModeReg ? deqPtrReg == scanPtrReg : False;
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            itemCnt   <= 0;
            enqPtrReg <= 0;
            deqPtrReg <= 0;
            emptyReg  <= True;
            fullReg   <= False;
        end
        else begin
            let nextEnqPtr = enqPtrReg;
            let nextDeqPtr = deqPtrReg;

            if (pushReg[1] matches tagged Valid .pushVal) begin
                dataVec[removeMSB(enqPtrReg)] <= pushVal;
                nextEnqPtr = enqPtrReg + 1;
                // $display("time=%0d: push into ScanFIFOF, enqPtrReg=%h", $time, enqPtrReg);
            end

            if (popReg[1]) begin
                nextDeqPtr = deqPtrReg + 1;
                // $display(
                //     "time=%0d: pop from ScanFIFOF, deqPtrReg=%h, emptyReg=",
                //     $time, deqPtrReg, fshow(emptyReg)
                // );
            end

            if (isValid(pushReg[1]) && !popReg[1]) begin
                itemCnt.incr(1);
            end
            else if (!isValid(pushReg[1]) && popReg[1]) begin
                itemCnt.decr(1);
            end

            fullReg  <= isFull(nextEnqPtr);
            emptyReg <= nextDeqPtr == enqPtrReg;

            enqPtrReg <= nextEnqPtr;
            deqPtrReg <= nextDeqPtr;

            // $display(
            //     "time=%0d: enqPtrReg=%0d, deqPtrReg=%0d", $time, enqPtrReg, deqPtrReg,
            //     ", fullReg=", fshow(fullReg), ", emptyReg=", fshow(emptyReg)
            // );
        end

        clearReg[1] <= False;
        pushReg[1]  <= tagged Invalid;
        popReg[1]   <= False;
    endrule

    interface fifoIfc = interface FIFOF#(qSz, anytype);
        method anytype first() if (!emptyReg && !scanModeReg);
            return dataVec[removeMSB(deqPtrReg)];
        endmethod

        method Bool notEmpty() = !emptyReg;
        method Bool notFull()  = !fullReg;

        method Action enq(anytype inputVal) if (!fullReg && !scanModeReg);
            pushReg[0] <= tagged Valid inputVal;
        endmethod

        method Action deq() if (!emptyReg && !isDeqPtrEqScanPtr);
            popReg[0] <= True;
        endmethod

        method Action clear() if (!scanModeReg);
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface scanIfc = interface ScanIfc#(qSz, anytype);
        method Action scanStart() if (!scanModeReg);
            dynAssert(
                !emptyReg,
                "emptyReg assertion @ mkScanFIFOF",
                $format("cannot start scan when emptyReg=", fshow(emptyReg))
            );

            scanModeReg <= !emptyReg;
            scanPtrReg <= deqPtrReg;

            // $display(
            //     "time=%0d: scanStart(), scanPtrReg=%0d, deqPtrReg=%0d, enqPtrReg=%0d",
            //     $time, scanPtrReg, deqPtrReg, enqPtrReg,
            //     ", scanModeReg=", fshow(scanModeReg),
            //     ", emptyReg=", fshow(emptyReg)
            // );
        endmethod

        method anytype current() if (scanModeReg);
            return dataVec[removeMSB(scanPtrReg)];
        endmethod

        method Action scanNext if (scanModeReg);
            let nextScanPtr = scanPtrReg + 1;
            let scanFinish = nextScanPtr == enqPtrReg;
            scanPtrReg  <= nextScanPtr;
            scanModeReg <= !scanFinish;
            // $display(
            //     "time=%0d: scanPtrReg=%0d, nextScanPtr=%0d, enqPtrReg=%0d, deqPtrReg=%0d, scanModeReg=",
            //     $time, scanPtrReg, nextScanPtr, enqPtrReg, deqPtrReg, fshow(scanModeReg)
            // );
        endmethod

        method Bool scanDone() = !scanModeReg;

        method Bool isEmpty() = emptyReg;
    endinterface;

    method UInt#(cntSz) count = itemCnt;
endmodule

interface SearchIfc#(type anytype);
    method Maybe#(anytype) search(function Bool searchFunc(anytype fifoItem));
endinterface

interface SearchFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifoIfc;
    interface SearchIfc#(anytype) searchIfc;
endinterface

module mkSearchFIFOF(SearchFIFOF#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(qSz), qLogSz),
    NumAlias#(TAdd#(qLogSz, 1), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype))     dataVec <- replicateM(mkRegU);
    Vector#(qSz, Array#(Reg#(Bool))) tagVec <- replicateM(mkCReg(3, False));
    Reg#(Bit#(cntSz)) enqPtrReg[3] <- mkCReg(3, 0);
    Reg#(Bit#(cntSz)) deqPtrReg[3] <- mkCReg(3, 0);
    Reg#(Bool)         emptyReg[3] <- mkCReg(3, True);
    Reg#(Bool)          fullReg[3] <- mkCReg(3, False);

    function Bool predFunc(
        function Bool searchFunc(anytype fifoItem),
        Tuple2#(Array#(Reg#(Bool)), Reg#(anytype)) zipItem
    );
        let { tag, anydata } = zipItem;
        return tag[0] && searchFunc(readReg(anydata));
    endfunction

    function Bool isFull(Bit#(cntSz) nextEnqPtr);
        return (getMSB(nextEnqPtr) != getMSB(deqPtrReg[1])) &&
            (removeMSB(nextEnqPtr) == removeMSB(deqPtrReg[1]));
    endfunction

    interface fifoIfc = interface FIFOF#(qSz, anytype);
        method anytype first() if (!emptyReg[0]);
            return dataVec[removeMSB(deqPtrReg[0])];
        endmethod

        method Bool notEmpty() = !emptyReg[0];
        method Bool notFull()  = !fullReg[1];

        method Action enq(anytype inputVal) if (!fullReg[1]);
            dataVec[removeMSB(enqPtrReg[1])]   <= inputVal;
            tagVec[removeMSB(enqPtrReg[1])][1] <= True;
            let nextEnqPtr = enqPtrReg[1] + 1;
            enqPtrReg[1] <= nextEnqPtr;
            fullReg[1]   <= isFull(nextEnqPtr);
            emptyReg[1]  <= False;
        endmethod

        method Action deq() if (!emptyReg[0]);
            tagVec[removeMSB(deqPtrReg[0])][0] <= False;
            let nextDeqPtr = deqPtrReg[0] + 1;
            deqPtrReg[0] <= nextDeqPtr;
            emptyReg[0]  <= nextDeqPtr == enqPtrReg[0];
            fullReg[0]   <= False;
        endmethod

        method Action clear();
            for (Integer idx = 0; idx < valueOf(qSz); idx = idx + 1) begin
                tagVec[idx][2] <= False;
            end
            enqPtrReg[2] <= 0;
            deqPtrReg[2] <= 0;
            emptyReg[2]  <= True;
            fullReg[2]   <= False;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc#(qSz, anytype);
        method Maybe#(anytype) search(function Bool searchFunc(anytype fifoItem));
            let zipVec = zip(tagVec, dataVec);
            let maybeFindResult = findIndex(predFunc(searchFunc), zipVec);
            if (maybeFindResult matches tagged Valid .findIndex) begin
                // let tag = readReg(tagVec[findIndex]);
                // dynAssert(
                //     tag,
                //     "tag assertion @ mkSearchFIFOF",
                //     $format("search found tag=", fshow(tag), " must be true")
                // );
                return tagged Valid readReg(dataVec[findIndex]);
            end
            else begin
                return tagged Invalid;
            end
        endmethod
    endinterface;
endmodule
