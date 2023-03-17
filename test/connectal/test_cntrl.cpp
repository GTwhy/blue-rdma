#include <errno.h>
#include <stdio.h>
#include "CntrlIndication.h"
#include "CntrlRequest.h"
#include "GeneratedTypes.h"

static CntrlRequestProxy *cntrlRequestProxy = 0;
static sem_t sem_resp;

bool SUCCESS_OR_NOT = false;

class CntrlIndication : public CntrlIndicationWrapper
{
public:
    virtual void cntrl2Host(RespQP resp) {
        printf("[%s:%d] sw cntrl2Host\n", __FUNCTION__, __LINE__);
        SUCCESS_OR_NOT = resp.successOrNot;
        sem_post(&sem_resp);
    }

    CntrlIndication(unsigned int id) : CntrlIndicationWrapper(id) {}
};

static void host2Cntrl(ReqQP req)
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);
    SUCCESS_OR_NOT = false;
    cntrlRequestProxy->host2Cntrl(req);
    sem_wait(&sem_resp);
}

bool createQP(QpType qpType, bool sqSigAll) 
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);

    ReqQP reqQP;
    QpInitAttr qpInitAttr = QpInitAttr {qpType, sqSigAll};
    memset(&reqQP, 0, sizeof(reqQP));

    reqQP.qpReqType = REQ_QP_CREATE;
    reqQP.qpInitAttr = qpInitAttr;
    host2Cntrl(reqQP);
    return SUCCESS_OR_NOT;
}

// int modifyToInit(MemAccessTypeFlags flag, uint8_t port_num, uint16_t pkey_index) {
bool modifyToInit(MemAccessTypeFlags qpAcessFlags)
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);

    ReqQP reqQP;
    memset(&reqQP, 0, sizeof(reqQP));

    reqQP.qpReqType = REQ_QP_MODIFY;
    reqQP.qpAttr.qpState = IBV_QPS_INIT;
    reqQP.qpAttr.qpAcessFlags = qpAcessFlags;
    reqQP.qpAttrMask = (QpAttrMask)(IBV_QP_STATE | IBV_QP_ACCESS_FLAGS);

    host2Cntrl(reqQP);
    return SUCCESS_OR_NOT;
}

    bool modify_to_rtr(RQAttr rq_attr) {
        // SAFETY: POD FFI type
        ibv_qp_attr qp_attr = {};
        qp_attr.qp_state = IBV_QPS_RTR;
        qp_attr.path_mtu = static_cast<ibv_mtu> (rq_attr.mtu);
        qp_attr.dest_qp_num = rq_attr.dest_qp_number;
        qp_attr.rq_psn = rq_attr.rq_psn;
        qp_attr.max_dest_rd_atomic = rq_attr.max_dest_rd_atomic;
        qp_attr.min_rnr_timer = rq_attr.min_rnr_timer;
        qp_attr.ah_attr = rq_attr.address_handler;
        ibv_qp_attr_mask flags = static_cast<ibv_qp_attr_mask> (
            IBV_QP_STATE |
            IBV_QP_AV |
            IBV_QP_PATH_MTU |
            IBV_QP_DEST_QPN |
            IBV_QP_RQ_PSN |
            IBV_QP_MAX_DEST_RD_ATOMIC |
            IBV_QP_MIN_RNR_TIMER
        );
        // SAFETY: ffi, and qp will not modify by other threads
        int errno = ibv_modify_qp(as_ptr(), &qp_attr, static_cast<int>(flags));
        if (errno != 0) {
            return log_ret_last_os_err();
        }
        *cur_state.write() = QueuePairState::ReadyToRecv;
        return 0;
    }

//     int modify_to_rts(SQAttr sq_attr) {
//         // SAFETY: POD FFI type
//         ibv_qp_attr attr = {};
//         attr.qp_state = IBV_QPS_RTS;
//         attr.timeout = sq_attr.timeout;
//         attr.retry_cnt = sq_attr.retry_cnt;
//         attr.rnr_retry = sq_attr.rnr_retry;
//         attr.sq_psn = sq_attr.sq_psn;
//         attr.max_rd_atomic = sq_attr.max_rd_atomic;
//         ibv_qp_attr_mask flags = static_cast<ibv_qp_attr_mask> (
//             IBV_QP_STATE |
//             IBV_QP_TIMEOUT |
//             IBV_QP_RETRY_CNT |
//             IBV_QP_RNR_RETRY |
//             IBV_QP_SQ_PSN |
//             IBV_QP_MAX_QP_RD_ATOMIC
//         );
//         // SAFETY: ffi, and qp will not modify by other threads
//         int errno = ibv_modify_qp(as_ptr(), &attr, static_cast<int>(flags));
//         if (errno != 0) {
//             return log_ret_last_os_err();
//         }
//         *cur_state.write() = QueuePairState::ReadyToSend;
//         return 0;
//     }


int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    bool ret = false;
    ret = createQP(IBV_QPT_RC, false);
    printf("createQP pass %", ret);
    ret = modifyToInit(IBV_ACCESS_LOCAL_WRITE);
    printf("modifyToInit pass %", ret);
    return 0;
}
