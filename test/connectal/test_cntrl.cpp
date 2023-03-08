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
    virtual void modify_qp_resp(RespQP resp) {
        sem_post(&sem_resp);
        printf("modify_qp_resp: %d\n", resp.successOrNot);
    }

    CntrlIndication(unsigned int id) : CntrlIndicationWrapper(id) {}
};

static void modify_qp(ReqQP req)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, req.qpn);
    cntrlRequestProxy->modify_qp(req);
    sem_wait(&sem_resp);
}

int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    ReqQP req{};
    req.qpn = 1;
    modify_qp(req);
    return 0;
}
