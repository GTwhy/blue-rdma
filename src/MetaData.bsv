import Arbitration :: *;
import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: * ;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;

/*
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
                    tagVec[insertIdx]  <= True;
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
    // IndexCB cbIndex;
} ReqMR deriving(Bits, FShow);

typedef struct {
    Bool successOrNot;
    MemRegion mr;
    LKEY lkey;
    RKEY rkey;
    // IndexCB cbIndex;
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

module mkMetaDataMRs(MetaDataMRs) provisos(
    Add#(TMul#(MAX_MR_PER_PD, MAX_PD), 0, MAX_MR) // MAX_MR == MAX_MR_PER_PD * MAX_PD
);
    TagVecSrv#(MAX_MR_PER_PD, MemRegion) mrTagVec <- mkTagVecSrv;
    // FIFOF#(IndexCB) cbIndexQ <- mkFIFOF;

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
                let mrIndex = mrReq.lkeyOrNot ?
                    lkey2IndexMR(mrReq.lkey) : rkey2IndexMR(mrReq.rkey);
                mrTagVec.srvPort.request.put(tuple3(
                    mrReq.allocOrNot, mrReq.mr, mrIndex
                ));
                // cbIndexQ.enq(mrReq.cbIndex);
            endmethod
        endinterface;

        interface response = interface Get#(RespMR);
            method ActionValue#(RespMR) get();
                let { successOrNot, mrIndex, mr } <- mrTagVec.srvPort.response.get;
                // let cbIndex = cbIndexQ.first;
                // cbIndexQ.deq;

                let { lkey, rkey } = genLocalAndRmtKey(mrIndex, mr);
                let mrResp = RespMR {
                    successOrNot: successOrNot,
                    mr          : mr,
                    lkey        : lkey,
                    rkey        : rkey
                    // cbIndex     : cbIndex
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

function IndexPD getIndexPD(HandlerPD pdHandler) = unpack(truncateLSB(pdHandler));

module mkMetaDataPDs(MetaDataPDs);
    TagVecSrv#(MAX_PD, KeyPD) pdTagVec <- mkTagVecSrv;
    Vector#(MAX_PD, MetaDataMRs) pdMrVec <- replicateM(mkMetaDataMRs);

    function Action clearAllMRs(MetaDataMRs mrMetaData);
        action
            mrMetaData.clear;
        endaction
    endfunction

    interface srvPort = interface SrvPortPD;
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

function QPN genQPN(IndexQP qpIndex, HandlerPD pdHandler);
    return { pack(qpIndex), truncate(pdHandler) };
endfunction

module mkMetaDataQPs(MetaDataQPs);
    TagVecSrv#(MAX_QP, HandlerPD) qpTagVec <- mkTagVecSrv;
    Vector#(MAX_QP, Controller) qpCntrlVec <- replicateM(mkController);
    FIFOF#(Tuple2#(Bool, ReqQP)) qpReqQ4Resp <- mkFIFOF;
    FIFOF#(ReqQP) qpReqQ4Cntrl <- mkFIFOF;

    rule handleReqQP;
        let qpReq = qpReqQ4Cntrl.first;
        qpReqQ4Cntrl.deq;

        let tagVecRespSuccess = True;
        case (qpReq.qpReqType)
            REQ_QP_CREATE,
            REQ_QP_DESTROY: begin
                let { successOrNot, qpIndex, pdHandler } <- qpTagVec.srvPort.response.get;
                tagVecRespSuccess = successOrNot;
                let cntrl = qpCntrlVec[qpIndex];

                if (tagVecRespSuccess) begin
                    let qpn = genQPN(qpIndex, pdHandler);
                    qpReq.qpn = qpn;
                    qpReq.pdHandler = pdHandler;
                    cntrl.srvPort.request.put(qpReq);
                end
            end
            REQ_QP_MODIFY,
            REQ_QP_QUERY : begin
                let qpIndex = getIndexQP(qpReq.qpn);
                let cntrl = qpCntrlVec[qpIndex];

                cntrl.srvPort.request.put(qpReq);
            end
            default: begin
                immFail(
                    "unreachible case @ mkMetaDataQPs",
                    $format("qpReq.qpReqType=", fshow(qpReq.qpReqType))
                );
            end
        endcase
        qpReqQ4Resp.enq(tuple2(tagVecRespSuccess, qpReq));
    endrule

    interface srvPort = interface SrvPortQP;
        interface request = interface Put#(ReqQP);
            method Action put(ReqQP qpReq);
                case (qpReq.qpReqType)
                    REQ_QP_CREATE ,
                    REQ_QP_DESTROY: begin
                        let qpCreateOrNot = qpReq.qpReqType == REQ_QP_CREATE;
                        let qpIndex = getIndexQP(qpReq.qpn);
                        qpTagVec.srvPort.request.put(tuple3(
                            qpCreateOrNot, qpReq.pdHandler, qpIndex
                        ));
                    end
                    REQ_QP_MODIFY,
                    REQ_QP_QUERY : begin end
                    default: begin
                        immFail(
                            "unreachible case @ mkMetaDataQPs",
                            $format("qpReq.qpReqType=", fshow(qpReq.qpReqType))
                        );
                    end
                endcase

                qpReqQ4Cntrl.enq(qpReq);
            endmethod
        endinterface;

        interface response = interface Get#(RespQP);
            method ActionValue#(RespQP) get();
                let { tagVecRespSuccess, qpReq } = qpReqQ4Resp.first;
                qpReqQ4Resp.deq;

                // immAssert(
                //     tagVecRespSuccess,
                //     "tagVecRespSuccess assertion @ mkMetaDataQPs",
                //     $format(
                //         "tagVecRespSuccess=", fshow(tagVecRespSuccess),
                //         " should be valid when qpReq.qpReqType=", fshow(qpReq.qpReqType),
                //         " and qpReq.qpn=%h", qpReq.qpn
                //     )
                // );

                let qpIndex = getIndexQP(qpReq.qpn);
                let cntrl = qpCntrlVec[qpIndex];
                let qpResp = RespQP {
                    successOrNot: False,
                    qpn         : qpReq.qpn,
                    pdHandler   : qpReq.pdHandler,
                    qpAttr      : qpReq.qpAttr,
                    qpInitAttr  : qpReq.qpInitAttr
                };

                case (qpReq.qpReqType)
                    REQ_QP_CREATE ,
                    REQ_QP_MODIFY ,
                    REQ_QP_QUERY  ,
                    REQ_QP_DESTROY: begin
                        if (tagVecRespSuccess) begin
                            qpResp <- cntrl.srvPort.response.get;
                        end
                    end
                    default: begin
                        immFail(
                            "unreachible case @ mkMetaDataQPs",
                            $format(
                                "request QPN=%h", qpReq.qpn, "qpReqType=", fshow(qpReq.qpReqType)
                            )
                        );
                    end
                endcase

                // $display(
                //     "time=%0t:", $time,
                //     " tagVecRespSuccess=", fshow(tagVecRespSuccess),
                //     " qpResp.successOrNot=", fshow(qpResp.successOrNot),
                //     " qpReq.qpn=%h, qpIndex=%h, qpReq.pdHandler=%h",
                //     qpReq.qpn, qpIndex, qpReq.pdHandler
                // );
                return qpResp;
            endmethod
        endinterface;
    endinterface;

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

module mkPermCheckAribter#(PermCheckMR permCheckMR)(PermCheckArbiter#(portSz)) provisos(
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

// TODO: remove this module
module mkQpAttrPipeOut(PipeOut#(QpAttr));
    FIFOF#(QpAttr) qpAttrQ <- mkFIFOF;
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) dqpnCnt <- mkCount(0);

    rule genQpAttr if (dqpnCnt < fromInteger(valueOf(MAX_QP)));
        QPN dqpn = zeroExtendLSB(dqpnCnt);
        dqpnCnt.incr(1);

        let qpAttr = QpAttr {
            qpState          : dontCareValue,
            curQpState       : dontCareValue,
            pmtu             : IBV_MTU_1024,
            qkey             : fromInteger(valueOf(DEFAULT_QKEY)),
            rqPSN            : 0,
            sqPSN            : 0,
            dqpn             : dqpn,
            qpAcessFlags     : IBV_ACCESS_REMOTE_WRITE,
            cap              : QpCapacity {
                maxSendWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxRecvWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxSendSGE   : fromInteger(valueOf(MAX_SEND_SGE)),
                maxRecvSGE   : fromInteger(valueOf(MAX_RECV_SGE)),
                maxInlineData: fromInteger(valueOf(MAX_INLINE_DATA))
            },
            pkeyIndex        : fromInteger(valueOf(DEFAULT_PKEY)),
            sqDraining       : False,
            maxReadAtomic    : fromInteger(valueOf(MAX_QP_RD_ATOM)),
            maxDestReadAtomic: fromInteger(valueOf(MAX_QP_RD_ATOM)),
            minRnrTimer      : 1, // minRnrTimer 1 - 0.01 milliseconds delay
            timeout          : 1, // maxTimeOut 0 - infinite, 1 - 8.192 usec (0.000008 sec)
            retryCnt         : 3,
            rnrRetry         : 3
        };

        qpAttrQ.enq(qpAttr);
    endrule

    return convertFifo2PipeOut(qpAttrQ);
endmodule

// TODO: move to Utils4Test, and change QP state as Reset -> Init -> RTR -> RTS
module mkInitMetaData#(
    MetaDataSrv metaDataSrv, QpInitAttr qpInitAttr, PipeOut#(QpAttr) qpAttrPipeIn
)(Empty);
    let pdNum = valueOf(MAX_PD);
    let qpNum = valueOf(MAX_QP);
    let qpPerPD = valueOf(TDiv#(MAX_QP, MAX_PD));

    FIFOF#(HandlerPD) pdHandlerQ4Fill <- mkSizedFIFOF(pdNum);
    FIFOF#(QPN)             qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)           qpnQ4Modify <- mkSizedFIFOF(qpNum);

    Count#(Bit#(TLog#(MAX_PD)))                  pdKeyCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))        pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))                 pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))        qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))                 qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    Count#(Bit#(TLog#(TDiv#(MAX_QP, MAX_PD)))) qpPerPdCnt <- mkCount(fromInteger(qpPerPD - 1));

    Reg#(Bool)   pdInitDoneReg <- mkReg(False);
    Reg#(Bool) qpCreateDoneReg <- mkReg(False);
    Reg#(Bool)   qpInitDoneReg <- mkReg(False);
    Reg#(Bool) qpModifyDoneReg <- mkReg(False);

    Vector#(MAX_QP, Reg#(Bool)) qpModifyDoneRegVec <- replicateM(mkReg(False));

    rule reqAllocPDs if (!isZero(pdReqCnt) && !pdInitDoneReg);
        pdReqCnt.decr(1);

        KeyPD pdKey = zeroExtend(pdKeyCnt);
        pdKeyCnt.incr(1);

        let allocReqPD = ReqPD {
            allocOrNot: True,
            pdKey     : pdKey,
            pdHandler : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4PD allocReqPD);
    endrule

    rule respAllocPDs if (!pdInitDoneReg);
        if (isZero(pdRespCnt)) begin
            pdInitDoneReg <= True;
        end
        else begin
            pdRespCnt.decr(1);
        end

        let maybeAllocRespPD <- metaDataSrv.response.get;
        if (maybeAllocRespPD matches tagged Resp4PD .allocRespPD) begin
            immAssert(
                allocRespPD.successOrNot,
                "allocRespPD.successOrNot assertion @ mkInitMetaData",
                $format(
                    "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            pdHandlerQ4Fill.enq(allocRespPD.pdHandler);
        end
        else begin
            immFail(
                "maybeAllocRespPD assertion @ mkInitMetaData",
                $format(
                    "maybeAllocRespPD=", fshow(maybeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule

    rule reqCreateQPs if (!isZero(qpReqCnt) && pdInitDoneReg && !qpCreateDoneReg);
        qpReqCnt.decr(1);

        if (isZero(qpPerPdCnt)) begin
            qpPerPdCnt <= fromInteger(qpPerPD - 1);
            pdHandlerQ4Fill.deq;
        end
        else begin
            qpPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4Fill.first;

        let createReqQP = ReqQP {
            qpReqType   : REQ_QP_CREATE,
            pdHandler   : pdHandler,
            qpn         : dontCareValue,
            qpAttrMask  : dontCareValue,
            qpAttr      : dontCareValue,
            qpInitAttr  : qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
    endrule

    rule respCreateQPs if (pdInitDoneReg && !qpCreateDoneReg);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            qpCreateDoneReg <= True;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeCreateRespQP <- metaDataSrv.response.get;
        if (maybeCreateRespQP matches tagged Resp4QP .createRespQP) begin
            immAssert(
                createRespQP.successOrNot,
                "createRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "createRespQP.successOrNot=", fshow(createRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = createRespQP.qpn;
            qpnQ4Init.enq(qpn);
            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeCreateRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeCreateRespQP=", fshow(maybeCreateRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqInitQPs if (
        !isZero(qpReqCnt) &&
        pdInitDoneReg     &&
        qpCreateDoneReg   &&
        !qpInitDoneReg
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Init.first;
        qpnQ4Init.deq;

        let qpAttr = qpAttrPipeIn.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let initReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP initReqQP);
    endrule

    rule respInitQPs if (pdInitDoneReg && qpCreateDoneReg && !qpInitDoneReg);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            qpInitDoneReg <= True;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeInitRespQP <- metaDataSrv.response.get;
        if (maybeInitRespQP matches tagged Resp4QP .initRespQP) begin
            immAssert(
                initRespQP.successOrNot,
                "initRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "initRespQP.successOrNot=", fshow(initRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = initRespQP.qpn;
            qpnQ4Modify.enq(qpn);
            // $display(
            //     "time=%0t: initRespQP=", $time, fshow(initRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     $time, qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeInitRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeInitRespQP=", fshow(maybeInitRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqModifyQPs if (
        !isZero(qpReqCnt) &&
        pdInitDoneReg     &&
        qpCreateDoneReg   &&
        qpInitDoneReg     &&
        !qpModifyDoneReg
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Modify.first;
        qpnQ4Modify.deq;

        let qpAttr = qpAttrPipeIn.first;
        qpAttrPipeIn.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let modifyReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP modifyReqQP);
    endrule

    rule respModifyQPs if (
        pdInitDoneReg   &&
        qpCreateDoneReg &&
        qpInitDoneReg   &&
        !qpModifyDoneReg
    );
        if (isZero(qpRespCnt)) begin
            qpModifyDoneReg <= True;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .modifyRespQP) begin
            immAssert(
                modifyRespQP.successOrNot,
                "modifyRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "modifyRespQP.successOrNot=", fshow(modifyRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", modifyRespQP=", fshow(modifyRespQP)
                )
            );
            // $display(
            //     "time=%0t: modifyRespQP=", $time, fshow(modifyRespQP),
            //     " should be success, and modifyRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, modifyRespQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule
endmodule

// MetaDataSrv related

typedef union tagged {
    ReqPD Req4PD;
    ReqMR Req4MR;
    ReqQP Req4QP;
} MetaDataReq deriving(Bits, FShow);

typedef union tagged {
    RespPD Resp4PD;
    RespMR Resp4MR;
    RespQP Resp4QP;
} MetaDataResp deriving(Bits, FShow);

typedef Server#(MetaDataReq, MetaDataResp) MetaDataSrv;

// TODO: check PD can be deallocated before removing all associated QPs
module mkMetaDataSrv#(
    MetaDataPDs pdMetaData, MetaDataQPs qpMetaData
)(MetaDataSrv) provisos(
    Add#(MAX_PD, anysizeJ, MAX_QP), // MAX_QP >= MAX_PD
    NumAlias#(TDiv#(MAX_QP, MAX_PD), qpPerPD),
    Add#(1, anysizeK, qpPerPD), // qpPerPD > 1
    Add#(TMul#(MAX_PD, qpPerPD), 0, MAX_QP) // MAX_QP == MAX_PD * qpPerPD
);
    FIFOF#(MetaDataReq)   metaDataReqQ <- mkFIFOF;
    FIFOF#(MetaDataResp) metaDataRespQ <- mkFIFOF;

    Reg#(Bool) busyReg <- mkReg(False);

    rule issueMetaDataReq if (!busyReg);
        let metaDataReq = metaDataReqQ.first;

        case (metaDataReq) matches
            tagged Req4MR .mrReq: begin
                let pdIndex = getIndexPD(mrReq.mr.pdHandler);
                let maybeMRs = pdMetaData.getMRs4PD(mrReq.mr.pdHandler);
                if (maybeMRs matches tagged Valid .mrMetaData) begin
                    mrMetaData.srvPort.request.put(mrReq);
                end
            end
            tagged Req4PD .pdReq: begin
                pdMetaData.srvPort.request.put(pdReq);
            end
            tagged Req4QP .qpReq: begin
                let isValidPD = pdMetaData.isValidPD(qpReq.pdHandler);
                if (isValidPD) begin
                    qpMetaData.srvPort.request.put(qpReq);
                end
            end
        endcase

        busyReg <= True;
    endrule

    rule recvMetaDataResp if (busyReg);
        let metaDataReq = metaDataReqQ.first;
        metaDataReqQ.deq;

        case (metaDataReq) matches
            tagged Req4MR .mrReq: begin
                let mrResp = RespMR {
                    successOrNot: False,
                    mr          : mrReq.mr,
                    lkey        : mrReq.lkey,
                    rkey        : mrReq.rkey
                };

                let pdIndex = getIndexPD(mrReq.mr.pdHandler);
                let maybeMRs = pdMetaData.getMRs4PD(mrReq.mr.pdHandler);
                if (maybeMRs matches tagged Valid .mrMetaData) begin
                    mrResp <- mrMetaData.srvPort.response.get;
                end

                metaDataRespQ.enq(tagged Resp4MR mrResp);
            end
            tagged Req4PD .pdReq: begin
                let pdResp <- pdMetaData.srvPort.response.get;
                metaDataRespQ.enq(tagged Resp4PD pdResp);
            end
            tagged Req4QP .qpReq: begin
                let qpResp = RespQP {
                    successOrNot: False,
                    qpn         : qpReq.qpn,
                    pdHandler   : qpReq.pdHandler,
                    qpAttr      : qpReq.qpAttr,
                    qpInitAttr  : qpReq.qpInitAttr
                };

                let isValidPD = pdMetaData.isValidPD(qpReq.pdHandler);
                if (isValidPD) begin
                    qpResp <- qpMetaData.srvPort.response.get;
                end
                metaDataRespQ.enq(tagged Resp4QP qpResp);
            end
        endcase

        busyReg <= False;
    endrule

    return toGPServer(metaDataReqQ, metaDataRespQ);
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

module mkCascadeCache(CascadeCache#(addrWidth, payloadWidth)) provisos(
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

module mkCascadeCache(CascadeCache#(addrWidth, payloadWidth)) provisos(
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