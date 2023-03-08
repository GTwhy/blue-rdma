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

static void host2Cntrl(ReqQP req)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, req.qpn);
    cntrlRequestProxy->host2Cntrl(req);
    sem_wait(&sem_resp);
}

int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    ReqQP req{};
    req.qpn = 1;
    host2Cntrl(req);
    return 0;
}
