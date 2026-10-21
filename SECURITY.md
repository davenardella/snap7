# Security Policy
Summary

A passive partner stores the TotalPackSize a peer declares at the start of a BSend sequence and later uses it, unvalidated, as the memcpy length into a buffer owned by the calling application. The API gives the caller no way to declare the size of that buffer, so an application that allocates for its expected payload has no supported way to avoid the overflow.

This is not the same defect as #15. That issue covers the unvalidated reassembly into the library's internal RxBuffer inside PickData(). This report covers a different sink of the same field: the value leaving the library and landing in memory the library neither owns nor can size. Bounding the reassembly in PickData() does not fix this path, because FRecvLast.Size is taken from the declared length rather than from the number of bytes actually reassembled — a peer can declare 65535 and send one short fragment.

It is the partner-side counterpart of #31 (opReadArea), which was assigned CVE-2026-111280 on 2026-10-15.

Trace (HEAD 30f37da, src/core/s7_partner.cpp)
c
// 853 - declared by the peer, stored unvalidated
FRecvStatus.TotalLength = SwapWord(*TotalPackSize);      // 0..65535

// 930 - the declared value, not the received byte count
FRecvLast.Size = FRecvStatus.TotalLength;

// 934 - handed to application code with no stated upper bound
OnBRecv(FRecvUsrPtr, FRecvLast.Result, FRecvLast.R_ID, &RxBuffer, FRecvLast.Size);

// 1130-1134, BRecv()
Size = FRecvLast.Size;
if (pData != NULL)
    memcpy(pData, &RxBuffer, Size);      // no bound on the caller's allocation

// 1161-1165, CheckAsBRecvCompletion()
Size = FRecvLast.Size;
if ((pData != NULL) && (Size > 0) && (opResult == 0))
   memcpy(pData, &RxBuffer, Size);       // same, async path

The only guard on either sink is a NULL check.

Impact

Any peer able to reach TCP/102 on a listening partner, or to impersonate the configured remote peer, controls how many bytes are written past the end of the application's receive buffer, up to 65535. S7 has no authentication. The write happens inside the consuming process — typically a SCADA front end, HMI gateway or data collector — so the outcome ranges from a deterministic crash to heap/stack corruption.

Suggested fix
c
// 1) In PickData(), reject a declared length that cannot fit:
FRecvStatus.TotalLength = SwapWord(*TotalPackSize);
if (FRecvStatus.TotalLength > sizeof(RxBuffer.Data)) {
    LastError = errParInvalidPDU;
    return false;
}

// 2) Let the caller state its capacity so the copy can be bounded:
int TSnap7Partner::BRecv(longword &R_ID, void *pData, int bufSize,
                         int &Size, longword Timeout);

Exporting a public S7_MAX_BSEND_SIZE equal to sizeof(TPendingBuffer::Data) would also let existing callers allocate correctly without reading library internals. The same applies to the OnBRecv callback contract.

Notes

Verified by manual review against HEAD 30f37da. A PoC that demonstrates the overflow under AddressSanitizer is available on request — I am holding it back rather than posting it here. Full write-up available as a PDF advisory (SNAP7-TX-2026-01). I have requested a CVE identifier.

Reported by Telmo Xavier (t31m0), CGI España.

