#include <errno.h>
#include <stdio.h>
#include "CntrlIndication.h"
#include "CntrlRequest.h"
#include "GeneratedTypes.h"

static CntrlRequestProxy *cntrlRequestProxy = 0;
static sem_t sem_resp;

class CntrlIndication : public CntrlIndicationWrapper
{
public:
    virtual void cntrl2Host(RespQP resp) {
        sem_post(&sem_resp);
        printf("sw cntrl2Host: %d\n", resp.successOrNot);
    }

    CntrlIndication(unsigned int id) : CntrlIndicationWrapper(id) {}
};

static void host2Cntrl(S2hReq req)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, req.qpn);
    cntrlRequestProxy->host2Cntrl(req);
    sem_wait(&sem_resp);
}


static void host2CntrlQpInitAttr(QpInitAttr qpInitAttr)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, qpInitAttr.qpType);
    cntrlRequestProxy->host2CntrlQpInitAttr(qpInitAttr);
}

int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    
    QpInitAttr initAttr{};
    initAttr.qpType = IBV_QPT_RC;
    host2CntrlQpInitAttr(initAttr);

    S2hReq s2hReq{};
    s2hReq.qpReqType = QpReqType::REQ_QP_CREATE;
    s2hReq.qpn = 6;
    host2Cntrl(s2hReq);

    return 0;
}
