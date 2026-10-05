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

1. **Restore the fused MoE-epilogue-into-combine under TP2** by exchanging
   the routed intermediates (`down_e`, halved expert width, F16) instead of
   the final F32 MoE output. The epilogue is linear in the expert outputs
   and both ranks hold identical routing weights, so the sum commutes —
   but the rounding changes, so `--split` invariance and the quality gates
   must be re-run. Expected: kill `MoeEpilogue` (546 ms), shrink
   `AddRows` (631→~410 ms), and replace ~800 unfused Vec4 combines with
   fused ones — roughly −1.5…−1.9 s/rank at 32 k, i.e. **dual prefill
   ~2.3–2.4 k tok/s**.
2. **Split the replicated dense/W8A8/mix family** (hyperconnection and
   indexer projections): up to ~1.2 s/rank more → ~2.6 k tok/s. Larger
   blast radius (numerical contracts per shape).
3. Kernel-level prefill speedups help single and dual equally; they are the
   only route to 3 k tok/s on this partition — the two fixes above alone
   plateau near 2.6 k because ~35 % of the per-rank time is still replicated
   or overhead work.

Not worth pursuing for prefill: wire quantization (already measured +2–4 %
ceiling), link latency (fully hidden), chunk-size tuning at depth (exchange
count is per-layer, not per-chunk, and the 20 MiB frames already amortize
framing).
