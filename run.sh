#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

BASH_PROFILE=$HOME/.bash_profile
if [ -f "$BASH_PROFILE" ]; then
    source $BASH_PROFILE
fi

cd test

RUN_LOG=run.log
echo "" > $RUN_LOG

make -j8 TESTFILE=SimDma.bsv TOP=mkTestFixedLenSimDataStreamPipeOut 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=SimGenRdmaReqAndResp.bsv TOP=mkTestSimGenRdmaResp 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestController.bsv TOP=mkTestCntrlInVec 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestDupReadAtomicCache.bsv TOP=mkTestDupReadAtomicCache 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestHeaderAndDataStreamConversion 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestPrependHeaderBeforeEmptyDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractHeaderWithLessThanOneFragPayload 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractHeaderLongerThanDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestExtractAndPrependPipeOut.bsv TOP=mkTestExtractAndPrependHeader 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculateRandomPktLen 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculatePktLenEqPMTU 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestCalculateZeroPktLen 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestInputPktHandle.bsv TOP=mkTestReceiveCNP 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestPayloadConAndGen.bsv TOP=mkTestPayloadConAndGenNormalCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestMetaData.bsv TOP=mkTestMetaDataMRs 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestMetaData.bsv TOP=mkTestMetaDataPDs 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestMetaData.bsv TOP=mkTestMetaDataQPs 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestMetaData.bsv TOP=mkTestPermCheckMR 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestReqGenSQ.bsv TOP=mkTestReqGenNormalCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandleNormalReqCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandleDupReqCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandleReqErrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandlePermCheckFailCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandleRnrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestReqHandleRQ.bsv TOP=mkTestReqHandleSeqErrCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleNormalRespCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleDupRespCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleGhostRespCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleRespErrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleRetryErrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandlePermCheckFailCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleRnrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleSeqErrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRespHandleSQ.bsv TOP=mkTestRespHandleNestedRetryCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestRetryHandleSQ.bsv TOP=mkTestRetryHandleSeqErrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRetryHandleSQ.bsv TOP=mkTestRetryHandleImplicitRetryCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRetryHandleSQ.bsv TOP=mkTestRetryHandleRnrCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRetryHandleSQ.bsv TOP=mkTestRetryHandleTimeOutCase 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestRetryHandleSQ.bsv TOP=mkTestRetryHandleNestedRetryCase 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestSpecialFIFOF.bsv TOP=mkTestCacheFIFO 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestSpecialFIFOF.bsv TOP=mkTestScanFIFOF 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestSpecialFIFOF.bsv TOP=mkTestSearchFIFOF 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestSpecialFIFOF.bsv TOP=mkTestVectorSearch 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestWorkCompGen.bsv TOP=mkTestWorkCompGenNormalCaseRQ 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestWorkCompGen.bsv TOP=mkTestWorkCompGenErrFlushCaseRQ 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestWorkCompGen.bsv TOP=mkTestWorkCompGenNormalCaseSQ 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestWorkCompGen.bsv TOP=mkTestWorkCompGenErrFlushCaseSQ 2>&1 | tee -a $RUN_LOG

make -j8 TESTFILE=TestUtils.bsv TOP=mkTestSegmentDataStream 2>&1 | tee -a $RUN_LOG
make -j8 TESTFILE=TestUtils.bsv TOP=mkTestPsnFunc 2>&1 | tee -a $RUN_LOG

FAIL_KEYWORKS='Error\|DynAssert'
grep -w $FAIL_KEYWORKS $RUN_LOG | cat
ERR_NUM=`grep -c -w $FAIL_KEYWORKS $RUN_LOG | cat`
if [ $ERR_NUM -gt 0 ]; then
    echo "FAIL"
    false
else
    echo "PASS"
fi
