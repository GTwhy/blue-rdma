import FIFOF :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import SpecialFIFOF :: *;
import Settings :: *;

function Bool compareDupReadAddrAndLen(PMTU pmtu, RETH dupReadReth, RETH origReadReth);
    Integer addrMSB        = valueOf(ADDR_WIDTH) - 1;
    Integer addrMidHighBit = valueOf(ADDR_WIDTH) - valueOf(RDMA_MAX_LEN_WIDTH);
    Integer addrMidLowBit  = valueOf(ADDR_WIDTH) - valueOf(RDMA_MAX_LEN_WIDTH) - 1;

    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrHighHalf = dupReadReth.va[addrMSB : addrMidHighBit];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrHighHalf = origReadReth.va[addrMSB : addrMidHighBit];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrLowHalf = dupReadReth.va[addrMidLowBit : 0];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrLowHalf = origReadReth.va[addrMidLowBit : 0];

    // 32-bit comparison
    let addrHighHalfMatch = dAddrHighHalf == oAddrHighHalf;

    let addrLowHalfAndLenMatch = case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 8];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 8];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) dupLenPart  = dupReadReth.dlen[addrMidLowBit : 8];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) origLenPart = origReadReth.dlen[addrMidLowBit : 8];

            (
                dAddrLowHalf[7 : 0]     == oAddrLowHalf[7 : 0]      &&
                dupReadReth.dlen[7 : 0] == origReadReth.dlen[7 : 0] &&
                origLenPart >= dupLenPart                           &&
                // 25-bit addition and comparison, for end address match
                ({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart }) == ({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart })
            );
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 9];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 9];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) dupLenPart  = dupReadReth.dlen[addrMidLowBit : 9];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) origLenPart = origReadReth.dlen[addrMidLowBit : 9];

            (
                dAddrLowHalf[8 : 0]     == oAddrLowHalf[8 : 0]      &&
                dupReadReth.dlen[8 : 0] == origReadReth.dlen[8 : 0] &&
                origLenPart >= dupLenPart                           &&
                // 24-bit addition and comparison, for end address match
                ({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart }) == ({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart })
            );
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 10];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 10];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) dupLenPart  = dupReadReth.dlen[addrMidLowBit : 10];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) origLenPart = origReadReth.dlen[addrMidLowBit : 10];

            (
                dAddrLowHalf[9 : 0]     == oAddrLowHalf[9 : 0]      &&
                dupReadReth.dlen[9 : 0] == origReadReth.dlen[9 : 0] &&
                origLenPart >= dupLenPart                           &&
                // 23-bit addition and comparison, for end address match
                ({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart }) == ({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart })
            );
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 11];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 11];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) dupLenPart  = dupReadReth.dlen[addrMidLowBit : 11];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) origLenPart = origReadReth.dlen[addrMidLowBit : 11];

            (
                dAddrLowHalf[10 : 0]     == oAddrLowHalf[10 : 0]      &&
                dupReadReth.dlen[10 : 0] == origReadReth.dlen[10 : 0] &&
                origLenPart >= dupLenPart                             &&
                // 22-bit addition and comparison, for end address match
                ({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart }) == ({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart })
            );
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 12];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 12];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) dupLenPart  = dupReadReth.dlen[addrMidLowBit : 12];
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) origLenPart = origReadReth.dlen[addrMidLowBit : 12];

            (
                dAddrLowHalf[11 : 0]     == oAddrLowHalf[11 : 0]      &&
                dupReadReth.dlen[11 : 0] == origReadReth.dlen[11 : 0] &&
                origLenPart >= dupLenPart                             &&
                // 21-bit addition and comparison, for end address match
                ({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart }) == ({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart })
            );
        end
    endcase;

    return addrHighHalfMatch && addrLowHalfAndLenMatch;
endfunction

function Bool compareDupReadAddr(PMTU pmtu, RETH dupReadReth, RETH origReadReth);
    Integer addrMSB        = valueOf(ADDR_WIDTH) - 1;
    Integer addrMidHighBit = valueOf(ADDR_WIDTH) - valueOf(RDMA_MAX_LEN_WIDTH);
    Integer addrMidLowBit  = valueOf(ADDR_WIDTH) - valueOf(RDMA_MAX_LEN_WIDTH) - 1;

    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrHighHalf = dupReadReth.va[addrMSB : addrMidHighBit];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrHighHalf = origReadReth.va[addrMSB : addrMidHighBit];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrLowHalf = dupReadReth.va[addrMidLowBit : 0];
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrLowHalf = origReadReth.va[addrMidLowBit : 0];

    let addrMatch = case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 8];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 8];

            // 24-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 9];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 9];

            // 23-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 10];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 10];

            // 22-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 11];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 11];

            // 21-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) dAddrLowPart = dAddrLowHalf[addrMidLowBit : 12];
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) oAddrLowPart = oAddrLowHalf[addrMidLowBit : 12];

            // 20-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
    endcase;

    return addrMatch;
endfunction

typedef enum {
    DUP_READ_REQ_START_FROM_FIRST,
    DUP_READ_REQ_START_FROM_MIDDLE
} DupReadReqStartState deriving(Bits, Eq, FShow);

typedef struct {
    RdmaOpCode   atomicOpCode;
    AtomicEth    atomicEth;
    AtomicAckEth atomicAckEth;
} AtomicCache deriving(Bits);

interface DupReadAtomicCache;
    method Action insertRead(RETH reth);
    method Action searchReadReq(RETH reth);
    method ActionValue#(Maybe#(DupReadReqStartState)) searchReadResp();

    method Action insertAtomic(AtomicCache atomicCache);
    method Action searchAtomicReq(RdmaOpCode atomicOpCode, AtomicEth atomicEth);
    method ActionValue#(Maybe#(AtomicCache)) searchAtomicResp();

    method Action clear();
endinterface

module mkDupReadAtomicCache#(Controller cntrl)(DupReadAtomicCache);
    CacheFIFO#(MAX_QP_RD_ATOM, RETH)          readCacheQ <- mkCacheFIFO;
    CacheFIFO#(MAX_QP_RD_ATOM, AtomicCache) atomicCacheQ <- mkCacheFIFO;
    FIFOF#(RETH) dupReadReqQ <- mkFIFOF;

    function Bool compareReadRethInCache(PMTU pmtu, RETH dupReadReth, RETH origReadReth);
        let keyMatch = dupReadReth.rkey == origReadReth.rkey;
        let addrLenMatch = compareDupReadAddrAndLen(pmtu, dupReadReth, origReadReth);
        return keyMatch && addrLenMatch;
    endfunction

    function Bool compareAtomicEthInCache(
        RdmaOpCode atomicOpCode, AtomicEth dupAtomicEth, AtomicCache atomicCache
    );
        let opCodeMatch = atomicOpCode == atomicCache.atomicOpCode;
        let keyMatch = dupAtomicEth.rkey == atomicCache.atomicEth.rkey;
        let addrMatch = dupAtomicEth.va == atomicCache.atomicEth.va;
        let swapMatch = dupAtomicEth.swap == atomicCache.atomicEth.swap;
        let payloadMatch = case (atomicOpCode)
            COMPARE_SWAP: (dupAtomicEth.comp == atomicCache.atomicEth.comp && swapMatch);
            FETCH_ADD   : swapMatch;
            default     : False;
        endcase;

        return opCodeMatch && keyMatch && addrMatch && payloadMatch;
    endfunction

    method Action insertRead(RETH reth);
        readCacheQ.cacheQIfc.push(reth);
    endmethod

    method Action searchReadReq(RETH reth);
        readCacheQ.searchIfc.searchReq(
            compareReadRethInCache(cntrl.getPMTU, reth)
        );
        dupReadReqQ.enq(reth);
    endmethod

    method ActionValue#(Maybe#(DupReadReqStartState)) searchReadResp();
        let dupReadReth = dupReadReqQ.first;
        dupReadReqQ.deq;

        let dupReadReqStartState = tagged Invalid;
        let searchResult <- readCacheQ.searchIfc.searchResp;
        if (searchResult matches tagged Valid .origReadReth) begin
            let dupReadAddrMatch = compareDupReadAddr(
                cntrl.getPMTU, dupReadReth, origReadReth
            );
            if (dupReadAddrMatch) begin
                dupReadReqStartState = tagged Valid DUP_READ_REQ_START_FROM_FIRST;
            end
            else begin
                dupReadReqStartState = tagged Valid DUP_READ_REQ_START_FROM_MIDDLE;
            end

            // $display(
            //     "time=%0d: dupReadReth.rkey=%h, origReadReth.rkey=%h",
            //     $time, dupReadReth.rkey, origReadReth.rkey,
            //     ", dupReadReth.va=%h, origReadReth.va=%h",
            //     dupReadReth.va, origReadReth.va,
            //     ", dupReadReth.dlen=%h, origReadReth.dlen=%h",
            //     dupReadReth.dlen, origReadReth.dlen,
            //     ", dupReadAddrMatch=", fshow(dupReadAddrMatch)
            // );
        end

        return dupReadReqStartState;
    endmethod

    method Action insertAtomic(AtomicCache atomicCache);
        atomicCacheQ.cacheQIfc.push(atomicCache);
    endmethod

    method Action searchAtomicReq(RdmaOpCode atomicOpCode, AtomicEth atomicEth);
        atomicCacheQ.searchIfc.searchReq(
            compareAtomicEthInCache(atomicOpCode, atomicEth)
        );
    endmethod

    method ActionValue#(Maybe#(AtomicCache)) searchAtomicResp();
        let searchResult <- atomicCacheQ.searchIfc.searchResp;
        return searchResult;
    endmethod

    method Action clear();
        readCacheQ.cacheQIfc.clear;
        atomicCacheQ.cacheQIfc.clear;
    endmethod
endmodule
