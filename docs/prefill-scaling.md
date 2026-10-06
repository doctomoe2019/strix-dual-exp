# Prefill scaling triage: what holds dual-host TP2 below 2×

Investigated 2026-10-05 on the frozen stack (baseline-B kernel, gufo
`b7ee0a9` + the `prefill_probe` tool added on `feat/tp2-tbstream`).
All evidence in `evidence/prefill-triage/`; rocprofv3 databases from the
session: `/tmp/opencode/prof-dual/dual_results.db` (14 MB) and
`/tmp/opencode/prof-single/single_results.db` (11 MB) — copy before reboot.

## Question

Single-host prefill runs ~1.5 k tok/s at depth, so perfect TP2 scaling would
be >3 k tok/s. Measured dual throughput is ~2.0–2.2 k — about two-thirds of
that. Compute, bandwidth, latency, or something else?

## Answer

**GPU compute, and specifically compute that TP2 does not halve.** The link
is not the limit: during a profiled 32 k prefill the rank-0 GPU was busy
97.6 % of the wall span, and the GPU-side exchange-wait kernel
(`WaitValueKernel`) totaled **10.6 ms of a 15.3 s prefill (0.07 %)**. The
split-reduce overlap hides the exchanges almost completely (consistent with
the earlier wire-quantization result: f16/q8 payloads bought only +1.6/+4.3 %
end-to-end).

## Matched measurements (same synthetic token walk, same `Session::Sync` path)

`tp_batched_probe` (pair) vs `prefill_probe` (single host), non-MTP,
context 65536, GPUs forced high, cold session per repeat:

| Tokens | Single (tok/s) | Dual (tok/s) | Speedup |
| ---: | ---: | ---: | ---: |
| 2048 | 1724–1725 | 1566 | **0.91×** |
| 8192 | 1458–1478 | 2100 | 1.43× |
| 32768 | 1448–1541 | 1933–2176 | 1.31–1.41× |
| 61440 | 1519–1547 | 2026–2149 | 1.32–1.36× |

Notes:

- Below one full prefill chunk the pair LOSES: a 2048-token prompt splits
  into two 1024-row lanes with smaller GEMMs plus exchange overhead.
- Session-to-session variance is ±6 % on both configs; future A/B needs
  interleaved rounds.
- Single-host MTP prefill was *faster* than non-MTP at 8 k (+9.5 %) and
  32 k (+3.3 %), parity at 61 k — a depth interaction in the kv-only
  catch-up path, not yet explained, worth a look on its own.
- Dual serve cross-check @62 449 tokens: non-MTP 1880–2117 vs MTP 2030 —
  MTP catch-up is neutral on the dual side; serve vs probe harness
  differences are inside the variance band.

## Corrections (2026-10-05, post-audit)

Three errors in the original attribution, found while planning the first
optimization:

1. **The initially proposed `down_e` exchange is wrong.** `down_e` is
   `[tokens × selected experts × hidden]` (~100 MiB at 2 048 tokens), not a
   halved expert intermediate; exchanging it would multiply the MoE
   boundary's wire bytes by five and overflow the 32 MiB windows. Dropped.
2. **The excess percentages double-counted the MoE epilogue.** Its 546 ms
   appeared both in the combine-family excess and in the TP2-only-kernels
   bucket. The kernel-level table is correct; the percentage split was not.
3. **The 10.6 ms `WaitValue` total is not the large-prefill wait budget.**
   Those calls belong to the small second prompt and the decode phase; the
   paired large exchanges wait host-side in `FinishPartial`. GPU-busy time
   also cannot by itself separate arithmetic from memory stalls.

A memory-copy trace of the same 32 k prefill quantifies the staging path:
**1 538 D2H copies × 20 MiB = 32.25 GB over the 15.3 s pass (2.11 GB/s
sustained), 98.5 % of copy time concurrent with compute** — a ~1–2 %
fabric-contention tax on the kernels, real but small. The working diagnosis
(Replicated GPU work + extra memory passes, link exonerated) stands.

## Stage 1 result: fused peer-add combine (retained, effect small)

`SplitReduce.finish` (add-the-peer) became `acquire` (return the peer
pointer); the paired lane's combine folds the sum in registers
(`HcCombinePeerVec4Kernel`, bit-exact by construction: same two-operand FP32
sum and reduction order; f16/q8 wire and uncovered geometries fall back to
the plain add).

- Operator check: bit-exact vs the unfused sequence at 37 and 2 048 tokens
  (residual, F16/float norm, tiled Q8, summed row).
- End-to-end: both-rank logit hashes and member checksums **identical to the
  baseline binary**.
- Kernel time at 32 k: the `AddRowsBroadcast` family (631 ms) disappears;
  the fused kernel runs 2 605 ms against the unfused pair's 2 826 ms
  (~220 ms/rank, profile pass 93 of the 9addbac+fix build).

**Corrected measurement (2026-10-05 evening).** The first A/B ("wins 8/8,
median +1.9 %") miscounted four paired comparisons as eight, and both arms
measured each process's *first* prefill: an A/A control with identical
binaries swung 2 088–2 210 tok/s (±5 %). The probe now runs an untimed
warmup prefill first (A/A ±0.7 %; steady-state paired prefill ≈ 2 235 tok/s
at 32 k), after which a balanced A/B against a no-fusion twin build measures
a **median +0.9 %**. Retained for the exact fused path and the removed pass,
not as a throughput claim. A residual "slow mode" remains: roughly one run
in five lands ~6 % slow on BOTH ranks from the warmup onward (whole-session
memory placement, not first-touch); the warmup doubles as a canary —
discard-and-retry pairs whose warmup exceeds ~2.3 s.

**Alias hazard found and fixed (same session).** With a MoE observer armed,
`ForwardPair` passed the block buffer as both the fused kernel's local input
and its summed-row output; every stream re-reads the local row, so an
in-place sum added the peer again. Production was unaffected (no observer),
but the diagnostic path corrupted every MoE hash and a member checksum
(reproduced on the 9addbac binary; fixed build = baseline hashes again). The
host wrappers now refuse `block_summed == block_local`, which routes the
observer path through the separate add.

## Stage 1b result: K/V-only draft catch-up in paired prefill (retained, +2 %)

`ForwardPair`'s known-hidden catch-up forwards now take the `kv_only` path
the unpaired prefill already uses; the next full forward rebuilds the
predictor residual from the kept trunk rows.

- Gates: paired `tp_probe --split` (1 261-token prompt, MTP) whole-vs-split
  logits bit-identical on both ranks; member tokens/checksums across the
  change equal each other AND the greedy AR decode (rank agreement exact);
  the chunk seam covered with a 4 104-token prompt.
- Perf (canary-gated interleaved pairs, MTP): 8 k +3.0/+1.2 %, 32 k
  +1.5/+2.9 % — **median +2.1 %**, 4/4 pairs favor the change.

## Measurement protocol (from Stage 1's correction onward)

- The paired probe runs an untimed warmup prefill before its timed loop; a
  120 ms pause after the warmup opens a clean profile boundary.
- Canary: discard and retry any pair whose warmup exceeds ~2.3 s (slow mode:
  ~1 in 5 sessions runs ~6 % slow on both ranks from allocation onward).
- A/B arms differ by exactly the change under test (twin worktree builds);
  interleave and reverse order; report paired medians, never means across
  slow-mode-contaminated sessions.
- Steady-state references @32 k (canary-clean): non-MTP ≈ 2 235 tok/s,
  MTP ≈ 2 180 (post Stage 1b).

## Where the un-halved GPU time goes (rocprofv3, 32 768 tokens)

Both runs are GPU-bound (single 98.9 % busy over 20.7 s kernel time, dual
rank-0 97.6 % busy over 14.9 s). Per token: single 0.632 ms of GPU time,
each dual rank 0.456 ms — **72 % of a single host per rank; the excess over
perfect halving is 4 583 ms/rank (30.7 % of dual GPU time)**:

| Kernel family | single ms | dual ms/rank | ratio | ideal (÷2) |
| --- | ---: | ---: | ---: | ---: |
| RoutedF16GEMM (experts) | 6932 | 3745 | 0.54 | 3466 |
| DenseF16 16x64→32 (split) | 2490 | 1245 | 0.50 | 1245 |
| WmmaCausalAttention (split) | 1723 | 897 | 0.52 | 862 |
| GDN family (split) | 1879 | 1076 | 0.57 | 939 |
| **Combine family** | **2244** | **2195** | **0.98** | 1122 |
| **MoeEpilogue (TP2-only)** | 0 | 546 | — | 0 |
| **AddRowsBroadcast (TP2-only)** | 0 | 631 | — | 0 |
| DenseF16 16x40 (replicated) | 803 | 834 | **1.04** | 402 |
| W8A8 16x5 (replicated) | 960 | 834 | **0.87** | 480 |
| HcMixEpilogueF16 (replicated) | 395 | 386 | **0.98** | 197 |
| DenseF16 16x10 (partial) | 1064 | 695 | 0.65 | 532 |
| Select score/mark (replicated) | 213 | 154 | 0.72 | 107 |
| WaitValue (exposed comm) | 0 | 10.6 | — | 0 |

Excess decomposition (per rank, at 32 k):

1. **Combine family lost fusion — 1 619 ms (35 % of the excess).** The
   single-host path fuses the MoE epilogue into the following combine
   (`HcCombineMoeF16`, 750 calls, 1 293 ms) and its `HcCombineVec4` handles
   only mixer combines (765 calls, 951 ms). TP2 disables the fusion
   (`moe_pending_ = out == s_.block_out && tp_world_size() == 1`,
   executor.cpp:1892) because the MoE output must be materialized for the
   exchange: every MoE layer runs a separate `MoeEpilogueVec4` plus an
   unfused F32 `HcCombineVec4`, doubling that kernel's call count (1 606)
   at full replicated width. The dual combine family costs MORE than the
   whole single host (2 741 vs 2 244 ms) despite half the model.
2. **TP2-only kernels — 1 188 ms (26 %).** `AddRowsBroadcast` (peer-add,
   631 ms) plus the materialized `MoeEpilogue` (546 ms) plus 11 ms of
   waits.
3. **Replicated, un-halved families — 1 197 ms (26 %).** DenseF16 16x40,
   W8A8 16x5, `HcMixEpilogueF16`, half of DenseF16 16x10, select score/mark:
   hyperconnection/indexer/router-adjacent shapes the partition does not
   split.
4. **Split inefficiency — ~580 ms (13 %).** Experts at 0.54, GDN at 0.57,
   attention at 0.52 of single.

## Optimization ranking

1. **[Stage 1, DONE: retained, +0.9 % steady-state median — see above.]**
2. **[Stage 1b, DONE: retained, +2.1 % on paired MTP prefill — see above.]**
3. **[TP2 launch plan (P1), DONE 2026-10-05: retained, +0.7 % median @32 k
   (3/3 pairs), 8 k even — the rank's 2 560×3 072 output projections take
   the one-host 6 144 shape's five-row-tile launch order; bit-exact.]**
4. **[LDS-staged combine rows (C2), DONE 2026-10-05: retained, +1.15 %
   median @32 k over the P1 twin (4/4 clean pairs), 8 k even; bit-exact;
   peer-combine kernel mean −4 % (1 713.5 → 1 643.7 µs). The remaining
   combine headroom is real but smaller than the traffic estimate — the
   repeated reads were not all DRAM-bound.]**
5. **Combine-kernel efficiency — instruction diet is DEAD (H1, rejected
   2026-10-05).** Constant-folding the index math kept every bit but moved
   the kernel only −1.4 % per call; the data-reuse route (C2) captured the
   available gain. Further combine work needs a residual-layout or
   store-width redesign.
6. **Chunk-width re-sweep (C1, 2026-10-05, closed): 2 048 retained.**
   1 536-token lanes −3.7/−5.0 % @32 k; 3 072-token lanes +1.3/+0.9/+1.4 %
   @32 k (24 % fewer layer exchanges) but −2.1 % @8 k (ragged tail).
   Mixed-sign at ~1 %.
7. **[GDN row-split parallelism (G1), DONE 2026-10-05: retained.]** The TP2
   geometry's 48-block grid (2 row blocks × 24 value heads vs the single
   host's 96) under-filled the device; the kernel is now block-size
   templated and the rank's geometry dispatches 128-thread/32-row blocks
   (96 blocks, per-row lanes and DPP reduction unchanged → bit-exact).
   Kernel mean 1 466.6 → 1 294.5 µs (**−11.7 %**, controls ≤0.2 %);
   e2e @32 k **median +0.40 % (5/6 clean pairs)**, 8 k even.
8. **[Routed experts (R1), CLOSED 2026-10-05.]** R1a (skip provably dead
   epilogue tiles, bit-exact by construction) made the kernels *slower*
   (+6–9 %/call, e2e −2.45 %) — replacing the constant unrolled trip count
   with the runtime `live_tok_tiles` bound perturbed the live path more
   than the dead tiles cost. With the earlier 256-row-block and
   expert-ordered rejections, three scheduling/tiling interventions have
   now failed on this family: it is weight-streaming-bound (0.54 of single
   vs 0.50 ideal — only ~360 ms of excess). R1b (K=320 down
   specialization) deprioritized: no mechanism that changes stage count
   addresses streaming. Revisit only with a weight-layout/streaming idea,
   which would help single-host too.
9. **Split the replicated dense/W8A8/mix family — CLOSED on this transport
   (2026-10-05).** The S1 ledger's one positive candidate (N-split of the
   fused HC mixer down, ~260 ms ceiling) was implemented bit-exact — the
   halves' scale/SiLU/rounding reproduce the fused epilogue exactly, with a
   new tagged exchange in the transport for the mid-part boundary — and
   still collapsed to **1 490 tok/s (−35 %)**: the single staging worker
   serializes every mid-part 1.25 MB exchange behind the preceding 20 MB
   part-boundary staging, and the host-side finish starves the stream.
   Splits after the 320-wide low-rank bottleneck were already
   bandwidth-dead. Revisit only after a transport redesign that
   GPU-stages small mid-part frames (queued path for the pair loop's
   boundary exchanges, or a second staging channel).
10. Kernel-level prefill speedups help single and dual equally; with the
   exchange-based routes exhausted, they are the only route to 3k tok/s
   on this partition.
11. **[HC inject-into-combine fusion (HCF1), DONE 2026-10-06: retained,
    +2.65% median @32k.]** The F16-norm combine's plain and peer routes now
    emit the next mixer's inject partials from the norm values they already
    hold (LDS-staged norm, the separate pass's exact grouping/reduction —
    byte-identical partials; `HcMix` skips its inject pass). 4/4 clean
    canary-gated pairs, full separation (2 269→2 329 tok/s), 8k +2.3%,
    decode flat, checksums canonical. The MoE-fused combine's variant is
    NOT bit-exactible (its norm compiles to v_fma_mix*_f16; closed).
    Evidence: `evidence/prefill-triage/hcf1/`.

Steady-state reference @32k after HCF1: ≈ 2 330 tok/s (canary-clean
sessions of 2026-10-06; the same session's baseline arm measured ≈ 2 270,
the historical reference ≈ 2 285 — absolute levels drift by session, the
paired deltas are the decision basis). Cumulative retained since the
triage: ≈ +5.5% over the Stage-1b build.

12. **[F32 mixed-store skip (HCS1), DONE 2026-10-06: retained, +0.86%
    median @32k.]** The FFN mixer's wide fused projection no longer writes
    the F32 mixed row: every consumer reads the F16/Q8 side outputs through
    the executor's activation caches (F16 router, Q8 shared expert, F16
    routed rows). A `kSkipF32` template sibling keeps the storing variant's
    codegen untouched; the attention mixer still stores (its row feeds the
    BF16 indexer re-narrow and the F32 SSM alpha/beta projection), and a
    cached router-type scan plus the MoE-observer check re-enable the store
    when needed. Isolated kernel −18.8% (580→471 µs @2 048 tokens); the
    first paired A/B was an accidental A/A — the scan initially included
    `alpha_beta` (F32 in this model, but it consumes only the attention
    mixer's row) and suppressed the skip; the corrected build's profile
    shows 48 skip + 48 keep instantiations per chunk. Paired TP2 4v4
    canary-clean @32k: 2 310→2 330 median (+0.86%, not fully separated),
    8k even, decode flat, checksums canonical. Retained on kernel evidence
    (pure store removal, zero arithmetic change). Evidence:
    `evidence/prefill-triage/hcs1/`.

Not worth pursuing for prefill: wire quantization (+2–4 % ceiling, already
measured), link latency (fully hidden), chunk-size tuning (C1 closed),
instruction-level combine tuning (H1 rejected), routed epilogue/tiling
work (R1a + three prior rejections — the family is streaming-bound),
GDN geometry (G1 captured the available block-parallelism),
exchange-based sharding of the replicated family (S1: bit-exact but
transport-serialized, −35 %).
