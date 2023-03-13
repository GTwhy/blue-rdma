import ClientServer :: *;
import Controller :: *;
import DataTypes :: *;
import GetPut::*;
import Utils4Test::*;
import PrimUtils :: *;

// Connectal imports
import HostInterface::*;
import Clocks::*;
import Connectable::*;

interface CntrlIndication;
    method Action cntrl2Host(RespQP respQP);
endinterface

interface CntrlRequest;
    method Action host2Cntrl(S2hReq s2hReq);
    method Action host2CntrlQpInitAttr(QpInitAttr qpInitAttr);
    method Action host2CntrlQpAttr(QpAttr qpAttr);
    method Action softReset();
endinterface

interface ControllerWrapper;
    interface CntrlRequest cntrlRequest;
endinterface

module mkControllerWrapper#(CntrlIndication cntrlIndication)(ControllerWrapper);

    Reg#(Bool) ready <- mkReg(False);
    Reg#(Bool) isResetting <- mkReg(False);
    Reg#(Bit#(2)) resetCnt <- mkReg(0);
    Clock connectal_clk <- exposeCurrentClock;
    MakeResetIfc my_rst <- mkReset(1, True, connectal_clk); // inherits parent's reset (hidden) and introduce extra reset method (OR condition)

    // for multi-step software to hardware modification
    Reg#(Bool) inProgressFlag <- mkReg(False);
    Reg#(Maybe#(QpInitAttr)) qpInitAttrBuf <- mkReg(Invalid);
    Reg#(Maybe#(QpAttr)) qpAttrBuf <- mkReg(Invalid);


    rule clearResetting if (isResetting);
        resetCnt <= resetCnt + 1;
        if (resetCnt == 3) isResetting <= False;
        $display("hw softReset rule isReady: %d isResetting: %d resetCnt: %d", ready, isResetting, resetCnt);
    endrule

    let cntrl <- mkController(reset_by my_rst.new_rst);
    let qpSrv = cntrl.srvPort;

    rule cntrl2Host if ( !isResetting && ready );
        let resp <- qpSrv.response.get;
        cntrlIndication.cntrl2Host(resp);
        $display("hw cntrl2Host: ", fshow(resp));
    endrule


    interface CntrlRequest cntrlRequest;

        method Action host2CntrlQpInitAttr(QpInitAttr qpInitAttr) if ( !isResetting && ready );
            qpInitAttrBuf <= Valid(qpInitAttr);
            $display("hw host2CntrlQpInitAttr: ", fshow(qpInitAttr));
        endmethod


        method Action host2CntrlQpAttr(QpAttr qpAttr) if ( !isResetting && ready );
            qpAttrBuf <= Valid(qpAttr);
            $display("hw host2CntrlQpAttr: ", fshow(qpAttr));
        endmethod
        
        
        method Action host2Cntrl(S2hReq s2hReq) if ( !isResetting && ready );

            let req = ReqQP {
                qpReqType : s2hReq.qpReqType,
                pdHandler : s2hReq.pdHandler,
                qpn       : s2hReq.qpn,
                qpAttrMask: s2hReq.qpAttrMask,
                qpAttr    : ?,
                qpInitAttr: ?
            };
            
            // case (s2hReq.qpReqType)
            //     // need `QpInitAttr`
            //     REQ_QP_CREATE: begin
            //         case (qpInitAttrBuf) matches
            //             tagged Invalid: immFail(
            //                 "unreachible case @ mkControllerWrapper",
            //                 $format(
            //                     "qpInitAttrBuf=", fshow(qpInitAttrBuf)
            //                 )
            //             );

            //             tagged Valid .qpInitAttr: req.qpInitAttr = qpInitAttr;
            //         endcase
            //     end
            //     // need `QpAttr`
            //     REQ_QP_MODIFY: begin
            //         case (qpAttrBuf) matches
            //             tagged Invalid: immFail(
            //                 "unreachible case @ mkControllerWrapper",
            //                 $format(
            //                     "qpAttrBuf", fshow(qpAttrBuf)
            //                 )
            //             );

            //             tagged Valid .qpAttr: req.qpAttr = qpAttr;
            //         endcase
            //     end
            //     // // need no attr
                // (REQ_QP_DESTROY || REQ_QP_QUERY): begin
                //     // do nothing
                // end
                // default: begin
                //     immFail(
                //         "unreachible case @ mkControllerWrapper",
                //         $format(
                //             "request QPN=%h", req.qpn,
                //             "qpReqType=", fshow(req.qpReqType)
                //         )
                //     );
                // end
            // endcase

            // clear 
            qpAttrBuf <= Invalid;
            qpInitAttrBuf <= Invalid;

            // qpSrv.request.put(req);
            $display("hw host2Cntrl req: ", fshow(req));
        endmethod

        method Action softReset();
            my_rst.assertReset; // assert my_rst.new_rst signal
            isResetting <= True;
            ready<=True;
            $display("hw softReset action");
        endmethod

    endinterface
endmodule