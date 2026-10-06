# S1 cost-model ledger: sharding the replicated prefill family

Written 2026-10-05 after G1 (rocprofv3 window = one clean 32 k main-prompt
pass, `evidence/prefill-triage/g1-r1a/prof-g1/`). All figures per rank.
The question: which of the un-halved "replicated" families can actually pay
for an exchange, at what byte cost, and with what numerical contract.

**Status update (2026-10-05, later): candidate 1 was implemented and
REJECTED — see the bottom line.**

## Inventory (32 k window, per rank, post-G1 build)

| Family | Kernel | ms | Notes |
| --- | --- | ---: | --- |
| Fused HC mixer down | W8A8BlockedWmma<64,128,4,2,4,true> | 657 | 320×10240, 1 504 calls |
| HC mix epilogue | HcMixEpilogueF16Kernel | 387 | elementwise + narrow/q8 emits |
| Router/indexer dense | DenseF16GEMM<256,128,1,4,2,8,true> | 838 | 1 504 calls, shapes not yet captured |
| Small dense | DenseF16GEMM<64,64,2,2,4,1> | 266 | 1 344 calls |
| Select score/mark | — | 154 | triage figure |

Replicated total ≈ 2.3 s of the ~14.4 s pass. Reference exchange traffic
today: 32.25 GB/pass at 2.11 GB/s staging, 98.5 % overlapped, GPU waits
10.6 ms — the overlap machinery has headroom for more wire, not for more
serial waits.

## Candidate 1 — N-split the fused HC mixer down (IMPLEMENTED, REJECTED)

Each rank computed 160 of the 320 low-rank rows and exchanged the F32
halves before the up projection consumed them. The arithmetic was proven
bit-exact two ways (operator check at 96/2049 tokens; canonical member
checksums end-to-end through the real pair path, via a new *tagged*
start/finish exchange in the tbstream transport that interleaves with the
part-boundary exchanges). The performance collapsed anyway:

- The transport stages every started exchange through **one worker
  thread**, in start order. A mid-part 1.25 MB exchange queues behind the
  preceding 20 MB part-boundary staging (~10 ms at 2.1 GB/s), and its
  host-side finish blocks the queue engine (the host is what feeds the
  stream), so each of the 1 504 mixer calls pays ~5 ms of exposed latency.
- Measured: timed 32 k prefill **1 490 tok/s (−35 %)** against a 260 ms
  GPU saving. The lo exchange cannot ride the queued (GPU-staged) path,
  because that path requires zero started exchanges in flight and the pair
  loop keeps one or two boundary exchanges outstanding at all times.
- Enabling prerequisite, if this is ever revisited: move the pair loop's
  part-boundary exchanges onto the queued GPU-staged path (or add a second
  staging channel for small mid-part frames). That is a transport redesign,
  not an executor change.

Measurement trap recorded for every future gated route: the probe's
`CollectiveTrace` decorator must delegate newly added transport methods —
the first four "A/B" pairs of this experiment were accidental A/A (the
split silently never ran) until a profile showed zero assembly-kernel
launches.

## Candidate 2 — N-split the HC up / anything after the low-rank bottleneck

The up writes the full 10 240-wide mixed activation that both ranks'
replicated residual stream consumes; an all-gather there moves
2 048×10 240×2 B ≈ 40 MB per call ≈ 46 GB/pass. **Dead on bandwidth** —
this is the concrete form of "the HC low-rank factorization caps
exchange-based splits": exchange AT the 320-wide bottleneck (candidate 1),
never after it.

## Candidate 3 — router/indexer dense family (needs shape capture first)

838 + 266 ms is the second-biggest replicated block, but the per-operator
shapes are not yet attributed (the 16×40/64×64 grids cover several
projections). Router-shaped outputs are small but must be gathered before
a replicated top-k; modeled wire is O(GB/pass) for ~550 ms of saving —
marginal. **Action: capture the per-op shape inventory** (observer hook or
one profile pass with launcher instrumentation) before deciding.

## Ruled out

- Elementwise/epilogue splits (387 ms): no arithmetic to halve, pure
  bandwidth already replicated by design.
- Select/score (154 ms): <0.2 % ceiling.
- K-splits of any projection: change the reduction contract for no byte
  saving over N-splits.

## Bottom line

The one implementable candidate was implemented and rejected on transport
architecture, not bandwidth: mid-part exchanges serialize behind the
part-boundary stagings in the single worker thread, and the host-side
finish starves the stream (−35 % e2e against a +1.8 % ceiling). Everything
else in the replicated family is bandwidth-dead or needs the shape-capture
pass first, and the shape capture is now moot for splitting purposes —
**exchange-based sharding of the replicated family is closed on this
transport** until small mid-part frames can be GPU-staged (queued path for
the pair loop's boundary exchanges, or a second staging channel). The
remaining honest levers for prefill are single-host kernel-level speedups
(which help both configurations) and the transport-level staging redesign.
