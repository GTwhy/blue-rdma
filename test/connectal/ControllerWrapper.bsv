import ClientServer :: *;
import Controller :: *;
import WrapperDataTypes :: *:

interface CntrlIndication;
    method Action modifyQpResp(RespQP respQP);
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
        let resp = qpSrv.get;
        cntrlIndication.modifyQpResp(resp);
    endrule


    interface CntrlRequest cntrlRequest;

        method Action modify_qp(ReqQP req);
            qpSrv.put(req);
            $display("hw modify_qp req: ", fshow(req));
        endmethod

    endinterface
endmodule