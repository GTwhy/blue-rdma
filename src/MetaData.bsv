import BRAM :: *;
import Cntrs :: *;
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

    function Bool readTagVec1(Array#(Reg#(Bool)) tagArray) = tagArray[1];
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
            let tagVec1 = map(readTagVec1, tagVec);
            if (insertReqReg[1] matches tagged Valid .insertVal) begin
                let maybeIndex = findElem(False, tagVec1);
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

// MR related

typedef TDiv#(MAX_MR, MAX_PD) MAX_MR_PER_PD;
typedef TLog#(MAX_MR_PER_PD) MR_INDEX_WIDTH;
typedef TSub#(KEY_WIDTH, MR_INDEX_WIDTH) MR_KEY_PART_WIDTH;

typedef UInt#(MR_INDEX_WIDTH) MrIndex;
typedef Bit#(MR_KEY_PART_WIDTH) MrKeyPart;

typedef struct {
    ADDR laddr;
    Length len;
    MemAccessTypeFlags accType;
    PdHandler pdHandler;
    MrKeyPart lkeyPart;
    Maybe#(MrKeyPart) rkeyPart;
} MemRegion deriving(Bits, FShow);

interface MetaDataMRs;
    method Action allocMR(
        ADDR               laddr,
        Length             len,
        MemAccessTypeFlags accType,
        PdHandler          pdHandler,
        MrKeyPart          lkeyPart,
        Maybe#(MrKeyPart)  rkeyPart
    );
    method ActionValue#(Tuple3#(MrIndex, LKEY, Maybe#(RKEY))) allocResp();
    method Action deAllocMR(MrIndex mrIndex);
    method ActionValue#(Bool) deAllocResp();
    method Maybe#(MemRegion) getMR(MrIndex mrIndex);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function Maybe#(MemRegion) getMemRegionByLKey(MetaDataMRs mrMetaData, LKEY lkey);
    MrIndex mrIndex = unpack(truncateLSB(lkey));
    return mrMetaData.getMR(mrIndex);
endfunction

function Maybe#(MemRegion) getMemRegionByRKey(MetaDataMRs mrMetaData, RKEY rkey);
    MrIndex mrIndex = unpack(truncateLSB(rkey));
    return mrMetaData.getMR(mrIndex);
endfunction

module mkMetaDataMRs(MetaDataMRs);
    TagVector#(MAX_MR_PER_PD, MemRegion) mrTagVec <- mkTagVector;
    FIFOF#(MemRegion) mrOutQ <- mkFIFOF;

    method Action allocMR(
        ADDR               laddr,
        Length             len,
        MemAccessTypeFlags accType,
        PdHandler          pdHandler,
        MrKeyPart          lkeyPart,
        Maybe#(MrKeyPart)  rkeyPart
    );
        let mr = MemRegion {
            laddr    : laddr,
            len      : len,
            accType  : accType,
            pdHandler: pdHandler,
            lkeyPart : lkeyPart,
            rkeyPart : rkeyPart
        };
        mrOutQ.enq(mr);
        mrTagVec.insertReq(mr);
    endmethod

    method ActionValue#(Tuple3#(MrIndex, LKEY, Maybe#(RKEY))) allocResp();
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
        return tuple3(mrIndex, lkey, rkey);
    endmethod

    method Action deAllocMR(MrIndex mrIndex) = mrTagVec.removeReq(mrIndex);
    method ActionValue#(Bool) deAllocResp() = mrTagVec.removeResp;
    method Maybe#(MemRegion) getMR(MrIndex mrIndex) = mrTagVec.getItem(mrIndex);

    method Action clear();
        mrTagVec.clear;
        mrOutQ.clear;
    endmethod

    method Bool notEmpty() = mrTagVec.notEmpty;
    method Bool notFull() = mrTagVec.notFull;
endmodule

// PD related

typedef TLog#(MAX_PD) PD_INDEX_WIDTH;
typedef TSub#(PD_HANDLE_WIDTH, PD_INDEX_WIDTH) PD_KEY_WIDTH;

typedef Bit#(PD_KEY_WIDTH)    PdKey;
typedef UInt#(PD_INDEX_WIDTH) PdIndex;

interface MetaDataPDs;
    method Action allocPD(PdKey pdKey);
    method ActionValue#(PdHandler) allocResp();
    method Action deAllocPD(PdHandler pdHandler);
    method ActionValue#(Bool) deAllocResp();
    method Bool isValidPD(PdHandler pdHandler);
    method Maybe#(MetaDataMRs) getMRs4PD(PdHandler pdHandler);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataPDs(MetaDataPDs);
    TagVector#(MAX_PD, PdKey) pdTagVec <- mkTagVector;
    Vector#(MAX_PD, MetaDataMRs) pdMrVec <- replicateM(mkMetaDataMRs);
    FIFOF#(PdKey) pdKeyOutQ <- mkFIFOF;

    function PdIndex getPdIndex(PdHandler pdHandler) = unpack(truncateLSB(pdHandler));
    function Action clearAllMRs(MetaDataMRs mrMetaData);
        action
            mrMetaData.clear;
        endaction
    endfunction

    method Action allocPD(PdKey pdKey);
        pdTagVec.insertReq(pdKey);
        pdKeyOutQ.enq(pdKey);
    endmethod
    method ActionValue#(PdHandler) allocResp();
        let pdIndex <- pdTagVec.insertResp;
        let pdKey = pdKeyOutQ.first;
        pdKeyOutQ.deq;
        PdHandler pdHandler = { pack(pdIndex), pdKey };
        return pdHandler;
    endmethod

    method Action deAllocPD(PdHandler pdHandler);
        let pdIndex = getPdIndex(pdHandler);
        pdTagVec.removeReq(pdIndex);
    endmethod
    method ActionValue#(Bool) deAllocResp() = pdTagVec.removeResp;

    method Bool isValidPD(PdHandler pdHandler);
        let pdIndex = getPdIndex(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex));
    endmethod

    method Maybe#(MetaDataMRs) getMRs4PD(PdHandler pdHandler);
        let pdIndex = getPdIndex(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex)) ?
            (tagged Valid pdMrVec[pdIndex]) : (tagged Invalid);
    endmethod

    method Action clear();
        pdTagVec.clear;
        pdKeyOutQ.clear;
        mapM_(clearAllMRs, pdMrVec);
    endmethod

    method Bool notEmpty() = pdTagVec.notEmpty;
    method Bool notFull()  = pdTagVec.notFull;
endmodule

// QP related

typedef TLog#(MAX_QP) QP_INDEX_WIDTH;
typedef UInt#(QP_INDEX_WIDTH) QpIndex;

interface MetaDataQPs;
    method Action createQP(QKEY qkey);
    method ActionValue#(QPN) createResp();
    method Action destroyQP(QPN qpn);
    method ActionValue#(Bool) destroyResp();
    method Bool isValidQP(QPN qpn);
    method Maybe#(PdHandler) getPD(QPN qpn);
    method Controller getCntrl(QPN qpn);
    // method Maybe#(Controller) getCntrl2(QPN qpn);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataQPs(MetaDataQPs);
    TagVector#(MAX_QP, PdHandler) qpTagVec <- mkTagVector;
    Vector#(MAX_QP, Controller) qpCntrlVec <- replicateM(mkController);
    FIFOF#(PdHandler) pdHandlerOutQ <- mkFIFOF;

    function QpIndex getQpIndex(QPN qpn) = unpack(truncateLSB(qpn));

    method Action createQP(PdHandler pdHandler);
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
        let qpIndex = getQpIndex(qpn);
        qpTagVec.removeReq(qpIndex);
    endmethod
    method ActionValue#(Bool) destroyResp() = qpTagVec.removeResp;

    method Bool isValidQP(QPN qpn);
        let qpIndex = getQpIndex(qpn);
        return isValid(qpTagVec.getItem(qpIndex));
    endmethod

    method Maybe#(PdHandler) getPD(QPN qpn);
        let qpIndex = getQpIndex(qpn);
        return qpTagVec.getItem(qpIndex);
    endmethod

    method Controller getCntrl(QPN qpn);
        let qpIndex = getQpIndex(qpn);
        let qpCntrl = qpCntrlVec[qpIndex];
        return qpCntrl;
    endmethod
    // method Maybe#(Controller) getCntrl2(QPN qpn);
    //     let qpIndex = getQpIndex(qpn);
    //     let qpCntrl = qpCntrlVec[qpIndex];
    //     let pdHandler = qpTagVec.getItem(qpIndex);
    //     return isValid(pdHandler) ? tagged Valid qpCntrl : tagged Invalid;
    // endmethod

    method Action clear();
        qpTagVec.clear;
        pdHandlerOutQ.clear;
    endmethod

    method Bool notEmpty() = qpTagVec.notEmpty;
    method Bool notFull()  = qpTagVec.notFull;
endmodule

// MR check related

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
        MetaDataPDs pdMetaData, PdHandler pdHandler, LKEY lkey
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
        MetaDataPDs pdMetaData, PdHandler pdHandler, RKEY rkey
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

typedef TExp#(11)  BRAM_CACHE_SIZE; // 2K
typedef BYTE_WIDTH BRAM_CACHE_DATA_WIDTH;

typedef Bit#(TLog#(BRAM_CACHE_SIZE)) BramCacheAddr;
typedef Bit#(BRAM_CACHE_DATA_WIDTH)  BramCacheData;

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
