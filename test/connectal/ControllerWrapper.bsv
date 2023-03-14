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

typedef SizeOf#(QpAttrMask)         QpAttrMask_WIDTH;
typedef SizeOf#(MemAccessTypeFlags)        MemAccessTypeFlags_WIDTH;

interface CntrlIndication;
    method Action cntrl2Host(RespQP respQP);
endinterface

interface CntrlRequest;
    method Action host2Cntrl(S2hReq s2hReq);
    method Action host2CntrlQpInitAttr(QpInitAttr qpInitAttr);
    method Action host2CntrlQpAttr(QpAttr qpAttr);
    method Action host2CntrlReq(S2hReq s2hReq);
    method Action softReset();
endinterface

interface ControllerWrapper;
    interface CntrlRequest cntrlRequest;
endinterface

module mkControllerWrapper#(CntrlIndication cntrlIndication)(ControllerWrapper);

    // for multi-step software to hardware modification
    Reg#(Bool) inProgressFlag <- mkReg(False);
    Reg#(Maybe#(QpInitAttr)) qpInitAttrBuf <- mkReg(Invalid);
    Reg#(Maybe#(QpAttr)) qpAttrBuf <- mkReg(Invalid);
    Reg#(Maybe#(S2hReq)) s2hReqBuf <- mkReg(Invalid);

    let cntrl <- mkController;
    let qpSrv = cntrl.srvPort;

    rule cntrl2Host;
        let resp <- qpSrv.response.get;
        cntrlIndication.cntrl2Host(resp);
        $display("hw cntrl2Host: ", fshow(resp));
    endrule


    interface CntrlRequest cntrlRequest;

        method Action host2CntrlQpInitAttr(QpInitAttr qpInitAttr);
            qpInitAttrBuf <= Valid(qpInitAttr);
            $display("hw host2CntrlQpInitAttr: ", fshow(qpInitAttr));
            $display("hw tttttttt %d", valueOf(QpAttrMask_WIDTH));
        endmethod


        method Action host2CntrlQpAttr(QpAttr qpAttr);
            qpAttrBuf <= Valid(qpAttr);
            $display("hw host2CntrlQpAttr: ", fshow(qpAttr));
        endmethod


        method Action host2CntrlReq(S2hReq s2hReq);
            s2hReqBuf <= Valid(s2hReq);
            $display("hw host2Cntrl req: ", fshow(s2hReq));
        endmethod


        method Action host2Cntrl(S2hReq s2hReq);

            // let req = ReqQP {
            //     qpReqType : s2hReq.qpReqType,
            //     pdHandler : s2hReq.pdHandler,
            //     qpn       : s2hReq.qpn,
            //     qpAttrMask: ?,
            //     qpAttr    : ?,
            //     qpInitAttr: ?
            // };

            ReqQP req = ?;
            
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
                // // need no attr
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

            // qpAttrBuf <= Invalid;
            // qpInitAttrBuf <= Invalid;
            s2hReqBuf <= Valid(s2hReq);

            qpSrv.request.put(req);
            $display("hw host2Cntrl req: ", fshow(s2hReq));
        endmethod

        // method Action softReset();
        //     my_rst.assertReset; // assert my_rst.new_rst signal
        //     isResetting <= True;
        //     ready<=True;
        //     $display("hw softReset action");
        // endmethod

    endinterface
endmodule