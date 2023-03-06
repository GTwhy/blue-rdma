import ClientServer :: *;
import Controller :: *;
import DataTypes :: *;
import GetPut::*;
import Utils4Test::*;

interface CntrlIndication;
    method Action modify_qp_resp(RespQP respQP);
endinterface

interface CntrlRequest;
    method Action modify_qp(ReqQP reqQp);
endinterface

interface ControllerWrapper;
    interface CntrlRequest cntrlRequest;
endinterface

module mkControllerWrapper#(CntrlIndication cntrlIndication)(ControllerWrapper);
    let cntrl <- mkController;
    let qpSrv = cntrl.srvPort;

    rule getResp;
        let resp <- qpSrv.response.get;
        cntrlIndication.modify_qp_resp(resp);
        $display("hw modify_qp resp: ", fshow(resp));
    endrule


    interface CntrlRequest cntrlRequest;

        method Action modify_qp(ReqQP req);
            let qpInitAttr = QpInitAttr {
                qpType  : IBV_QPT_RC,
                sqSigAll: False
            };

            let qpCreateReq = ReqQP {
                qpReqType : REQ_QP_CREATE,
                pdHandler : ?,
                qpn       : getDefaultQPN,
                qpAttrMast: ?,
                qpAttr    : ?,
                qpInitAttr: qpInitAttr
            };
            qpSrv.request.put(qpCreateReq);
            $display("hw modify_qp req: ", fshow(req));
        endmethod

    endinterface
endmodule