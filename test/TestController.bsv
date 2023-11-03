import ClientServer::*;
import DataTypes::*;
import FIFOF::*;
import Headers::*;
import Settings::*;
import PrimUtils::*;
import Utils::*;
import GetPut::*;

import Controller::*;

module mkTestbench();
    // Instantiate mkController
    Controller controller <- mkController;

    // Default QP attributes
    QpAttr defaultQpAttr = QpAttr {
        qpState      : INIT,
        qpAccessFlags: 0,
        pkeyIndex    : 0,
        portNum      : 0,
        qpDestQpn    : 0,
        qpPathMtu    : 0,
        qpTimeout    : 0,
        qpRetryCnt   : 0,
        qpRnrNakCnt  : 0,
        qpSvcType    : 0,
        qpMaxRdAtom  : 0,
        qpMaxDestRdAtom: 0,
        qpMinRnrNak : 0
    };

    QpInitAttr defaultQpInitAttr = QpInitAttr {
        qpSendCq     : 0,
        qpRecvCq     : 0,
        qpSrQ        : 0,
        qpMaxSendWr  : 0,
        qpMaxRecvWr  : 0,
        qpMaxSendSge : 0,
        qpMaxRecvSge : 0,
        qpXrcDomain  : 0
    };

    // Test stimuli for mkController
    ReqQP reqCreate = ReqQP {
        qpReqType : REQ_QP_CREATE,
        qpn       : 0,
        pdHandler : 0,
        qpAttr    : defaultQpAttr,
        qpInitAttr: defaultQpInitAttr
    };

    ReqQP reqModify = ReqQP {
        qpReqType : REQ_QP_MODIFY,
        qpn       : 0,
        pdHandler : 0,
        qpAttr    : defaultQpAttr,
        qpInitAttr: defaultQpInitAttr
    };

    ReqQP reqQuery = ReqQP {
        qpReqType : REQ_QP_QUERY,
        qpn       : 0,
        pdHandler : 0,
        qpAttr    : defaultQpAttr,
        qpInitAttr: defaultQpInitAttr
    };

    ReqQP reqDestroy = ReqQP {
        qpReqType : REQ_QP_DESTROY,
        qpn       : 0,
        pdHandler : 0,
        qpAttr    : defaultQpAttr,
        qpInitAttr: defaultQpInitAttr
    };

    // Testbench rules
    rule initController;
        // Initialize the controller by sending a create request
        if (controller.srvPort.request.canPut) begin
            controller.srvPort.request.put(reqCreate);
            $display("Sent create request");
        end else begin
            $display("Failed to send create request");
            $finish;
        end
    endrule

    rule modifyController;
        // Modify the controller by sending a modify request
        if (controller.srvPort.request.canPut) begin
            controller.srvPort.request.put(reqModify);
            $display("Sent modify request");
        end else begin
            $display("Failed to send modify request");
            $finish;
        end
    endrule

    rule queryController;
        // Query the controller by sending a query request
        if (controller.srvPort.request.canPut) begin
            controller.srvPort.request.put(reqQuery);
            $display("Sent modify request");
        end else begin
            $display("Failed to send modify request");
            $finish;
        end
    endrule
    rule destroyController;
        // Destroy the controller by sending a destroy request
        if (controller.srvPort.request.canPut) begin
            controller.srvPort.request.put(reqDestroy);
            $display("Sent destroy request");
        end else begin
            $display("Failed to send destroy request");
            $finish;
        end
    endrule
    
    rule displayResponse;
        // Display response from controller
        if (controller.srvPort.response.canGet) begin
            RespQP resp = controller.srvPort.response.get;
            $display("Received response: ", fshow(resp));
            controller.srvPort.response.get;
        end
    endrule
endmodule