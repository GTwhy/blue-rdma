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
    virtual void modify_qp_resp(uint32_t v) {
        sem_post(&sem_resp);
        printf("modify_qp_resp: %d\n", v);
    }

    virtual void query_qp_resp(uint32_t v) {
        sem_post(&sem_resp);
        printf("query_qp_resp: %d\n", v);
    }
    CntrlIndication(unsigned int id) : CntrlIndicationWrapper(id) {}
};

static void modify_qp(uint32_t v)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, v);
    cntrlRequestProxy->modify_qp(v);
    sem_wait(&sem_resp);
}

static void query_qp(uint32_t v)
{
    printf("[%s:%d] %d\n", __FUNCTION__, __LINE__, v);
    cntrlRequestProxy->query_qp(v);
    sem_wait(&sem_resp);
}

int main(int argc, const char **argv)
{
    CntrlIndication cntrlIndication(IfcNames_CntrlIndicationH2S);
    cntrlRequestProxy = new CntrlRequestProxy(IfcNames_CntrlRequestS2H);

    uint32_t v = 1024;
    modify_qp(v);
    query_qp(v);
    return 0;
}
