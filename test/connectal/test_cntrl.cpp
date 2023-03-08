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
    virtual void modify_qp_resp(uint32_t resp) {
        sem_post(&sem_resp);
        printf("modify_qp_resp: %d\n", resp);
    }

    CntrlIndication(unsigned int id) : CntrlIndicationWrapper(id) {}
};

static void modify_qp(uint32_t req)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, req);
    cntrlRequestProxy->modify_qp(req);
    sem_wait(&sem_resp);
}

int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);
    cntrlRequestProxy->softReset();
    uint32_t v = 1;
    modify_qp(v);
    return 0;
}
