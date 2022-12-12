import Cntrs :: * ;
import FIFOF :: *;
import Vector :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;

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

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            itemCnt   <= 0;
            emptyReg  <= True;
            fullReg   <= False;
            for (Integer idx = 0; idx < valueOf(vSz); idx = idx + 1) begin
                tagVec[idx][1] <= False;
            end
        end
        else begin
            let inserted = False;
            let tagVec1 = map(readTagVec1, tagVec);
            if (insertReqReg[1] matches tagged Valid .insertVal) begin
                let maybeIndex = findElem(False, tagVec1);
                if (maybeIndex matches tagged Valid .index) begin
                    tagVec[index][1] <= True;
                    dataVec[index] <= insertVal;
                    // insertReqQ.deq;
                    insertRespQ.enq(index);
                    inserted = True;
                end
            end

            let removed = False;
            if (removeReqReg[1] matches tagged Valid .index) begin
                // removeReqQ.deq;
                removed = True;
            end

            insertReqReg[1] <= tagged Invalid;
            removeReqReg[1] <= tagged Invalid;

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
        end
    endrule

    method Maybe#(anytype) getItem(UInt#(vLogSz) index);
        return (tagVec[index][0]) ? (tagged Valid dataVec[index]) : (tagged Invalid);
    endmethod

    method Action insertReq(anytype inputVal) if (!fullReg);
        insertReqReg[0] <= tagged Valid inputVal;
    endmethod
    method ActionValue#(UInt#(TLog#(vSz))) insertResp();
        insertRespQ.deq;
        return insertRespQ.first;
    endmethod

    method Action removeReq(UInt#(TLog#(vSz)) index) if (!emptyReg);
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
} MR deriving(Bits, FShow);

interface MRs;
    method Action allocMR(
        ADDR               laddr,
        Length             len,
        MemAccessTypeFlags accType,
        PdHandler          pdHandler,
        MrKeyPart          lkeyPart,
        Maybe#(MrKeyPart)  rkeyPart
    );
    method ActionValue#(Tuple3#(MrIndex, LKEY, Maybe#(RKEY))) allocResp();
    method Maybe#(MR) getMR(MrIndex mrIndex);
    method Action deAllocMR(MrIndex mrIndex);
    method ActionValue#(Bool) deAllocResp();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMRs(MRs);
    TagVector#(MAX_MR_PER_PD, MR) mrTagVec <- mkTagVector;
    FIFOF#(MR) mrOutQ <- mkFIFOF;

    method Action allocMR(
        ADDR               laddr,
        Length             len,
        MemAccessTypeFlags accType,
        PdHandler          pdHandler,
        MrKeyPart          lkeyPart,
        Maybe#(MrKeyPart)  rkeyPart
    );
        let mr = MR {
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
            tagged Valid .keyPart: begin
                RKEY rk = { pack(mrIndex), keyPart };
                tagged Valid rk;
            end
            default: tagged Invalid;
        endcase;
        return tuple3(mrIndex, lkey, rkey);
    endmethod

    method Maybe#(MR) getMR(MrIndex mrIndex) = mrTagVec.getItem(mrIndex);
    method Action deAllocMR(MrIndex mrIndex) = mrTagVec.removeReq(mrIndex);
    method ActionValue#(Bool) deAllocResp() = mrTagVec.removeResp;

    method Bool notEmpty() = mrTagVec.notEmpty;
    method Bool notFull() = mrTagVec.notFull;
endmodule

// PD related

typedef 32 PD_HANDLE_WIDTH;
typedef TLog#(MAX_PD) PD_INDEX_WIDTH;
typedef TSub#(PD_HANDLE_WIDTH, PD_INDEX_WIDTH) PD_KEY_WIDTH;

typedef Bit#(PD_HANDLE_WIDTH) PdHandler;
typedef Bit#(PD_KEY_WIDTH)    PdKey;
typedef UInt#(PD_INDEX_WIDTH) PdIndex;

interface PDs;
    method Action allocPD(PdKey pdKey);
    method ActionValue#(PdHandler) allocResp();
    method Action deAllocPD(PdHandler pdHandler);
    method ActionValue#(Bool) deAllocResp();
    method Bool isValidPD(PdHandler pdHandler);
    method Maybe#(MRs) getMRs(PdHandler pdHandler);
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkPDs(PDs);
    TagVector#(MAX_PD, PdKey) pdTagVec <- mkTagVector;
    Vector#(MAX_PD, MRs) pdMrVec <- replicateM(mkMRs);
    FIFOF#(PdKey) pdKeyOutQ <- mkFIFOF;

    function PdIndex getPdIndex(PdHandler pdHandler) = unpack(truncateLSB(pdHandler));

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

    method Maybe#(MRs) getMRs(PdHandler pdHandler);
        let pdIndex = getPdIndex(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex)) ?
            (tagged Valid pdMrVec[pdIndex]) : (tagged Invalid);
    endmethod

    method Bool notEmpty() = pdTagVec.notEmpty;
    method Bool notFull()  = pdTagVec.notFull;
endmodule

// QP related

typedef TLog#(MAX_QP) QP_INDEX_WIDTH;
typedef UInt#(QP_INDEX_WIDTH) QpIndex;

interface QPs;
    method Action createQP(QKEY qkey);
    method ActionValue#(QPN) createResp();
    method Action destroyQP(QPN qpn);
    method ActionValue#(Bool) destroyResp();
    method Bool isValidQP(QPN qpn);
    method Maybe#(PdHandler) getPD(QPN qpn);
    method Controller getCntrl(QPN qpn);
    // method Maybe#(Controller) getCntrl2(QPN qpn);
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkQPs(QPs);
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

    method Bool notEmpty() = qpTagVec.notEmpty;
    method Bool notFull()  = qpTagVec.notFull;
endmodule
