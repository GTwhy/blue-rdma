import Cntrs :: *;
import FIFOF :: *;
import PAClib :: *;
import PrimUtils :: *;
import Vector :: *;
/*
interface ScanIfc#(type anytype);
    method Action scanStart();
    method Action scanRestart();
    method anytype current();
    method Action next();
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
    Reg#(Bool)              scanModeReg <- mkReg(False);
    Reg#(Bit#(cntSz))        scanPtrReg <- mkRegU;

    Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             popReg[2] <- mkCReg(2, False);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);
    Reg#(Bool)       scanStartReg[2] <- mkCReg(2, False);
    Reg#(Bool)        scanNextReg[2] <- mkCReg(2, False);

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
            itemCnt     <= 0;
            enqPtrReg   <= 0;
            deqPtrReg   <= 0;
            emptyReg    <= True;
            fullReg     <= False;
            scanModeReg <= False;
        end
        else begin
            let nextEnqPtr  = enqPtrReg;
            let nextDeqPtr  = deqPtrReg;
            let nextScanPtr = scanPtrReg;

            if (pushReg[1] matches tagged Valid .pushVal) begin
                dataVec[removeMSB(enqPtrReg)] <= pushVal;
                nextEnqPtr = enqPtrReg + 1;
                // $display("time=%0t: push into ScanFIFOF, enqPtrReg=%h", $time, enqPtrReg);
            end

            if (popReg[1]) begin
                nextDeqPtr = deqPtrReg + 1;
                // $display(
                //     "time=%0t: pop from ScanFIFOF, deqPtrReg=%h, emptyReg=",
                //     $time, deqPtrReg, fshow(emptyReg)
                // );
            end

            let isEmpty = nextDeqPtr == enqPtrReg;

            if (scanStartReg[1]) begin
                nextScanPtr = nextDeqPtr;

                scanModeReg <= !isEmpty;
            end
            else if (scanNextReg[1]) begin
                nextScanPtr = scanPtrReg + 1;

                // No enqueue during scan mode
                let scanFinish = nextScanPtr == enqPtrReg;
                scanModeReg <= !(isEmpty || scanFinish);
            end

            immAssert(
                !(scanStartReg[1] && popReg[1]),
                "scanStartReg and popReg assertion @ mkScanFIFOF",
                $format(
                    "scanStartReg=", fshow(scanStartReg[1]),
                    ", popReg=", fshow(popReg[1]),
                    " cannot both be true"
                )
            );

            if (isValid(pushReg[1]) && !popReg[1]) begin
                itemCnt.incr(1);
            end
            else if (!isValid(pushReg[1]) && popReg[1]) begin
                itemCnt.decr(1);
            end

            fullReg  <= isFull(nextEnqPtr);
            emptyReg <= isEmpty;

            enqPtrReg  <= nextEnqPtr;
            deqPtrReg  <= nextDeqPtr;
            scanPtrReg <= nextScanPtr;
            // $display(
            //     "time=%0t: enqPtrReg=%0d, deqPtrReg=%0d", $time, enqPtrReg, deqPtrReg,
            //     ", fullReg=", fshow(fullReg), ", emptyReg=", fshow(emptyReg)
            // );
        end

        clearReg[1]     <= False;
        pushReg[1]      <= tagged Invalid;
        popReg[1]       <= False;
        scanStartReg[1] <= False;
        scanNextReg[1]  <= False;
    endrule

    interface fifoIfc = interface FIFOF#(qSz, anytype);
        method anytype first() if (!emptyReg);
            return dataVec[removeMSB(deqPtrReg)];
        endmethod

        method Bool notEmpty() = !emptyReg;
        method Bool notFull()  = !fullReg;

        method Action enq(anytype inputVal) if (!fullReg && !scanModeReg);
            pushReg[0] <= tagged Valid inputVal;
        endmethod

        // Make sure no dequeue when start scan
        method Action deq() if (!emptyReg && !scanStartReg[1] && !isDeqPtrEqScanPtr);
            popReg[0] <= True;
        endmethod

        method Action clear() if (!scanModeReg);
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface scanIfc = interface ScanIfc#(qSz, anytype);
        // (* preempts = "scanStart, deq" *)
        method Action scanStart() if (!scanModeReg);
            immAssert(
                !emptyReg,
                "emptyReg assertion @ mkScanFIFOF",
                $format("cannot start scan when emptyReg=", fshow(emptyReg))
            );
            scanStartReg[0] <= True;

            // $display(
            //     "time=%0t: scanStart(), scanPtrReg=%0d, deqPtrReg=%0d, enqPtrReg=%0d",
            //     $time, scanPtrReg, deqPtrReg, enqPtrReg,
            //     ", scanModeReg=", fshow(scanModeReg),
            //     ", emptyReg=", fshow(emptyReg)
            // );
        endmethod

        // (* preempts = "scanRestart, deq" *)
        method Action scanRestart() if (scanModeReg);
            immAssert(
                !emptyReg,
                "emptyReg assertion @ mkScanFIFOF",
                $format("cannot restart scan when emptyReg=", fshow(emptyReg))
            );

            scanStartReg[0] <= True;
        endmethod

        method anytype current() if (scanModeReg);
            return dataVec[removeMSB(scanPtrReg)];
        endmethod

        method Action next if (scanModeReg);
            scanNextReg[0] <= True;
            // $display(
            //     "time=%0t: scanPtrReg=%0d, nextScanPtr=%0d, enqPtrReg=%0d, deqPtrReg=%0d, scanModeReg=",
            //     $time, scanPtrReg, nextScanPtr, enqPtrReg, deqPtrReg, fshow(scanModeReg)
            // );
        endmethod

        method Bool scanDone() = !scanModeReg;

        method Bool isEmpty() = emptyReg;
    endinterface;

    method UInt#(cntSz) count = itemCnt;
endmodule
*/
interface ScanOutIfc#(type anytype);
    method anytype current();
    method Action next();
    // method Bool isEmpty();
endinterface

interface ScanCntrlIfc#(type anytype);
    method anytype getHead();
    method Action modifyHead(anytype head);
    method Action preScanStart();
    method Action scanStart();
    method Action preScanRestart();
    // method Action scanStop();
    method Bool isScanDone();
    method Bool isScanMode();
endinterface

interface ScanFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifoIfc;
    interface ScanOutIfc#(anytype) scanOutIfc;
    interface ScanCntrlIfc#(anytype) scanCntrlIfc;
    // method UInt#(TLog#(TAdd#(qSz, 1))) count;
endinterface

typedef enum {
    SCAN_Q_FIFOF_MODE,
    SCAN_Q_PRE_SCAN_MODE,
    SCAN_Q_SCAN_MODE
} ScanState deriving(Bits, Eq, FShow);

function PipeOut#(anytype) scanOut2PipeOut(ScanFIFOF#(qSz, anytype) scanQ);
    return interface PipeOut#(anytype);
        method anytype first();
            return scanQ.scanOutIfc.current;
        endmethod

        method Action deq();
            scanQ.scanOutIfc.next;
        endmethod

        method Bool notEmpty();
            return scanQ.scanCntrlIfc.isScanMode;
        endmethod
    endinterface;
endfunction

function Bool isFull(Bit#(cntSz) nextEnqPtr, Bit#(cntSz) nextDeqPtr)
provisos(Add#(1, anysize, cntSz));
    return (getMSB(nextEnqPtr) != getMSB(nextDeqPtr)) &&
        (removeMSB(nextEnqPtr) == removeMSB(nextDeqPtr));
endfunction

// ScanFIFOF is frozon when in SCAN_Q_PRE_SCAN_MODE,
// and no enqueue when in SCAN_Q_SCAN_MODE.
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
    Count#(Bit#(cntSz))        itemCnt <- mkCount(0);
    Reg#(Bit#(cntSz))        scanPtrReg <- mkRegU;
    Reg#(ScanState)        scanStateReg <- mkReg(SCAN_Q_FIFOF_MODE);

    Reg#(Maybe#(anytype)) headReg[2] <- mkCRegU(2);
    Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             popReg[2] <- mkCReg(2, False);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);
    Reg#(Bool)    preScanStartReg[2] <- mkCReg(2, False);
    Reg#(Bool)       scanStartReg[2] <- mkCReg(2, False);
    Reg#(Bool)  preScanRestartReg[2] <- mkCReg(2, False);
    Reg#(Bool)        scanNextReg[2] <- mkCReg(2, False);

    let inFifoMode = scanStateReg == SCAN_Q_FIFOF_MODE;
    let inScanMode = scanStateReg == SCAN_Q_SCAN_MODE;
    let inPreScanMode = scanStateReg == SCAN_Q_PRE_SCAN_MODE;

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            itemCnt      <= 0;
            enqPtrReg    <= 0;
            deqPtrReg    <= 0;
            emptyReg     <= True;
            fullReg      <= False;
            scanStateReg <= SCAN_Q_FIFOF_MODE;
        end
        else begin
            let nextEnqPtr  = enqPtrReg;
            let nextDeqPtr  = deqPtrReg;
            let nextScanPtr = scanPtrReg;

            if (pushReg[1] matches tagged Valid .pushVal) begin
                dataVec[removeMSB(enqPtrReg)] <= pushVal;
                nextEnqPtr = enqPtrReg + 1;
                // $display("time=%0t: push into ScanFIFOF, enqPtrReg=%h", $time, enqPtrReg);
            end

            if (popReg[1]) begin
                nextDeqPtr = deqPtrReg + 1;
                // $display(
                //     "time=%0t: pop from ScanFIFOF, deqPtrReg=%h, emptyReg=",
                //     $time, deqPtrReg, fshow(emptyReg)
                // );
            end

            let isEmptyNext = nextDeqPtr == nextEnqPtr;

            if (preScanStartReg[1]) begin
                immAssert(
                    !emptyReg,
                    "emptyReg assertion @ mkScanFIFOF",
                    $format("cannot start pre-scan when emptyReg=", fshow(emptyReg))
                );

                headReg[1] <= tagged Invalid;
                if (!emptyReg) begin
                    scanStateReg <= SCAN_Q_PRE_SCAN_MODE;
                end
            end
            else if (scanStartReg[1]) begin
                immAssert(
                    !emptyReg,
                    "emptyReg assertion @ mkScanFIFOF",
                    $format("cannot start scan when emptyReg=", fshow(emptyReg))
                );

                nextScanPtr = nextDeqPtr;
                if (!emptyReg) begin
                    scanStateReg <= SCAN_Q_SCAN_MODE;
                end
            end
            else if (preScanRestartReg[1]) begin
                immAssert(
                    !emptyReg,
                    "emptyReg assertion @ mkScanFIFOF",
                    $format("cannot restart scan when emptyReg=", fshow(emptyReg))
                );

                headReg[1] <= tagged Invalid;
                nextScanPtr = nextDeqPtr;
                if (!emptyReg) begin
                    scanStateReg <= SCAN_Q_PRE_SCAN_MODE;
                end
            end
            else if (scanNextReg[1]) begin
                immAssert(
                    !emptyReg,
                    "emptyReg assertion @ mkScanFIFOF",
                    $format("cannot scan next when emptyReg=", fshow(emptyReg))
                );

                headReg[1] <= tagged Invalid;
                nextScanPtr = scanPtrReg + 1;

                // No enqueue during scan mode
                let scanFinish = nextScanPtr == enqPtrReg;
                if (scanFinish) begin
                    scanStateReg <= SCAN_Q_FIFOF_MODE;
                end
            end

            immAssert(
                !(scanStartReg[1] && popReg[1]),
                "scanStartReg and popReg assertion @ mkScanFIFOF",
                $format(
                    "scanStartReg=", fshow(scanStartReg[1]),
                    ", popReg=", fshow(popReg[1]),
                    " cannot both be true"
                )
            );
            immAssert(
                !(preScanRestartReg[1] && popReg[1]),
                "preScanRestartReg and popReg assertion @ mkScanFIFOF",
                $format(
                    "preScanRestartReg=", fshow(preScanRestartReg[1]),
                    ", popReg=", fshow(popReg[1]),
                    " cannot both be true"
                )
            );
            if (inScanMode || inPreScanMode) begin
                immAssert(
                    !isZero(itemCnt),
                    "notEmpty assertion @ mkScanFIFOF",
                    $format(
                        "itemCnt=%0d", itemCnt,
                        "cannot be zero when scanStateReg=",
                        fshow(scanStateReg)
                    )
                );
            end
            if (emptyReg) begin
                immAssert(
                    isZero(itemCnt),
                    "emptyReg assertion @ mkScanFIFOF",
                    $format(
                        "itemCnt=%0d should be zero when emptyReg=",
                        itemCnt, fshow(emptyReg)
                    )
                );
            end
            else if (fullReg) begin
                immAssert(
                    itemCnt == fromInteger(valueOf(qSz)),
                    "fullReg assertion @ mkScanFIFOF",
                    $format(
                        "itemCnt=%0d should == qSz=%0d when fullReg=",
                        itemCnt, valueOf(qSz), fshow(fullReg)
                    )
                );
            end

            // Verify deqPtrReg cannot over pass scanPtrReg when in scan mode
            if (inScanMode && popReg[1] && !scanNextReg[1]) begin
                immAssert(
                    deqPtrReg != scanPtrReg,
                    "dequeue beyond scan assertion @ mkScanFIFOF",
                    $format(
                        "deqPtrReg=%0d should != scanPtrReg=%0d",
                        deqPtrReg, scanPtrReg,
                        " when scanStateReg=", fshow(scanStateReg),
                        ", popReg=", fshow(popReg[1]),
                        ", scanNextReg=", fshow(scanNextReg[1])
                    )
                );
            end

            if (isValid(pushReg[1]) && !popReg[1]) begin
                itemCnt.incr(1);
                // $display("time=%0d: itemCnt.incr(1)", $time);
            end
            else if (!isValid(pushReg[1]) && popReg[1]) begin
                itemCnt.decr(1);
                // $display("time=%0d: itemCnt.decr(1)", $time);
            end

            fullReg  <= isFull(nextEnqPtr, nextDeqPtr);
            emptyReg <= isEmptyNext;

            enqPtrReg  <= nextEnqPtr;
            deqPtrReg  <= nextDeqPtr;
            scanPtrReg <= nextScanPtr;
            // $display(
            //     "time=%0t: enqPtrReg=%0d, deqPtrReg=%0d", $time, enqPtrReg, deqPtrReg,
            //     ", fullReg=", fshow(fullReg), ", emptyReg=", fshow(emptyReg)
            // );
        end

        clearReg[1]          <= False;
        pushReg[1]           <= tagged Invalid;
        popReg[1]            <= False;
        preScanStartReg[1]   <= False;
        preScanRestartReg[1] <= False;
        scanStartReg[1]      <= False;
        scanNextReg[1]       <= False;
    endrule

    interface fifoIfc = interface FIFOF#(qSz, anytype);
        method anytype first() if (!emptyReg);
            return dataVec[removeMSB(deqPtrReg)];
        endmethod

        method Bool notEmpty() = !emptyReg;
        method Bool notFull()  = !fullReg;

        method Action enq(anytype inputVal) if (!fullReg && inFifoMode);
            pushReg[0] <= tagged Valid inputVal;
        endmethod

        // It can dequeue when inFifoMode or inScanMode
        method Action deq() if (!emptyReg && (inFifoMode || inScanMode));
            // Make sure no dequeue when scan start or scan restart
            immAssert(
                !scanStartReg[1] && !preScanRestartReg[1],
                "dequeue assertion @ mkScanFIFOF",
                $format(
                    "cannot dequeue when scanStartReg=", fshow(scanStartReg[1]),
                    " or preScanRestartReg=", fshow(preScanRestartReg[1])
                )
            );

            popReg[0] <= True;
        endmethod

        method Action clear() if (inFifoMode);
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface scanOutIfc = interface ScanOutIfc#(qSz, anytype);
        method anytype current() if (inScanMode);
            return case (headReg[0]) matches
                tagged Valid .head: head;
                default           : dataVec[removeMSB(scanPtrReg)];
            endcase;
        endmethod

        method Action next if (inScanMode);
            scanNextReg[0] <= True;
            // $display(
            //     "time=%0t: scanPtrReg=%0d, nextScanPtr=%0d, enqPtrReg=%0d, deqPtrReg=%0d, scanStateReg=",
            //     $time, scanPtrReg, nextScanPtr, enqPtrReg, deqPtrReg, fshow(scanStateReg)
            // );
        endmethod

        // method Bool isEmpty() if (inScanMode) = emptyReg;
    endinterface;

    interface scanCntrlIfc = interface ScanCntrlIfc;
        method anytype getHead() if (inPreScanMode);
            return dataVec[removeMSB(deqPtrReg)];
        endmethod

        method Action modifyHead(anytype head) if (inPreScanMode);
            headReg[0] <= tagged Valid head;
        endmethod

        method Action preScanStart() if (inFifoMode);
            preScanStartReg[0] <= True;
        endmethod

        method Action scanStart() if (inPreScanMode);
            scanStartReg[0] <= True;
            // $display(
            //     "time=%0t: scanStart(), scanPtrReg=%0d, deqPtrReg=%0d, enqPtrReg=%0d",
            //     $time, scanPtrReg, deqPtrReg, enqPtrReg,
            //     ", scanStateReg=", fshow(scanStateReg),
            //     ", emptyReg=", fshow(emptyReg)
            // );
        endmethod

        method Action preScanRestart() if (inScanMode);
            preScanRestartReg[0] <= True;
            // immAssert(
            //     !emptyReg,
            //     "emptyReg assertion @ mkScanFIFOF",
            //     $format("cannot restart scan when emptyReg=", fshow(emptyReg))
            // );
        endmethod

        method Bool isScanDone() = inFifoMode;

        method Bool isScanMode() = inScanMode;
    endinterface;

    // method UInt#(cntSz) count = itemCnt;
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

    // function Bool isFull(Bit#(cntSz) nextEnqPtr);
    //     return (getMSB(nextEnqPtr) != getMSB(deqPtrReg[1])) &&
    //         (removeMSB(nextEnqPtr) == removeMSB(deqPtrReg[1]));
    // endfunction

    function Action clearTag(Array#(Reg#(Bool)) tagReg);
        action
            tagReg[2] <= False;
        endaction
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
            fullReg[1]   <= isFull(nextEnqPtr, deqPtrReg[1]);
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
            mapM_(clearTag, tagVec);
            // for (Integer idx = 0; idx < valueOf(qSz); idx = idx + 1) begin
            //     tagVec[idx][2] <= False;
            // end
            enqPtrReg[2] <= 0;
            deqPtrReg[2] <= 0;
            emptyReg[2]  <= True;
            fullReg[2]   <= False;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc#(anytype);
        method Maybe#(anytype) search(function Bool searchFunc(anytype fifoItem));
            let zipVec = zip(tagVec, dataVec);
            // TODO: change findIndex() to find()
            let maybeFindResult = findIndex(predFunc(searchFunc), zipVec);
            if (maybeFindResult matches tagged Valid .index) begin
                // let tag = readReg(tagVec[index]);
                // immAssert(
                //     tag,
                //     "tag assertion @ mkSearchFIFOF",
                //     $format("search found tag=", fshow(tag), " must be true")
                // );
                return tagged Valid readReg(dataVec[index]);
            end
            else begin
                return tagged Invalid;
            end
        endmethod
    endinterface;
endmodule


interface SearchIfc2#(type anytype);
    method Action searchReq(function Bool searchFunc(anytype fifoItem));
    method ActionValue#(Maybe#(anytype)) searchResp();
endinterface

interface CacheQIfc#(type anytype);
    method Action push(anytype inputVal);
    method Action clear();
endinterface

interface CacheFIFO#(numeric type qSz, type anytype);
    interface CacheQIfc#(anytype) cacheQIfc;
    interface SearchIfc2#(anytype) searchIfc;
endinterface

module mkCacheFIFO(CacheFIFO#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(qSz), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Vector#(qSz, Reg#(Bool))     tagVec <- replicateM(mkReg(False));

    FIFOF#(Maybe#(anytype)) searchResultQ <- mkFIFOF;

    Reg#(Maybe#(anytype)) pushValReg[3] <- mkCReg(3, tagged Invalid);
    Reg#(Bool)              clearReg[2] <- mkCReg(2, False);

    Reg#(Bit#(cntSz)) enqPtrReg <- mkReg(0);

    function Bool predFunc(
        function Bool searchFunc(anytype fifoItem),
        Tuple2#(Bool, anytype) zipItem
    );
        let { tag, anydata } = zipItem;
        return tag && searchFunc(anydata);
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            writeVReg(tagVec, replicate(False));
            enqPtrReg   <= 0;
            clearReg[1] <= False;
        end
        else begin
            if (pushValReg[2] matches tagged Valid .pushVal) begin
                dataVec[enqPtrReg] <= pushVal;
                tagVec[enqPtrReg]  <= True;

                enqPtrReg     <= enqPtrReg + 1;
                pushValReg[2] <= tagged Invalid;
            end
        end
    endrule

    interface cacheQIfc = interface CacheQIfc#(anytype);
        method Action push(anytype pushVal);
            pushValReg[0] <= tagged Valid pushVal;
        endmethod

        method Action clear();
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc2#(anytype);
        method Action searchReq(function Bool searchFunc(anytype fifoItem));
            let zipVec = zip(readVReg(tagVec), readVReg(dataVec));
            // TODO: change findIndex() to find()
            let maybeFindResult = findIndex(predFunc(searchFunc), zipVec);
            if (maybeFindResult matches tagged Valid .index) begin
                searchResultQ.enq(tagged Valid dataVec[index]);
            // let maybeFindResult = find(predFunc(searchFunc), zipVec);
            // if (maybeFindResult matches tagged Valid .findResult) begin
            //     searchResultQ.enq(tagged Valid getTupleSecond(findResult));
            end
            else if (pushValReg[1] matches tagged Valid .pushVal &&& searchFunc(pushVal)) begin
                searchResultQ.enq(pushValReg[1]);
            end
            else begin
                searchResultQ.enq(tagged Invalid);
            end
        endmethod

        method ActionValue#(Maybe#(anytype)) searchResp();
            let maybeFindResult = searchResultQ.first;
            searchResultQ.deq;

            return maybeFindResult;
        endmethod
    endinterface;
endmodule
