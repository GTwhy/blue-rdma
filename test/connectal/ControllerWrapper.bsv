import ClientServer :: *;
import Controller :: *;
import DataTypes :: *;
import GetPut::*;
import Utils4Test::*;

// Connectal imports
import HostInterface::*;
import Clocks::*;
import Connectable::*;

interface CntrlIndication;
    method Action cntrl2Host(RespQP respQP);
endinterface

interface CntrlRequest;
    method Action host2Cntrl(ReqQP reqQp);
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

        method Action host2Cntrl(ReqQP req) if ( !isResetting && ready );
            // let qpInitAttr = QpInitAttr {
            //     qpType  : IBV_QPT_RC,
            //     sqSigAll: False
            // };

            // let qpCreateReq = ReqQP {
            //     qpReqType : REQ_QP_CREATE,
            //     pdHandler : ?,
            //     qpn       : getDefaultQPN,
            //     qpAttrMast: ?,
            //     qpAttr    : ?,
            //     qpInitAttr: qpInitAttr
            // };
            // qpSrv.request.put(qpCreateReq);
            qpSrv.request.put(req);
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