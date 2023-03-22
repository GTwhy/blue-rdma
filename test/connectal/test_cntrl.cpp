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


bool modifyToRTR(PMTU pmtu, PSN rqPSN, QPN dqpn, PendingReadAtomicReqCnt maxDestReadAtomic, RnrTimer minRnrTimer)
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);

    ReqQP reqQP;
    memset(&reqQP, 0, sizeof(reqQP));

    reqQP.qpReqType = REQ_QP_MODIFY;
    reqQP.qpAttr.qpState = IBV_QPS_RTR;
    reqQP.qpAttr.pmtu = pmtu;
    reqQP.qpAttr.rqPSN = rqPSN;
    reqQP.qpAttr.dqpn = dqpn;
    reqQP.qpAttr.maxDestReadAtomic = maxDestReadAtomic;
    reqQP.qpAttr.minRnrTimer = minRnrTimer;
    reqQP.qpAttrMask = (QpAttrMask)(IBV_QP_STATE |IBV_QP_PATH_MTU | IBV_QP_RQ_PSN |
                    IBV_QP_DEST_QPN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);    

    host2Cntrl(reqQP);
    return SUCCESS_OR_NOT;
}


bool modifyToRTS(PSN sqPSN, PendingReadAtomicReqCnt maxReadAtomic, TimeOutTimer timeout, RetryCnt retryCnt, RetryCnt rnrRetry)
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);

    ReqQP reqQP;
    memset(&reqQP, 0, sizeof(reqQP));

    reqQP.qpReqType = REQ_QP_MODIFY;
    reqQP.qpAttr.qpState = IBV_QPS_RTS;
    reqQP.qpAttr.sqPSN = sqPSN;
    reqQP.qpAttr.maxReadAtomic = maxReadAtomic;
    reqQP.qpAttr.timeout = timeout;
    reqQP.qpAttr.retryCnt = retryCnt;
    reqQP.qpAttr.rnrRetry = rnrRetry;
    reqQP.qpAttrMask = (QpAttrMask)(IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                    IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC);    

    host2Cntrl(reqQP);
    return SUCCESS_OR_NOT;
}


bool destroyQP() 
{
    printf("[%s:%d] sw host2Cntrl\n", __FUNCTION__, __LINE__);

    ReqQP reqQP;
    memset(&reqQP, 0, sizeof(reqQP));

    reqQP.qpReqType = REQ_QP_DESTROY;
    reqQP.qpAttr.qpState = IBV_QPS_RESET;
    reqQP.qpAttrMask = IBV_QP_STATE;    

    host2Cntrl(reqQP);
    return SUCCESS_OR_NOT;
}


int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    bool ret = false;

    // TODO: Add randomness and assertions
    ret = createQP(IBV_QPT_RC, true);
    printf("createQP pass %d\n", ret);

    ret = modifyToInit(IBV_ACCESS_LOCAL_WRITE);
    printf("modifyToInit pass %d\n", ret);

    // TODO: improve variable definition
    ret = modifyToRTR(IBV_MTU_1024, 1, 1, 1, 1);
    printf("modifyToRTR pass %d\n", ret);

    ret = modifyToRTS(1, 1, 1, 1, 1);
    printf("modifyToRTS pass %d\n", ret);
    
    // ret = destroyQP();
    // printf("destroyQP pass %d\n", ret);

    return 0;
}
