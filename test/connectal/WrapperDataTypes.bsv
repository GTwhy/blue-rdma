typedef 5 TIMER_WIDTH;

typedef 64 ATOMIC_ADDR_BIT_ALIGNMENT;
typedef 32 PD_HANDLE_WIDTH;
typedef 8 QP_CAP_CNT_WIDTH;
// typedef 32 QP_CAP_CNT_WIDTH;
typedef 8 PENDING_READ_ATOMIC_REQ_CNT_WIDTH;
typedef 8         ATOMIC_WORK_REQ_LEN;
typedef 3         RETRY_CNT_WIDTH;

typedef 7 INFINITE_RETRY;
typedef 0 INFINITE_TIMEOUT;
// Fixed settings
typedef 64 ADDR_WIDTH;
typedef 64 LONG_WIDTH;
typedef 24 PSN_WIDTH;
typedef 24 QPN_WIDTH;
typedef 32 RDMA_MAX_LEN_WIDTH;
typedef 64 WR_ID_WIDTH;
typedef 2  PAD_WIDTH;
typedef 16 PKEY_WIDTH;
typedef 5  AETH_VALUE_WIDTH;
typedef 24 MSN_WIDTH;
typedef 32 KEY_WIDTH;
typedef 32 IMM_WIDTH;
typedef 256  MIN_PMTU;
typedef 4096 MAX_PMTU;

typedef Bit#(PD_HANDLE_WIDTH) HandlerPD;
typedef Bit#(ADDR_WIDTH) ADDR;
typedef Bit#(RDMA_MAX_LEN_WIDTH) Length; // Byte length
typedef Bit#(LONG_WIDTH) Long;
typedef Bit#(QPN_WIDTH) QPN;
typedef Bit#(PSN_WIDTH) PSN;
typedef Bit#(PAD_WIDTH) PAD;
typedef Bit#(PKEY_WIDTH) PKEY;
typedef Bit#(AETH_VALUE_WIDTH) AethValue;
typedef Bit#(MSN_WIDTH) MSN;
typedef Bit#(KEY_WIDTH) RKEY;
typedef Bit#(KEY_WIDTH) LKEY;
typedef Bit#(KEY_WIDTH) QKEY;
typedef Bit#(IMM_WIDTH) IMM;


typedef enum {
    IBV_QP_STATE               = 1,       // 1 << 0
    IBV_QP_CUR_STATE           = 2,       // 1 << 1
    IBV_QP_EN_SQD_ASYNC_NOTIFY = 4,       // 1 << 2
    IBV_QP_ACCESS_FLAGS        = 8,       // 1 << 3
    IBV_QP_PKEY_INDEX          = 16,      // 1 << 4
    IBV_QP_PORT                = 32,      // 1 << 5
    IBV_QP_QKEY                = 64,      // 1 << 6
    IBV_QP_AV                  = 128,     // 1 << 7
    IBV_QP_PATH_MTU            = 256,     // 1 << 8
    IBV_QP_TIMEOUT             = 512,     // 1 << 9
    IBV_QP_RETRY_CNT           = 1024,    // 1 << 10
    IBV_QP_RNR_RETRY           = 2048,    // 1 << 11
    IBV_QP_RQ_PSN              = 4096,    // 1 << 12
    IBV_QP_MAX_QP_RD_ATOMIC    = 8192,    // 1 << 13
    IBV_QP_ALT_PATH            = 16384,   // 1 << 14
    IBV_QP_MIN_RNR_TIMER       = 32768,   // 1 << 15
    IBV_QP_SQ_PSN              = 65536,   // 1 << 16
    IBV_QP_MAX_DEST_RD_ATOMIC  = 131072,  // 1 << 17
    IBV_QP_PATH_MIG_STATE      = 262144,  // 1 << 18
    IBV_QP_CAP                 = 524288,  // 1 << 19
    IBV_QP_DEST_QPN            = 1048576, // 1 << 20
    // These bits were supported on older kernels, but never exposed from libibverbs
    // _IBV_QP_SMAC               = 1 << 21,
    // _IBV_QP_ALT_SMAC           = 1 << 22,
    // _IBV_QP_VID                = 1 << 23,
    // _IBV_QP_ALT_VID            = 1 << 24,
    IBV_QP_RATE_LIMIT          = 33554432 // 1 << 25
} QpAttrMask deriving(Bits, Eq, FShow);

// QP related types

typedef enum {
    IBV_QPS_RESET,
    IBV_QPS_INIT,
    IBV_QPS_RTR,
    IBV_QPS_RTS,
    IBV_QPS_SQD,
    IBV_QPS_SQE,
    IBV_QPS_ERR,
    IBV_QPS_UNKNOWN
} QpState deriving(Bits, Eq, FShow);

typedef enum {
    IBV_MTU_256  = 1,
    IBV_MTU_512  = 2,
    IBV_MTU_1024 = 3,
    IBV_MTU_2048 = 4,
    IBV_MTU_4096 = 5
} PMTU deriving(Bits, Eq, FShow);

typedef enum {
    IBV_ACCESS_LOCAL_WRITE   =  1,
    IBV_ACCESS_REMOTE_WRITE  =  2, // (1 << 1)
    IBV_ACCESS_REMOTE_READ   =  4, // (1 << 2)
    IBV_ACCESS_REMOTE_ATOMIC =  8, // (1 << 3)
    IBV_ACCESS_MW_BIND       = 16, // (1 << 4)
    IBV_ACCESS_ZERO_BASED    = 32, // (1 << 5)
    IBV_ACCESS_ON_DEMAND     = 64, // (1 << 6)
    IBV_ACCESS_HUGETLB       = 128 // (1 << 7)
    // IBV_ACCESS_RELAXED_ORDERING    = IBV_ACCESS_OPTIONAL_FIRST,
} MemAccessTypeFlags deriving(Bits, Eq, FShow);

typedef Bit#(PENDING_READ_ATOMIC_REQ_CNT_WIDTH) PendingReadAtomicReqCnt;
typedef Bit#(QP_CAP_CNT_WIDTH) PendingReqCnt;
typedef Bit#(QP_CAP_CNT_WIDTH) InlineDataSize;
typedef Bit#(QP_CAP_CNT_WIDTH) ScatterGatherElemCnt;

typedef struct {
    PendingReqCnt        maxSendWR;
    PendingReqCnt        maxRecvWR;
    ScatterGatherElemCnt maxSendSGE;
    ScatterGatherElemCnt maxRecvSGE;
    InlineDataSize       maxInlineData;
} QpCapacity deriving(Bits, FShow);

typedef Bit#(RETRY_CNT_WIDTH) RetryCnt;
typedef Bit#(TIMER_WIDTH)     TimeOutTimer;
typedef Bit#(TIMER_WIDTH)     RnrTimer;

typedef struct {
    QpState                 qpState;    // init 
    QpState                 curQpState;
    PMTU                    pmtu;   // rtr
    QKEY                    qkey;
    PSN                     rqPSN;  // rtr
    PSN                     sqPSN;  // rts
    QPN                     dqpn;   // rtr
    MemAccessTypeFlags      qpAcessFlags;   // init
    QpCapacity              cap;
    PKEY                    pkeyIndex;  // init
    Bool                    sqDraining;
    PendingReadAtomicReqCnt maxReadAtomic; // rts
    PendingReadAtomicReqCnt maxDestReadAtomic;  // rtr
    RnrTimer                minRnrTimer;    // rtr
    TimeOutTimer            timeout;    // rts
    RetryCnt                retryCnt;   // rts
    RetryCnt                rnrRetry;   // rts
    // PKEY                    alt_pkey_index;
    // enum ibv_mig_state      path_mig_state;
    // struct ibv_ah_attr      ah_attr;     // TODO: rtr
    // struct ibv_ah_attr      alt_ah_attr;
    // uint8_t                 en_sqd_async_notify;
    // uint8_t                 port_num;    // TODO: init
    // uint8_t                 alt_port_num;
    // uint8_t                 alt_timeout;
    // uint32_t                rate_limit;
} QpAttr deriving(Bits, FShow);

typedef enum {
    IBV_QPT_RC = 2,
    IBV_QPT_UC = 3,
    IBV_QPT_UD = 4,
    IBV_QPT_RAW_PACKET = 8,
    IBV_QPT_XRC_SEND = 9,
    IBV_QPT_XRC_RECV = 10
    // IBV_QPT_DRIVER = 0xff
} QpType deriving(Bits, Eq, FShow);

typedef struct {
    QpType qpType;
    Bool   sqSigAll;
} QpInitAttr deriving(Bits, FShow);


typedef enum {
    REQ_QP_CREATE,
    REQ_QP_DESTROY,
    REQ_QP_MODIFY,
    REQ_QP_QUERY
} QpReqType deriving(Bits, Eq, FShow);

typedef struct {
    QpReqType  qpReqType;
    HandlerPD  pdHandler;
    QPN        qpn;
    QpAttrMask qpAttrMast;
    QpAttr     qpAttr;
    QpInitAttr qpInitAttr;
} ReqQP deriving(Bits, FShow);

typedef struct {
    // TODO: replace with errno?
    Bool       successOrNot;
    QPN        qpn;
    HandlerPD  pdHandler;
    QpAttr     qpAttr;
    QpInitAttr qpInitAttr;
} RespQP deriving(Bits, FShow);