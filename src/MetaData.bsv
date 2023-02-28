import Arbitration :: *;
import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: * ;
import FIFOF :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;

interface TagVector#(numeric type vSz, type anytype);
    method Action insertReq(anytype insertVal);
    method ActionValue#(UInt#(TLog#(vSz))) insertResp();
    method Action removeReq(UInt#(TLog#(vSz)) index);
    method ActionValue#(Bool) removeResp();
    method Maybe#(anytype) getItem(UInt#(TLog#(vSz)) index);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkTagVector(TagVector#(vSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(vSz), vLogSz),
    NumAlias#(TAdd#(1, vLogSz), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(vSz, 1))) // vSz must be power of 2
);
    Vector#(vSz, Reg#(anytype))     dataVec <- replicateM(mkRegU);
    Vector#(vSz, Array#(Reg#(Bool))) tagVec <- replicateM(mkCReg(2, False));

    Reg#(Bool) emptyReg <- mkReg(True);
    Reg#(Bool)  fullReg <- mkReg(False);

    Reg#(Maybe#(anytype))       insertReqReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Maybe#(UInt#(vLogSz))) removeReqReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)                      clearReg[2] <- mkCReg(2, False);

    FIFOF#(UInt#(vLogSz)) insertRespQ <- mkFIFOF;
    FIFOF#(Bool)          removeRespQ <- mkFIFOF;

    Count#(Bit#(cntSz)) itemCnt <- mkCount(0);

    function Bool readTagVecPort1(Array#(Reg#(Bool)) tagArray) = tagArray[1];
    function Action clearTag(Array#(Reg#(Bool)) tagReg);
        action
            tagReg[1] <= False;
        endaction
    endfunction

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            itemCnt   <= 0;
            emptyReg  <= True;
            fullReg   <= False;
            mapM_(clearTag, tagVec);
            // for (Integer idx = 0; idx < valueOf(vSz); idx = idx + 1) begin
            //     tagVec[idx][1] <= False;
            // end
            insertRespQ.clear;
            removeRespQ.clear;
        end
        else begin
            let inserted = False;
            let tagVecPort1 = map(readTagVecPort1, tagVec);
            if (insertReqReg[1] matches tagged Valid .insertVal) begin
                let maybeIndex = findElem(False, tagVecPort1);
                if (maybeIndex matches tagged Valid .index) begin
                    tagVec[index][1] <= True;
                    dataVec[index] <= insertVal;
                    insertRespQ.enq(index);
                    inserted = True;
                end
            end

            let removed = False;
            if (removeReqReg[1] matches tagged Valid .index) begin
                removed = True;
            end

            let almostFull = isAllOnes(removeMSB(itemCnt));
            let almostEmpty = isOne(itemCnt);
            if (inserted && !removed) begin
                itemCnt.incr(1);
                emptyReg <= False;
                fullReg <= almostFull;
            end
            else if (!inserted && removed) begin
                itemCnt.decr(1);
                emptyReg <= almostEmpty;
                fullReg <= False;
            end

            // $display(
            //     "time=%0t: inserted=", $time, fshow(inserted),
            //     ", removed=", fshow(removed)
            // );
        end

        clearReg[1] <= False;
        insertReqReg[1] <= tagged Invalid;
        removeReqReg[1] <= tagged Invalid;
    endrule

    method Maybe#(anytype) getItem(UInt#(vLogSz) index);
        return (tagVec[index][0]) ? (tagged Valid dataVec[index]) : (tagged Invalid);
    endmethod

    method Action insertReq(anytype inputVal) if (!fullReg && !isValid(insertReqReg[0]));
        insertReqReg[0] <= tagged Valid inputVal;
    endmethod
    method ActionValue#(UInt#(TLog#(vSz))) insertResp();
        insertRespQ.deq;
        return insertRespQ.first;
    endmethod

    method Action removeReq(UInt#(TLog#(vSz)) index) if (!emptyReg && !isValid(removeReqReg[0]));
        removeReqReg[0] <= tagged Valid index;
        tagVec[index][0] <= False;
        removeRespQ.enq(tagVec[index][0]);
    endmethod
    method ActionValue#(Bool) removeResp();
        removeRespQ.deq;
        return removeRespQ.first;
    endmethod

    method Action clear();
        clearReg[0] <= True;
    endmethod

    method Bool notEmpty() = !emptyReg;
    method Bool notFull()  = !fullReg;
endmodule
/*
interface TagVecWrapper#(numeric type vSz, type vecItemType, type allocRespType, type deAllocReqType);
    interface Server#(vecItemType, Maybe#(allocRespType)) allocSrv;
    interface Server#(deAllocReqType, Bool) deAllocSrv;
    method Maybe#(vecItemType) getItem(UInt#(TLog#(vSz)) index);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkTagVecWrapper#(
    function allocRespType genAllocResp(UInt#(TLog#(vSz)) tagVecIdx, vecItemType vecItem),
    function UInt#(TLog#(vSz)) genDeAllocIdx(deAllocReqType deAllocReq)
)(TagVecWrapper#(vSz, vecItemType, allocRespType, deAllocReqType)) provisos(
    Bits#(vecItemType, tSz),
    Bits#(allocRespType, allocRespSz),
    Bits#(deAllocReqType, deAllocReqSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(vSz, 1))) // vSz must be power of 2
);
    TagVector#(vSz, vecItemType) tagVec <- mkTagVector;

    FIFOF#(Maybe#(vecItemType)) pendingAllocReqQ <- mkFIFOF;
    FIFOF#(Bool)              pendingDeAllocReqQ <- mkFIFOF;

    FIFOF#(vecItemType)                allocReqQ <- mkFIFOF;
    FIFOF#(Maybe#(allocRespType)) allocRespQ <- mkFIFOF;

    FIFOF#(deAllocReqType) deAllocReqQ <- mkFIFOF;
    FIFOF#(Bool)             deAllocRespQ <- mkFIFOF;

    rule handleAllocReq;
        let vecItem = allocReqQ.first;
        allocReqQ.deq;

        if (tagVec.notFull) begin
            pendingAllocReqQ.enq(tagged Valid vecItem);
            tagVec.insertReq(vecItem);
        end
        else begin
            pendingAllocReqQ.enq(tagged Invalid);
        end
    endrule

    rule handleAllocResp;
        let maybeVecItem = pendingAllocReqQ.first;
        pendingAllocReqQ.deq;

        if (maybeVecItem matches tagged Valid .vecItem) begin
            let tagVecIdx <- tagVec.insertResp;
            let allocResp = genAllocResp(tagVecIdx, vecItem);
            allocRespQ.enq(tagged Valid allocResp);
        end
        else begin
            allocRespQ.enq(tagged Invalid);
        end
    endrule

    rule handleDeAllocReq;
        let deAllocReq = deAllocReqQ.first;
        deAllocReqQ.deq;

        let vecItemIdx = genDeAllocIdx(deAllocReq);

        if (tagVec.notEmpty) begin
            tagVec.removeReq(vecItemIdx);
        end
        pendingDeAllocReqQ.enq(tagVec.notEmpty);
    endrule

    rule handleDeAllocResp;
        let pendingDeAllocReq = pendingDeAllocReqQ.first;
        pendingDeAllocReqQ.deq;

        if (pendingDeAllocReq) begin
            let deAllocResp <- tagVec.removeResp;
        end
        deAllocRespQ.enq(pendingDeAllocReq);
    endrule

    interface allocSrv   = toGPServer(allocReqQ, allocRespQ);
    interface deAllocSrv = toGPServer(deAllocReqQ, deAllocRespQ);
    method Maybe#(vecItemType) getItem(UInt#(TLog#(vSz)) index) = tagVec.getItem(index);
    method Action clear();
        tagVec.clear;
        pendingAllocReqQ.clear;
        pendingDeAllocReqQ.clear;
        allocReqQ.clear;
        allocRespQ.clear;
        deAllocReqQ.clear;
        deAllocRespQ.clear;
    endmethod
    method Bool notEmpty() = tagVec.notEmpty;
    method Bool notFull() = tagVec.notFull;
endmodule
*/
interface TagVecSrv#(numeric type vSz, type anytype);
    interface Server#(
        Tuple3#(Bool, anytype, UInt#(TLog#(vSz))),
        Tuple3#(Bool, UInt#(TLog#(vSz)), anytype)
    ) srvPort;
    method Maybe#(anytype) getItem(UInt#(TLog#(vSz)) index);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkTagVecSrv(TagVecSrv#(vSz, anytype)) provisos(
    FShow#(anytype),
    Bits#(anytype, tSz),
    NumAlias#(TLog#(vSz), vLogSz),
    NumAlias#(TAdd#(1, vLogSz), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(vSz, 1))) // vSz must be power of 2
);
    Vector#(vSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Vector#(vSz, Reg#(Bool))     tagVec <- replicateM(mkReg(False));

    Reg#(Bool)    emptyReg <- mkReg(True);
    Reg#(Bool)     fullReg <- mkReg(False);
    Reg#(Bool) clearReg[2] <- mkCReg(2, False);

    FIFOF#(Tuple3#(Bool, anytype, UInt#(TLog#(vSz))))  reqQ <- mkFIFOF;
    FIFOF#(Tuple3#(Bool, UInt#(TLog#(vSz)), anytype)) respQ <- mkFIFOF;

    Count#(Bit#(cntSz)) itemCnt <- mkCount(0);

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            itemCnt   <= 0;
            emptyReg  <= True;
            fullReg   <= False;
            writeVReg(tagVec, replicate(False));
            reqQ.clear;
            respQ.clear;
        end
        else begin
            let { insertOrRemove, insertVal, removeIdx } = reqQ.first;
            reqQ.deq;

            let inserted = False;
            let insertIdx = dontCareValue;
            let removed = False;
            if (insertOrRemove) begin // Insert
                if (!fullReg) begin
                    let maybeIndex = findElem(False, readVReg(tagVec));
                    immAssert(
                        isValid(maybeIndex),
                        "maybeIndex assertion @ mkTagVecSrv",
                        $format(
                            "maybeIndex=", fshow(maybeIndex),
                            " should be valid"
                        )
                    );

                    insertIdx = unwrapMaybe(maybeIndex);
                    tagVec[insertIdx] <= True;
                    dataVec[insertIdx] <= insertVal;
                    inserted = True;
                end
                respQ.enq(tuple3(inserted, insertIdx, insertVal));
            end
            else begin // Remove
                let removeTag = tagVec[removeIdx];
                let removeVal = dataVec[removeIdx];
                if (removeTag) begin
                    removed = True;
                    tagVec[removeIdx] <= False;
                end
                respQ.enq(tuple3(removed, removeIdx, removeVal));
            end

            let almostFull = isAllOnes(removeMSB(itemCnt));
            let almostEmpty = isOne(itemCnt);
            if (inserted) begin
                itemCnt.incr(1);
                emptyReg <= False;
                fullReg <= almostFull;
            end
            else if (removed) begin
                itemCnt.decr(1);
                emptyReg <= almostEmpty;
                fullReg <= False;
            end
            immAssert(
                !(inserted && removed),
                "inserted and removed assertion @ mkTagVecSrv",
                $format(
                    "inserted=", fshow(inserted),
                    " and removed=", fshow(removed),
                    " cannot both be true"
                )
            );
            immAssert(
                fromInteger(valueOf(vSz)) >= itemCnt,
                "itemCnt assertion @ mkTagVecSrv",
                $format(
                    "itemCnt=%0d should be less or equal to vSz=%0d",
                    itemCnt, valueOf(vSz)
                )
            );

            // $display(
            //     "time=%0t: inserted=", $time, fshow(inserted),
            //     ", removed=", fshow(removed),
            //     ", itemCnt=%0d, req=", itemCnt, fshow(reqQ.first)
            // );
        end

        clearReg[1] <= False;
    endrule

    interface srvPort = toGPServer(reqQ, respQ);

    method Maybe#(anytype) getItem(UInt#(vLogSz) index);
        return (tagVec[index]) ? (tagged Valid dataVec[index]) : (tagged Invalid);
    endmethod

    method Action clear();
        clearReg[0] <= True;
    endmethod

    method Bool notEmpty() = !emptyReg;
    method Bool notFull()  = !fullReg;
endmodule

// MR related

typedef TDiv#(MAX_MR, MAX_PD) MAX_MR_PER_PD;
typedef TLog#(MAX_MR_PER_PD) MR_INDEX_WIDTH;
typedef TSub#(KEY_WIDTH, MR_INDEX_WIDTH) MR_KEY_PART_WIDTH;

typedef UInt#(MR_INDEX_WIDTH) IndexMR;
typedef Bit#(MR_KEY_PART_WIDTH) KeyPartMR;

typedef struct {
    ADDR laddr;
    Length len;
    MemAccessTypeFlags accType;
    HandlerPD pdHandler;
    KeyPartMR lkeyPart;
    KeyPartMR rkeyPart;
} MemRegion deriving(Bits, FShow);

typedef struct {
    Bool allocOrNot;
    MemRegion mr;
    Bool lkeyOrNot;
    LKEY lkey;
    RKEY rkey;
} ReqMR deriving(Bits, FShow);

typedef struct {
    Bool successOrNot;
    MemRegion mr;
    LKEY lkey;
    RKEY rkey;
} RespMR deriving(Bits, FShow);

typedef Server#(ReqMR, RespMR) SrvPortMR;

interface MetaDataMRs;
    interface SrvPortMR srvPort;
    method Maybe#(MemRegion) getMemRegionByLKey(LKEY lkey);
    method Maybe#(MemRegion) getMemRegionByRKey(RKEY rkey);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataMRs(MetaDataMRs);
    TagVecSrv#(MAX_MR_PER_PD, MemRegion) mrTagVec <- mkTagVecSrv;

    function Tuple2#(LKEY, RKEY) genLocalAndRmtKey(IndexMR mrIndex, MemRegion mr);
        LKEY lkey = { pack(mrIndex), mr.lkeyPart };
        RKEY rkey = { pack(mrIndex), mr.rkeyPart };
        return tuple2(lkey, rkey);
    endfunction

    function IndexMR lkey2IndexMR(LKEY lkey) = unpack(truncateLSB(lkey));
    function IndexMR rkey2IndexMR(RKEY rkey) = unpack(truncateLSB(rkey));

    interface srvPort = interface SrvPortMR;
        interface request = interface Put#(ReqMR);
            method Action put(ReqMR mrReq);
                IndexMR mrIndex = mrReq.lkeyOrNot ?
                    lkey2IndexMR(mrReq.lkey) : rkey2IndexMR(mrReq.rkey);
                mrTagVec.srvPort.request.put(tuple3(
                    mrReq.allocOrNot, mrReq.mr, mrIndex
                ));
            endmethod
        endinterface;

        interface response = interface Get#(RespMR);
            method ActionValue#(RespMR) get();
                let { successOrNot, mrIndex, mr } <- mrTagVec.srvPort.response.get;
                let { lkey, rkey } = genLocalAndRmtKey(mrIndex, mr);
                let mrResp = RespMR {
                    successOrNot: successOrNot,
                    mr          : mr,
                    lkey        : lkey,
                    rkey        : rkey
                };
                return mrResp;
            endmethod
        endinterface;
    endinterface;

    method Maybe#(MemRegion) getMemRegionByLKey(LKEY lkey);
        IndexMR mrIndex = lkey2IndexMR(lkey);
        return mrTagVec.getItem(mrIndex);
    endmethod

    method Maybe#(MemRegion) getMemRegionByRKey(RKEY rkey);
        IndexMR mrIndex = rkey2IndexMR(rkey);
        return mrTagVec.getItem(mrIndex);
    endmethod

    method Action clear() = mrTagVec.clear;
    method Bool notEmpty() = mrTagVec.notEmpty;
    method Bool notFull() = mrTagVec.notFull;
endmodule
/*
typedef struct {
    IndexMR mrIndex;
    LKEY lkey;
    Maybe#(RKEY) rkey;
} AllocRespMR deriving(Bits, FShow);

typedef Server#(MemRegion, Maybe#(AllocRespMR)) AllocMR;
typedef Server#(IndexMR, Bool) DeAllocMR;

interface MetaDataMRs;
    interface AllocMR allocMR;
    interface DeAllocMR deAllocMR;
    method Maybe#(MemRegion) getMR(IndexMR mrIndex);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function Maybe#(MemRegion) getMemRegionByLKey(MetaDataMRs mrMetaData, LKEY lkey);
    IndexMR mrIndex = unpack(truncateLSB(lkey));
    return mrMetaData.getMR(mrIndex);
endfunction

function Maybe#(MemRegion) getMemRegionByRKey(MetaDataMRs mrMetaData, RKEY rkey);
    IndexMR mrIndex = unpack(truncateLSB(rkey));
    return mrMetaData.getMR(mrIndex);
endfunction

module mkMetaDataMRs(MetaDataMRs);
    FIFOF#(MemRegion)   allocReqQ <- mkFIFOF;
    FIFOF#(AllocRespMR) allocRespQ <- mkFIFOF;
    FIFOF#(MemRegion)       mrOutQ <- mkFIFOF;

    FIFOF#(IndexMR) deAllocReqQ <- mkFIFOF;
    FIFOF#(Bool)   deAllocRespQ <- mkFIFOF;

    TagVector#(MAX_MR_PER_PD, MemRegion) mrTagVec <- mkTagVector;

    rule handleAllocReq;
        let mr = allocReqQ.first;
        allocReqQ.deq;

        // let mr = MemRegion {
        //     laddr    : allocReq.laddr,
        //     len      : allocReq.len,
        //     accType  : allocReq.accType,
        //     pdHandler: allocReq.pdHandler,
        //     lkeyPart : allocReq.lkeyPart,
        //     rkeyPart : allocReq.rkeyPart
        // };
        mrOutQ.enq(mr);
        mrTagVec.insertReq(mr);
    endrule

    rule handleAllocResp;
        let mrIndex <- mrTagVec.insertResp;
        let mr = mrOutQ.first;
        mrOutQ.deq;

        LKEY lkey = { pack(mrIndex), mr.lkeyPart };
        Maybe#(RKEY) rkey = case (mr.rkeyPart) matches
            tagged Valid .rmtKeyPart: begin
                RKEY rmtKey = { pack(mrIndex), rmtKeyPart };
                tagged Valid rmtKey;
            end
            default: tagged Invalid;
        endcase;

        let allocResp = AllocRespMR {
            mrIndex: mrIndex,
            lkey   : lkey,
            rkey   : rkey
        };
        allocRespQ.enq(allocResp);
    endrule

    rule handleDeAllocReq;
        let mrIndex = deAllocReqQ.first;
        deAllocReqQ.deq;

        mrTagVec.removeReq(mrIndex);
    endrule

    rule handleDeAllocResp;
        let deAllocResp <- mrTagVec.removeResp;
        deAllocRespQ.enq(deAllocResp);
    endrule

    interface allocMR   = toGPServer(allocReqQ, allocRespQ);
    interface deAllocMR = toGPServer(deAllocReqQ, deAllocRespQ);

    method Maybe#(MemRegion) getMR(IndexMR mrIndex) = mrTagVec.getItem(mrIndex);

    method Action clear();
        mrTagVec.clear;
        allocReqQ.clear;
        allocRespQ.clear;
        deAllocReqQ.clear;
        deAllocRespQ.clear;
        mrOutQ.clear;
    endmethod

    method Bool notEmpty() = mrTagVec.notEmpty;
    method Bool notFull() = mrTagVec.notFull;
endmodule

module mkMetaDataMRs(MetaDataMRs);
    function AllocRespMR genAllocRespMR(IndexMR mrIndex, MemRegion mr);
        LKEY lkey = { pack(mrIndex), mr.lkeyPart };
        Maybe#(RKEY) rkey = case (mr.rkeyPart) matches
            tagged Valid .rmtKeyPart: begin
                RKEY rmtKey = { pack(mrIndex), rmtKeyPart };
                tagged Valid rmtKey;
            end
            default: tagged Invalid;
        endcase;
        let allocResp = AllocRespMR {
            mrIndex: mrIndex,
            lkey   : lkey,
            rkey   : rkey
        };
        return allocResp;
    endfunction

    TagVecWrapper#(MAX_MR_PER_PD, MemRegion, AllocRespMR, IndexMR) tagVecWrapper <-
        mkTagVecWrapper(genAllocRespMR, identityFunc);

    interface allocMR   = tagVecWrapper.allocSrv;
    interface deAllocMR = tagVecWrapper.deAllocSrv;

    method Maybe#(MemRegion) getMR(IndexMR mrIndex) = tagVecWrapper.getItem(mrIndex);

    method Action clear() = tagVecWrapper.clear;
    method Bool notEmpty() = tagVecWrapper.notEmpty;
    method Bool notFull() = tagVecWrapper.notFull;
endmodule
*/
// PD related

typedef TLog#(MAX_PD) PD_INDEX_WIDTH;
typedef TSub#(PD_HANDLE_WIDTH, PD_INDEX_WIDTH) PD_KEY_WIDTH;

typedef Bit#(PD_KEY_WIDTH)    KeyPD;
typedef UInt#(PD_INDEX_WIDTH) IndexPD;
/*
typedef Server#(KeyPD, HandlerPD) AllocPD;
typedef Server#(HandlerPD, Bool) DeAllocPD;

interface MetaDataPDs;
    interface AllocPD allocPD;
    interface DeAllocPD deAllocPD;
    method Bool isValidPD(HandlerPD pdHandler);
    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataPDs(MetaDataPDs);
    TagVector#(MAX_PD, KeyPD) pdTagVec <- mkTagVector;
    Vector#(MAX_PD, MetaDataMRs) pdMrVec <- replicateM(mkMetaDataMRs);

    FIFOF#(KeyPD)       allocReqQ <- mkFIFOF;
    FIFOF#(HandlerPD)  allocRespQ <- mkFIFOF;
    FIFOF#(KeyPD)       pdKeyOutQ <- mkFIFOF;

    FIFOF#(HandlerPD) deAllocReqQ <- mkFIFOF;
    FIFOF#(Bool)     deAllocRespQ <- mkFIFOF;

    function IndexPD getIndexPD(HandlerPD pdHandler) = unpack(truncateLSB(pdHandler));
    function Action clearAllMRs(MetaDataMRs mrMetaData);
        action
            mrMetaData.clear;
        endaction
    endfunction

    rule handleAllocReq;
        let pdKey = allocReqQ.first;
        allocReqQ.deq;

        pdTagVec.insertReq(pdKey);
        pdKeyOutQ.enq(pdKey);
    endrule

    rule handleAllocResp;
        let pdIndex <- pdTagVec.insertResp;

        let pdKey = pdKeyOutQ.first;
        pdKeyOutQ.deq;

        HandlerPD pdHandler = { pack(pdIndex), pdKey };
        allocRespQ.enq(pdHandler);
    endrule

    rule handleDeAllocReq;
        let pdHandler = deAllocReqQ.first;
        deAllocReqQ.deq;

        let pdIndex = getIndexPD(pdHandler);
        pdTagVec.removeReq(pdIndex);
    endrule

    rule handleDeAllocResp;
        let deAllocResp <- pdTagVec.removeResp;
        deAllocRespQ.enq(deAllocResp);
    endrule

    interface allocPD   = toGPServer(allocReqQ, allocRespQ);
    interface deAllocPD = toGPServer(deAllocReqQ, deAllocRespQ);

    method Bool isValidPD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex));
    endmethod

    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex)) ?
            (tagged Valid pdMrVec[pdIndex]) : (tagged Invalid);
    endmethod

    method Action clear();
        pdTagVec.clear;
        allocReqQ.clear;
        allocRespQ.clear;
        deAllocReqQ.clear;
        deAllocRespQ.clear;
        pdKeyOutQ.clear;
        mapM_(clearAllMRs, pdMrVec);
    endmethod

    method Bool notEmpty() = pdTagVec.notEmpty;
    method Bool notFull()  = pdTagVec.notFull;
endmodule
*/
typedef struct {
    Bool allocOrNot;
    KeyPD pdKey;
    HandlerPD pdHandler;
} ReqPD deriving(Bits, FShow);

typedef struct {
    Bool successOrNot;
    HandlerPD pdHandler;
    KeyPD pdKey;
} RespPD deriving(Bits, FShow);

typedef Server#(ReqPD, RespPD) SrvPortPD;

interface MetaDataPDs;
    interface SrvPortPD srvPort;
    method Bool isValidPD(HandlerPD pdHandler);
    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataPDs(MetaDataPDs);
    TagVecSrv#(MAX_PD, KeyPD) pdTagVec <- mkTagVecSrv;
    Vector#(MAX_PD, MetaDataMRs) pdMrVec <- replicateM(mkMetaDataMRs);

    function IndexPD getIndexPD(HandlerPD pdHandler) = unpack(truncateLSB(pdHandler));
    function Action clearAllMRs(MetaDataMRs mrMetaData);
        action
            mrMetaData.clear;
        endaction
    endfunction

    interface srvPort = interface SrvPortMR;
        interface request = interface Put#(ReqPD);
            method Action put(ReqPD pdReq);
                IndexPD pdIndex = getIndexPD(pdReq.pdHandler);
                pdTagVec.srvPort.request.put(tuple3(
                    pdReq.allocOrNot, pdReq.pdKey, pdIndex
                ));
            endmethod
        endinterface;

        interface response = interface Get#(RespPD);
            method ActionValue#(RespPD) get();
                let { successOrNot, pdIndex, pdKey } <- pdTagVec.srvPort.response.get;
                HandlerPD pdHandler = { pack(pdIndex), pdKey };
                let pdResp = RespPD {
                    successOrNot: successOrNot,
                    pdHandler   : pdHandler,
                    pdKey       : pdKey
                };
                return pdResp;
            endmethod
        endinterface;
    endinterface;

    method Bool isValidPD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex));
    endmethod

    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex)) ?
            (tagged Valid pdMrVec[pdIndex]) : (tagged Invalid);
    endmethod

    method Action clear();
        pdTagVec.clear;
        mapM_(clearAllMRs, pdMrVec);
    endmethod

    method Bool notEmpty() = pdTagVec.notEmpty;
    method Bool notFull()  = pdTagVec.notFull;
endmodule

// QP related

typedef TLog#(MAX_QP) QP_INDEX_WIDTH;
typedef UInt#(QP_INDEX_WIDTH) IndexQP;
/*
typedef Server#(QKEY, QPN) CreateQP;
typedef Server#(QPN, Bool) DestroyQP;

interface MetaDataQPs;
    interface CreateQP createQP;
    interface DestroyQP destroyQP;
    method Bool isValidQP(QPN qpn);
    method Maybe#(HandlerPD) getPD(QPN qpn);
    method Controller getCntrlByQPN(QPN qpn);
    method Controller getCntrlByIdxQP(IndexQP qpIndex);
    // method Maybe#(Controller) getCntrl2(QPN qpn);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function IndexQP getIndexQP(QPN qpn) = unpack(truncateLSB(qpn));

module mkMetaDataQPs(MetaDataQPs);
    TagVector#(MAX_QP, HandlerPD) qpTagVec <- mkTagVector;
    Vector#(MAX_QP, Controller) qpCntrlVec <- replicateM(mkController);

    FIFOF#(QKEY)      createReqQ <- mkFIFOF;
    FIFOF#(QPN)      createRespQ <- mkFIFOF;
    FIFOF#(HandlerPD) pdHandlerQ <- mkFIFOF;

    FIFOF#(QPN)   destroyReqQ <- mkFIFOF;
    FIFOF#(Bool) destroyRespQ <- mkFIFOF;

    rule handleCreateQP;
        let pdHandler = createReqQ.first;
        createReqQ.deq;

        qpTagVec.insertReq(pdHandler);
        pdHandlerQ.enq(pdHandler);
    endrule

    rule handleCreateResp;
        let qpIndex <- qpTagVec.insertResp;

        let pdHandler = pdHandlerQ.first;
        pdHandlerQ.deq;

        QPN qpn = { pack(qpIndex), truncateLSB(pdHandler) };
        createRespQ.enq(qpn);
    endrule

    rule handleDestroyQP;
        let qpn = destroyReqQ.first;
        destroyReqQ.deq;

        let qpIndex = getIndexQP(qpn);
        qpTagVec.removeReq(qpIndex);
    endrule

    rule handleDestroyResp;
        let destroyResp <- qpTagVec.removeResp;
        destroyRespQ.enq(destroyResp);
    endrule

    interface createQP  = toGPServer(createReqQ, createRespQ);
    interface destroyQP = toGPServer(destroyReqQ, destroyRespQ);

    method Bool isValidQP(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return isValid(qpTagVec.getItem(qpIndex));
    endmethod

    method Maybe#(HandlerPD) getPD(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return qpTagVec.getItem(qpIndex);
    endmethod

    method Controller getCntrlByQPN(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        let qpCntrl = qpCntrlVec[qpIndex];
        return qpCntrl;
    endmethod

    method Controller getCntrlByIdxQP(IndexQP qpIndex) = qpCntrlVec[qpIndex];
    // method Maybe#(Controller) getCntrl2(QPN qpn);
    //     let qpIndex = getIndexQP(qpn);
    //     let qpCntrl = qpCntrlVec[qpIndex];
    //     let pdHandler = qpTagVec.getItem(qpIndex);
    //     return isValid(pdHandler) ? tagged Valid qpCntrl : tagged Invalid;
    // endmethod

    method Action clear();
        qpTagVec.clear;
        createReqQ.clear;
        createRespQ.clear;
        destroyReqQ.clear;
        destroyRespQ.clear;
        pdHandlerQ.clear;
    endmethod

    method Bool notEmpty() = qpTagVec.notEmpty;
    method Bool notFull()  = qpTagVec.notFull;
endmodule
*/
typedef struct {
    Bool createOrNot;
    HandlerPD pdHandler;
    QPN qpn;
} ReqQP deriving(Bits, FShow);

typedef struct {
    Bool successOrNot;
    QPN qpn;
    HandlerPD pdHandler;
} RespQP deriving(Bits, FShow);

typedef Server#(ReqQP, RespQP) SrvPortQP;

interface MetaDataQPs;
    interface SrvPortQP srvPort;
    method Bool isValidQP(QPN qpn);
    method Maybe#(HandlerPD) getPD(QPN qpn);
    method Controller getCntrlByQPN(QPN qpn);
    method Controller getCntrlByIdxQP(IndexQP qpIndex);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function IndexQP getIndexQP(QPN qpn) = unpack(truncateLSB(qpn));

module mkMetaDataQPs(MetaDataQPs);
    TagVecSrv#(MAX_QP, HandlerPD) qpTagVec <- mkTagVecSrv;
    Vector#(MAX_QP, Controller) qpCntrlVec <- replicateM(mkController);

    interface srvPort = interface SrvPortQP;
        interface request = interface Put#(ReqQP);
            method Action put(ReqQP qpReq);
                IndexQP qpIndex = getIndexQP(qpReq.qpn);
                qpTagVec.srvPort.request.put(tuple3(
                    qpReq.createOrNot, qpReq.pdHandler, qpIndex
                ));
            endmethod
        endinterface;

        interface response = interface Get#(RespQP);
            method ActionValue#(RespQP) get();
                let { successOrNot, qpIndex, pdHandler } <- qpTagVec.srvPort.response.get;
                QPN qpn = { pack(qpIndex), truncateLSB(pdHandler) };
                let qpResp = RespQP {
                    successOrNot: successOrNot,
                    qpn         : qpn,
                    pdHandler   : pdHandler
                };
                return qpResp;
            endmethod
        endinterface;
    endinterface;
/*
    method Action createQP(HandlerPD pdHandler);
        qpTagVec.insertReq(pdHandler);
        pdHandlerOutQ.enq(pdHandler);
    endmethod
    method ActionValue#(QPN) createResp();
        let qpIndex <- qpTagVec.insertResp;
        let pdHandler = pdHandlerOutQ.first;
        pdHandlerOutQ.deq;
        QPN qpn = { pack(qpIndex), truncateLSB(pdHandler) };
        return qpn;
    endmethod

    method Action destroyQP(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        qpTagVec.removeReq(qpIndex);
    endmethod
    method ActionValue#(Bool) destroyResp() = qpTagVec.removeResp;
*/
    method Bool isValidQP(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return isValid(qpTagVec.getItem(qpIndex));
    endmethod

    method Maybe#(HandlerPD) getPD(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return qpTagVec.getItem(qpIndex);
    endmethod

    method Controller getCntrlByQPN(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        let qpCntrl = qpCntrlVec[qpIndex];
        return qpCntrl;
    endmethod

    method Controller getCntrlByIdxQP(IndexQP qpIndex) = qpCntrlVec[qpIndex];

    method Action clear() = qpTagVec.clear;
    method Bool notEmpty() = qpTagVec.notEmpty;
    method Bool notFull()  = qpTagVec.notFull;
endmodule

// MR check related
/*
interface PermCheckMR;
    method Action checkReq(PermCheckInfo permCheckInfo);
    method ActionValue#(Bool) checkResp();
endinterface

module mkPermCheckMR#(MetaDataPDs pdMetaData)(PermCheckMR);
    FIFOF#(Tuple3#(PermCheckInfo, Bool, Maybe#(MemRegion))) checkReqQ <- mkFIFOF;

    function Bool checkPermByMR(PermCheckInfo permCheckInfo, MemRegion mr);
        let keyMatch = case (permCheckInfo.localOrRmtKey)
            True : (truncate(permCheckInfo.lkey) == mr.lkeyPart);
            False: (isValid(mr.rkeyPart) ?
                truncate(permCheckInfo.rkey) == unwrapMaybe(mr.rkeyPart) : False);
        endcase;

        let accTypeMatch = compareAccessTypeFlags(permCheckInfo.accType, mr.accType);

        let addrLenMatch = checkAddrAndLenWithinRange(
            permCheckInfo.laddr, permCheckInfo.totalLen, mr.laddr, mr.len
        );
        return keyMatch && accTypeMatch && addrLenMatch;
    endfunction

    function Maybe#(MemRegion) mrSearchByLKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, LKEY lkey
    );
        let maybeMR = tagged Invalid;
        // let maybePD = qpMetaData.getPD(qpn);
        // if (maybePD matches tagged Valid .pdHandler) begin
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = getMemRegionByLKey(mrMetaData, lkey);
        end
        // end
        return maybeMR;
    endfunction

    function Maybe#(MemRegion) mrSearchByRKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, RKEY rkey
    );
        let maybeMR = tagged Invalid;
        // let maybePD = qpMetaData.getPD(qpn);
        // if (maybePD matches tagged Valid .pdHandler) begin
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = getMemRegionByRKey(mrMetaData, rkey);
        end
        // end
        return maybeMR;
    endfunction

    method Action checkReq(PermCheckInfo permCheckInfo);
        let isZeroDmaLen = isZero(permCheckInfo.totalLen);
        immAssert(
            !isZeroDmaLen,
            "isZeroDmaLen assertion @ mkPermCheckMR",
            $format(
                "isZeroDmaLen=", fshow(isZeroDmaLen),
                " should be false in PermCheckMR.checkReq()"
            )
        );

        let maybeMR = tagged Invalid;
        if (permCheckInfo.localOrRmtKey) begin
            maybeMR = mrSearchByLKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.lkey
            );
        end
        else begin
            maybeMR = mrSearchByRKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.rkey
            );
        end

        checkReqQ.enq(tuple3(permCheckInfo, isZeroDmaLen, maybeMR));
    endmethod

    method ActionValue#(Bool) checkResp();
        let { permCheckInfo, isZeroDmaLen, maybeMR } = checkReqQ.first;
        checkReqQ.deq;

        let checkResult = isZeroDmaLen;
        if (!isZeroDmaLen) begin
            if (maybeMR matches tagged Valid .mr) begin
                checkResult = checkPermByMR(permCheckInfo, mr);
            end
        end

        return checkResult;
    endmethod
endmodule
*/
typedef Server#(PermCheckInfo, Bool) PermCheckMR;

module mkPermCheckMR#(MetaDataPDs pdMetaData)(PermCheckMR);
    FIFOF#(PermCheckInfo) reqInQ <- mkFIFOF;
    FIFOF#(Bool) respOutQ <- mkFIFOF;
    FIFOF#(Tuple3#(PermCheckInfo, Bool, Maybe#(MemRegion))) checkReqQ <- mkFIFOF;

    function Bool checkPermByMR(PermCheckInfo permCheckInfo, MemRegion mr);
        let keyMatch = case (permCheckInfo.localOrRmtKey)
            True : (truncate(permCheckInfo.lkey) == mr.lkeyPart);
            False: (truncate(permCheckInfo.rkey) == mr.rkeyPart);
            // False: (isValid(mr.rkeyPart) ?
            //     truncate(permCheckInfo.rkey) == unwrapMaybe(mr.rkeyPart) : False);
        endcase;

        let accTypeMatch = compareAccessTypeFlags(permCheckInfo.accType, mr.accType);

        let addrLenMatch = checkAddrAndLenWithinRange(
            permCheckInfo.laddr, permCheckInfo.totalLen, mr.laddr, mr.len
        );
        return keyMatch && accTypeMatch && addrLenMatch;
    endfunction

    function Maybe#(MemRegion) mrSearchByLKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, LKEY lkey
    );
        let maybeMR = tagged Invalid;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = mrMetaData.getMemRegionByLKey(lkey);
        end
        return maybeMR;
    endfunction

    function Maybe#(MemRegion) mrSearchByRKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, RKEY rkey
    );
        let maybeMR = tagged Invalid;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = mrMetaData.getMemRegionByRKey(rkey);
        end
        return maybeMR;
    endfunction

    rule checkReq;
        let permCheckInfo = reqInQ.first;
        reqInQ.deq;

        let isZeroDmaLen = isZero(permCheckInfo.totalLen);
        immAssert(
            !isZeroDmaLen,
            "isZeroDmaLen assertion @ mkPermCheckMR",
            $format(
                "isZeroDmaLen=", fshow(isZeroDmaLen),
                " should be false in PermCheckMR.checkReq()"
            )
        );

        let maybeMR = tagged Invalid;
        if (permCheckInfo.localOrRmtKey) begin
            maybeMR = mrSearchByLKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.lkey
            );
        end
        else begin
            maybeMR = mrSearchByRKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.rkey
            );
        end

        checkReqQ.enq(tuple3(permCheckInfo, isZeroDmaLen, maybeMR));
    endrule

    rule checkResp;
        let { permCheckInfo, isZeroDmaLen, maybeMR } = checkReqQ.first;
        checkReqQ.deq;

        let checkResult = isZeroDmaLen;
        if (!isZeroDmaLen) begin
            if (maybeMR matches tagged Valid .mr) begin
                checkResult = checkPermByMR(permCheckInfo, mr);
            end
        end

        respOutQ.enq(checkResult);
    endrule

    return toGPServer(reqInQ, respOutQ);
endmodule

typedef Vector#(portSz, PermCheckMR) PermCheckArbiter#(numeric type portSz);

module mkPermCheckAribter#(PermCheckMR permCheckMR)(PermCheckArbiter#(portSz))
provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isPermCheckReqFinished(PermCheckInfo req) = True;
    function Bool isPermCheckRespFinished(Bool resp) = True;

    PermCheckArbiter#(portSz) arbiter <- mkServerArbiter(
        permCheckMR,
        isPermCheckReqFinished,
        isPermCheckRespFinished
    );
    return arbiter;
endmodule

// TLB related

typedef TExp#(11)  BRAM_CACHE_SIZE; // 2K
typedef BYTE_WIDTH BRAM_CACHE_DATA_WIDTH;

typedef Bit#(TLog#(BRAM_CACHE_SIZE)) BramCacheAddr;
typedef Bit#(BRAM_CACHE_DATA_WIDTH)  BramCacheData;

typedef Server#(BramCacheAddr, BramCacheData) BramRead;

interface BramCache;
    interface BramRead read;
    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
endinterface

// BramCache total size 2K * 8 = 16Kb
module mkBramCache(BramCache);
    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(BramCacheAddr, BramCacheData) bram2Port <- mkBRAM2Server(cfg);

    FIFOF#(BramCacheAddr)  bramReadReqQ <- mkFIFOF;
    FIFOF#(BramCacheData) bramReadRespQ <- mkFIFOF;

    rule handleBramReadReq;
        let cacheAddr = bramReadReqQ.first;
        bramReadReqQ.deq;

        let req = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: cacheAddr,
            datain: dontCareValue
        };
        bram2Port.portA.request.put(req);
    endrule

    rule handleBramReadResp;
        let readRespData <- bram2Port.portA.response.get;
        bramReadRespQ.enq(readRespData);
    endrule

    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
        let req = BRAMRequest{
            write: True,
            responseOnWrite: False,
            address: cacheAddr,
            datain: writeData
        };
        bram2Port.portB.request.put(req);
    endmethod

    interface read = toGPServer(bramReadReqQ, bramReadRespQ);
endmodule

interface CascadeCache#(numeric type addrWidth, numeric type payloadWidth);
    interface Server#(Bit#(addrWidth), Bit#(payloadWidth)) read;
    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
endinterface

module mkCascadeCache(CascadeCache#(addrWidth, payloadWidth))
provisos(
    NumAlias#(TLog#(BRAM_CACHE_SIZE), bramCacheIndexWidth),
    Add#(bramCacheIndexWidth, TAdd#(anysize, 1), addrWidth), // addrWidth > bramCacheIndexWidth
    NumAlias#(TDiv#(payloadWidth, BRAM_CACHE_DATA_WIDTH), colNum),
    Add#(TMul#(BRAM_CACHE_DATA_WIDTH, colNum), 0, payloadWidth), // payloadWidth must be multiplier of BYTE_WIDTH
    NumAlias#(TSub#(addrWidth, bramCacheIndexWidth), cascadeCacheIndexWidth),
    NumAlias#(TExp#(cascadeCacheIndexWidth), rowNum)
);
    function BramCacheAddr getBramCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncate(cacheAddr); // [valueOf(bramCacheIndexWidth) - 1 : 0];
    endfunction

    function Bit#(cascadeCacheIndexWidth) getCascadeCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncateLSB(cacheAddr); // [valueOf(addrWidth) - 1 : valueOf(bramCacheIndexWidth)];
    endfunction

    function Action readReqHelper(BramCacheAddr bramCacheIndex, BramCache bramCache);
        action
            bramCache.read.request.put(bramCacheIndex);
        endaction
    endfunction

    function ActionValue#(BramCacheData) readRespHelper(BramCache bramCache);
        actionvalue
            let bramCacheReadRespData <- bramCache.read.response.get;
            return bramCacheReadRespData;
        endactionvalue
    endfunction

    function Action writeHelper(
        BramCacheAddr bramCacheIndex, Tuple2#(BramCache, BramCacheData) tupleInput
    );
        action
            let { bramCache, writeData } = tupleInput;
            bramCache.write(bramCacheIndex, writeData);
        endaction
    endfunction

    function Bit#(payloadWidth) concatBitVec(BramCacheData bramCacheData, Bit#(payloadWidth) concatResult);
        return truncate({ concatResult, bramCacheData });
    endfunction
    // function Bit#(m) concatBitVec(Vector#(nSz, Bit#(n)) inputBitVec)
    // provisos(Add#(TMul#(n, nSz), 0, m));
    //     Bit#(m) result = dontCareValue;
    //     for (Integer idx = 0; idx < valueOf(n); idx = idx + 1) begin
    //         // result[(idx+1)*valueOf(n) : idx*valueOf(n)] = inputBitVec[idx];
    //         result = truncate({ result, inputBitVec[idx] });
    //     end
    //     return result;
    // endfunction

    Vector#(rowNum, Vector#(colNum, BramCache)) cascadeCacheVec <- replicateM(replicateM(mkBramCache));
    FIFOF#(Bit#(cascadeCacheIndexWidth)) cascadeCacheIndexQ <- mkFIFOF;
    FIFOF#(Bit#(addrWidth)) cacheReadReqQ <- mkFIFOF;
    FIFOF#(Bit#(payloadWidth)) cacheReadRespQ <- mkFIFOF;

    rule handleCacheReadReq;
        let cacheAddr = cacheReadReqQ.first;
        cacheReadReqQ.deq;

        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        mapM_(readReqHelper(bramCacheIndex), cascadeCacheVec[cascadeCacheIndex]);
        cascadeCacheIndexQ.enq(cascadeCacheIndex);
    endrule

    rule handleCacheReadResp;
        let cascadeCacheIndex = cascadeCacheIndexQ.first;
        cascadeCacheIndexQ.deq;
        Vector#(colNum, BramCacheData) bramCacheReadRespVec <- mapM(
            readRespHelper, cascadeCacheVec[cascadeCacheIndex]
        );
        Bit#(payloadWidth) concatSeed = dontCareValue;
        Bit#(payloadWidth) concatResult = foldr(concatBitVec, concatSeed, bramCacheReadRespVec);

        cacheReadRespQ.enq(concatResult);
    endrule

    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        Vector#(colNum, BramCacheData) writeDataVec = toChunks(writeData);
        Vector#(colNum, Tuple2#(BramCache, BramCacheData)) bramCacheAndWriteDataVec = zip(
            cascadeCacheVec[cascadeCacheIndex], writeDataVec
        );
        mapM_(writeHelper(bramCacheIndex), bramCacheAndWriteDataVec);
    endmethod

    interface read = toGPServer(cacheReadReqQ, cacheReadRespQ);
endmodule

typedef Tuple2#(Bool, ADDR) FindRespTLB;
typedef Server#(ADDR, FindRespTLB) FindInTLB;

interface TLB;
    interface FindInTLB find;
    method Action insert(ADDR va, ADDR pa);
    // TODO: implement delete method
    // method Action delete(ADDR va);
endinterface

function Bit#(PAGE_OFFSET_WIDTH) getPageOffset(ADDR addr);
    return truncate(addr);
endfunction

function ADDR restorePA(
    Bit#(TLB_CACHE_PA_DATA_WIDTH) paData, Bit#(PAGE_OFFSET_WIDTH) pageOffset
);
    return signExtend({ paData, pageOffset });
endfunction

function Bit#(TLB_CACHE_PA_DATA_WIDTH) getData4PA(ADDR pa);
    return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
endfunction

module mkTLB(TLB);
    CascadeCache#(TLB_CACHE_INDEX_WIDTH, TLB_PAYLOAD_WIDTH) cache4TLB <- mkCascadeCache;
    FIFOF#(ADDR) vaInputQ <- mkFIFOF;
    FIFOF#(ADDR) findReqQ <- mkFIFOF;
    FIFOF#(FindRespTLB) findRespQ <- mkFIFOF;

    function Bit#(TLB_CACHE_INDEX_WIDTH) getIndex4TLB(ADDR va);
        return truncate(va >> valueOf(PAGE_OFFSET_WIDTH));
    endfunction

    function Bit#(TLB_CACHE_TAG_WIDTH) getTag4TLB(ADDR va);
        return truncate(va >> valueOf(TAdd#(TLB_CACHE_INDEX_WIDTH, PAGE_OFFSET_WIDTH)));
    endfunction

    rule handleFindReq;
        let va = findReqQ.first;
        findReqQ.deq;

        let index = getIndex4TLB(va);
        cache4TLB.read.request.put(index);

        vaInputQ.enq(va);
    endrule

    rule handleFindResp;
        let va = vaInputQ.first;
        vaInputQ.deq;

        let inputTag = getTag4TLB(va);
        let pageOffset = getPageOffset(va);

        let readRespData <- cache4TLB.read.response.get;
        PayloadTLB payload = unpack(readRespData);

        let pa = restorePA(payload.data, pageOffset);
        let tagMatch = inputTag == payload.tag;

        findRespQ.enq(tuple2(tagMatch, pa));
    endrule

    method Action insert(ADDR va, ADDR pa);
        let index = getIndex4TLB(va);
        let inputTag = getTag4TLB(va);
        let paData = getData4PA(pa);
        let payload = PayloadTLB {
            data: paData,
            tag : inputTag
        };
        cache4TLB.write(index, pack(payload));
    endmethod

    interface find = toGPServer(findReqQ, findRespQ);
endmodule

/*
interface BramCache;
    method Action readReq(BramCacheAddr cacheAddr);
    method ActionValue#(BramCacheData) readResp();
    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
endinterface

// BramCache total size 2K * 8 = 16Kb
module mkBramCache(BramCache);
    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(BramCacheAddr, BramCacheData) bram2Port <- mkBRAM2Server(cfg);

    method Action readReq(BramCacheAddr cacheAddr);
        let req = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: cacheAddr,
            datain: dontCareValue
        };
        bram2Port.portA.request.put(req);
    endmethod

    method ActionValue#(BramCacheData) readResp();
        let readRespData <- bram2Port.portA.response.get;
        return readRespData;
    endmethod

    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
        let req = BRAMRequest{
            write: True,
            responseOnWrite: False,
            address: cacheAddr,
            datain: writeData
        };
        bram2Port.portB.request.put(req);
    endmethod
endmodule

interface CascadeCache#(numeric type addrWidth, numeric type payloadWidth);
    method Action readReq(Bit#(addrWidth) cacheAddr);
    method ActionValue#(Bit#(payloadWidth)) readResp();
    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
endinterface

module mkCascadeCache(CascadeCache#(addrWidth, payloadWidth))
provisos(
    NumAlias#(TLog#(BRAM_CACHE_SIZE), bramCacheIndexWidth),
    Add#(bramCacheIndexWidth, TAdd#(anysize, 1), addrWidth), // addrWidth > bramCacheIndexWidth
    NumAlias#(TDiv#(payloadWidth, BRAM_CACHE_DATA_WIDTH), colNum),
    Add#(TMul#(BRAM_CACHE_DATA_WIDTH, colNum), 0, payloadWidth), // payloadWidth must be multiplier of BYTE_WIDTH
    NumAlias#(TSub#(addrWidth, bramCacheIndexWidth), cascadeCacheIndexWidth),
    NumAlias#(TExp#(cascadeCacheIndexWidth), rowNum)
);
    function BramCacheAddr getBramCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncate(cacheAddr); // [valueOf(bramCacheIndexWidth) - 1 : 0];
    endfunction

    function Bit#(cascadeCacheIndexWidth) getCascadeCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncateLSB(cacheAddr); // [valueOf(addrWidth) - 1 : valueOf(bramCacheIndexWidth)];
    endfunction

    function Action readReqHelper(BramCacheAddr bramCacheIndex, BramCache bramCache);
        action
            bramCache.readReq(bramCacheIndex);
        endaction
    endfunction

    function ActionValue#(BramCacheData) readRespHelper(BramCache bramCache);
        actionvalue
            let bramCacheReadRespData <- bramCache.readResp;
            return bramCacheReadRespData;
        endactionvalue
    endfunction

    function Action writeHelper(
        BramCacheAddr bramCacheIndex, Tuple2#(BramCache, BramCacheData) tupleInput
    );
        action
            let { bramCache, writeData } = tupleInput;
            bramCache.write(bramCacheIndex, writeData);
        endaction
    endfunction

    function Bit#(payloadWidth) concatBitVec(BramCacheData bramCacheData, Bit#(payloadWidth) concatResult);
        return truncate({ concatResult, bramCacheData });
    endfunction
    // function Bit#(m) concatBitVec(Vector#(nSz, Bit#(n)) inputBitVec)
    // provisos(Add#(TMul#(n, nSz), 0, m));
    //     Bit#(m) result = dontCareValue;
    //     for (Integer idx = 0; idx < valueOf(n); idx = idx + 1) begin
    //         // result[(idx+1)*valueOf(n) : idx*valueOf(n)] = inputBitVec[idx];
    //         result = truncate({ result, inputBitVec[idx] });
    //     end
    //     return result;
    // endfunction

    Vector#(rowNum, Vector#(colNum, BramCache)) cascadeCacheVec <- replicateM(replicateM(mkBramCache));
    FIFOF#(Bit#(cascadeCacheIndexWidth)) cascadeCacheIndexQ <- mkFIFOF;

    method Action readReq(Bit#(addrWidth) cacheAddr);
        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        mapM_(readReqHelper(bramCacheIndex), cascadeCacheVec[cascadeCacheIndex]);
        cascadeCacheIndexQ.enq(cascadeCacheIndex);
    endmethod

    method ActionValue#(Bit#(payloadWidth)) readResp();
        let cascadeCacheIndex = cascadeCacheIndexQ.first;
        cascadeCacheIndexQ.deq;
        Vector#(colNum, BramCacheData) bramCacheReadRespVec <- mapM(
            readRespHelper, cascadeCacheVec[cascadeCacheIndex]
        );
        Bit#(payloadWidth) concatSeed = dontCareValue;
        Bit#(payloadWidth) concatResult = foldr(concatBitVec, concatSeed, bramCacheReadRespVec);
        return concatResult;
    endmethod

    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        Vector#(colNum, BramCacheData) writeDataVec = toChunks(writeData);
        Vector#(colNum, Tuple2#(BramCache, BramCacheData)) bramCacheAndWriteDataVec = zip(
            cascadeCacheVec[cascadeCacheIndex], writeDataVec
        );
        mapM_(writeHelper(bramCacheIndex), bramCacheAndWriteDataVec);
    endmethod
endmodule

interface TLB;
    method Action findReq(ADDR va);
    method ActionValue#(Tuple2#(Bool, ADDR)) findResp();
    method Action insert(ADDR va, ADDR pa);
endinterface

    function Bit#(PAGE_OFFSET_WIDTH) getPageOffset(ADDR addr);
        return truncate(addr);
    endfunction

    function ADDR restorePA(
        Bit#(TLB_CACHE_PA_DATA_WIDTH) paData, Bit#(PAGE_OFFSET_WIDTH) pageOffset
    );
        return signExtend({ paData, pageOffset });
    endfunction

    function Bit#(TLB_CACHE_PA_DATA_WIDTH) getData4PA(ADDR pa);
        return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
    endfunction

module mkTLB(TLB);
    CascadeCache#(TLB_CACHE_INDEX_WIDTH, TLB_PAYLOAD_WIDTH) cache4TLB <- mkCascadeCache;
    FIFOF#(ADDR) vaInputQ <- mkFIFOF;

    function Bit#(TLB_CACHE_INDEX_WIDTH) getIndex4TLB(ADDR va);
        return truncate(va >> valueOf(PAGE_OFFSET_WIDTH));
    endfunction

    function Bit#(TLB_CACHE_TAG_WIDTH) getTag4TLB(ADDR va);
        return truncate(va >> valueOf(TAdd#(TLB_CACHE_INDEX_WIDTH, PAGE_OFFSET_WIDTH)));
    endfunction

    method Action findReq(ADDR va);
        let index = getIndex4TLB(va);
        cache4TLB.readReq(index);
        vaInputQ.enq(va);
    endmethod

    method ActionValue#(Tuple2#(Bool, ADDR)) findResp();
        let va = vaInputQ.first;
        vaInputQ.deq;

        let inputTag = getTag4TLB(va);
        let pageOffset = getPageOffset(va);

        let readRespData <- cache4TLB.readResp;
        PayloadTLB payload = unpack(readRespData);

        let pa = restorePA(payload.data, pageOffset);
        let tagMatch = inputTag == payload.tag;
        return tuple2(tagMatch, pa);
    endmethod

    method Action insert(ADDR va, ADDR pa);
        let index = getIndex4TLB(va);
        let inputTag = getTag4TLB(va);
        let paData = getData4PA(pa);
        let payload = PayloadTLB {
            data: paData,
            tag : inputTag
        };
        cache4TLB.write(index, pack(payload));
    endmethod
endmodule
*/