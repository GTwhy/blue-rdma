
function Bool isZero(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    // TODO: consider using fold
    Bool ret = unpack(|bits);
    return !ret;
endfunction

function Bool isLessOrEqOne(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    Bool ret = isZero(bits >> 1);
    // Bool ret = isZero(bits >> 1) && unpack(bits[0]);
    return ret;
endfunction

function Bool isOne(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    return isLessOrEqOne(bits) && unpack(bits[0]);
endfunction

function Bool isAllOnes(Bit#(nSz) bits);
    Bool ret = unpack(&bits);
    return ret;
endfunction

function Bool isLargerThanOne(Bit#(tSz) bits) provisos(Add#(1, kSz, tSz));
    return !isZero(bits >> 1);
endfunction

function Bit#(nSz) zeroExtendLSB(Bit#(mSz) bits) provisos(Add#(mSz, kSz, nSz));
    return { bits, 0 };
endfunction

function Bit#(1) getMSB(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    return (reverseBits(bits))[0];
endfunction

function Bit#(TSub#(nSz, 1)) removeMSB(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    return truncateLSB(bits << 1);
endfunction

function anytype dontCareValue() provisos(Bits#(anytype, nSz));
    return ?;
endfunction

function anytype unwrapMaybe(Maybe#(anytype) maybe) provisos(Bits#(anytype, nSz));
    return fromMaybe(?, maybe);
endfunction

function anytype unwrapMaybeWithDefault(
    Maybe#(anytype) maybe, anytype defaultVal
) provisos(Bits#(anytype, nSz));
    return fromMaybe(defaultVal, maybe);
endfunction
