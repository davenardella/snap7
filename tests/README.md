# Tests for malformed PLC answers (AddressSanitizer)

`rogue_plc.py` is a scripted S7 server that answers a client with deliberately wrong telegrams.
`client_test.cpp` is a small client that issues reads, writes, CPU-info and status calls, with buffers
of exactly the requested size. `build-asan.ps1` builds `snap7.dll` (Win32, `/fsanitize=address`) for any
source tree, and `run-tests.ps1` runs every scenario against two builds and prints one row per scenario.

## Run

```
tests\build-asan.ps1 -Tree <upstream tree>  -Name old
tests\build-asan.ps1 -Tree <patched tree>   -Name new
tests\run-tests.ps1                         # -Only frag3 -Builds new for a subset
```

Needs Visual Studio with the ASan component (x86) and Python 3. Logs, including the ASan traces, are written to
`tests\out\logs\`. Settings: `/Od /Zi /MD /fsanitize=address`, no `/RTC1`, `/INCREMENTAL:NO`.

Error codes: `0x00800000` errCliInvalidPlcAnswer, `0x01600000` errCliInvalidDataSizeRecvd,
`0x00100000` errNegotiatingPDU.

## Scenarios

Result of `old` = upstream `30f37da` (1.4.3), `new` = the same plus the client fixes
(branch `client-fixes`). MSVC 19.51, 2026-11-10.

| Scenario | Issue | old | new |
|---|---|---|---|
| normal | - | all 0 | all 0 |
| read_big: answer carries 1000 bytes more than requested | #31 | heap-buffer-overflow in `opReadArea` | ReadArea `0x01600000` |
| read_claim: DataLength claims more than the telegram holds | #31 | heap-buffer-overflow in `opReadArea` | ReadArea `0x01600000` |
| read_short: successful answer with 50 of 100 bytes | - | ReadArea 0, buffer silently half filled | ReadArea `0x01600000` |
| neg_big: negotiate reply with PDU length 65535 | #17 | access violation in `opReadArea` after the client object was overwritten | PDU clamped, all 0 |
| neg_short / neg_long: negotiate reply not 20 bytes | - | ConnectTo 0, `PDULength` uninitialised, heap-buffer-overflow read in `opWriteArea` | `0x00100000` |
| frag: 60 ISO fragments, EoT only on the last | #33 | accepted | ReadArea `0x00800000` |
| frag3: a valid answer split into 3 fragments | #33 | success, `data=MISMATCH` | success, data ok |
| seq: wrong Sequence in every answer | - | accepted | `0x00800000` |
| szl_big: SZL slices claiming 32 KiB | #11 | heap-buffer-overflow in `opReadSZL` | `0x01600000` |
| szl_endless: "not done" forever, 16 bytes per slice | - | heap-buffer-overflow in `opReadSZL` | `0x00800000` |
| szl_endless0: "not done" forever, no data | - | endless loop (killed after 30 s) | `0x00800000` |
| recovery: one server, connections 1..3 = read_big, seq, normal | #31 | ASan, then accepted | `0x01600000`, `0x00800000`, then all 0 |

No ASan report occurs on `new` in any scenario.

Note: the overflow of #33 is not reported by ASan, because the out-of-bounds write is done by `recv()` inside ws2_32,
which is not instrumented. `frag3` shows its effect (wrong data); `frag` shows that the telegram is rejected.
