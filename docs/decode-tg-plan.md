# Decode / TG experimentation plan

Written 2026-10-07 after the decode audit + online research session (read-only;
no new measurements yet). Scope: token-generation speed for the TP2
tbstream serving pair, Qwen3.8-Flash-Next UD-Q4_K_XL target + shared-Q8 MTP
sidecar, after the prefill campaign closed (see
`evidence/prefill-triage/serve-shapes/SUMMARY.md`). Gufo source citations are
against `512f62b` (deployed lineage); evidence paths are repo-relative and
stay local.

**Status 2026-10-07 (evening) — Phase 2 executed:** D2 implemented, gated and
**rejected** (exact but immaterial; selector dispatch already free — the
baseline shows no capacity sensitivity); its operator-test additions are kept
in the gufo working tree. D1's cost tables were measured
(`evidence/decode-tg/d1-costs/`), and a follow-up matched serving experiment
(`evidence/decode-tg/d1-policy/`) superseded the cost-curve hypothesis: a
forced-width serving sweep shows the optimal width is workload-dependent
(repetitive: monotone to the 7-draft cap at ~78 tok/s; code-shaped: peak at
~w5), and the production adaptive controller is **bimodal per request** —
converged runs beat forced widths (80.8 tok/s), collapsed runs deliver
~AR+ε (45 tok/s), a 15–45% loss on affected requests. **D1's actionable
continuation is draft-width controller stabilization** (EMA/probe/retry
dynamics in `mtp_policy.hpp`), not cost tables or concurrency mapping.

**Status 2026-10-08 (overnight) — stabilization leg closed.** Matched-input
E0 (`evidence/decode-tg/d1-stabilization/`) revised the picture again: the
controller is **deterministic per request** (three passes bit-identical; the
"bimodality" was nonce-level workload variation), sits within ~8% of the
per-request forced-width optimum on hard text and **beats every fixed width
on easy text**; the loss concentrates in cooldown-retry storms (26% of
rounds on hard/tools fixtures). An EMA 0.75→0.85 candidate passed gates but
gained only 0–3.8% per fixture in a 4v4 serving A/B — **rejected** below the
5% bar. Exact offline policy replay is impossible (catch-up vs mid-chain
draft-state numerics differ; acceptance streams are policy-dependent). New
follow-up flagged: **seeded-replay fragility via checkpoint-restored draft
policy** (candidate showed fixed-seed outputs varying across passes). Phase
3 (D3/D4 by workload-share data) is the next decision point.

Everything below is either an established measurement (labeled with its
source), a source-visible mechanism (labeled **unmeasured** — not a claimed
speedup), or a historical precedent. Published speedups from the papers listed
in §7 are datacenter/NVIDIA numbers and are **not** predictions for this
stack.

## 1. Baseline (established)

| Fact | Value | Source |
| --- | --- | --- |
| Constrained TP2 MTP | shipped; tool/schema requests decode speculatively | gufo EXPERIMENTS "Mirrored request constraints"; TODO log 2026-10-07 07:40 |
| Production sampled constrained decode | 49.1 tok/s (496 out, 31 tools, 67.9% acc, `spec:222/constr:0/policy:17`); 60.6 tok/s (3 038 out, 74.0% acc); one 87.1%-acc request with 32 policy-AR calls | `evidence/serve-guardian/20261007-094150/r0-c1.log` |
| Historic tools request | 33.1 → 52.4 tok/s at constraint mirroring | TODO log 2026-10-07 07:40 |
| Qualification-era tbstream MTP | 76.1 tok/s steady, 93% acceptance | gufo EXPERIMENTS TP2-tbstream row |
| Decode alongside active prefill (post `--prefill-chunk 2048`) | 77.6–78.1 tok/s | serve-shapes campaign, 2026-10-07 |
| Single-host published C1 MTP | 59.3 repetitive / 32.1 mixed (Sept 27 cells) | gufo BENCHMARKS.md |
| Server sampling defaults | temperature 1, top-k 20, top-p 0.95 | `src/core/text_sampling_defaults.hpp` |

## 2. Architecture facts relevant to TG (gufo @ 512f62b)

- **Chain MTP only, ≤ 7 drafts** (`src/models/qwen38_flash_next/mtp_policy.hpp:15`).
  Proposals: greedy = raw draft-head argmax; sampled = top-64 candidates from
  the full Q8 head, compact F32 masses summing to exactly 2^24 units
  (`src/models/qwen38_flash_next/mtp_sampling.hpp:16-69`). Target
  verification uses the complete FP64 target distribution with p/q acceptance
  and residual correction (`mtp_sampling.hpp:76-107`).
- **Draft cost policy is TP2-blind.** Fixed curves calibrated 2026-09-20
  single-host (`mtp_costs.hpp:11-18`, reproduce via
  `qwen38_flash_next_gpu_probe --cost-audit`); inputs are context and
  concurrency only. The controller's concurrency initializes from
  **configured** session capacity (`src/cli/serve/inference_backend.cpp:3617`),
  so a lone decoder on the two-session server plans with the C2 curve while
  physically executing C1. The audit that produced the tables measures greedy
  proposal/verify cycles only (`tests/models/qwen38_flash_next/mtp_audit.cpp`).
- **Live timing control is all-greedy C≥2 only.** One sampled member disables
  the shared controller for the batch (`engine.cpp:1100-1105`); a
  one-token-budget member caps the whole cohort's width
  (`engine.cpp:1107-1113`); "same cohort" keys are occupancy + context bin
  only (`mtp_policy.hpp:222-275`). Sampled requests keep deterministic
  fixed-curve policies for seeded replay (QUALITY.md contract).
- **TP2 mirroring carries one scalar width.** `kDecode`/`kDecodeBatch` carry
  budgets + draw state, and the batch carries rank 0's chosen draft count
  (`src/cli/serve/tp_executor.cpp:840-924`, `src/cli/serve/tp_control.hpp`);
  per-member ragged widths would need a protocol extension and a continuation
  identity bump (the stored identity records draft limit + cost concurrency,
  `inference_backend.cpp:367-372`).
- **Drafts are constraint-blind.** `pending->draft_sampler =
  sampler.WithoutConstraint()` (`engine.cpp:784`); proposals are selected
  before penalties/filtering. Verification is exact regardless — this is a
  potential acceptance/efficiency lever, not a correctness gap.
- **Greedy verification keeps winners on GPU** with exact penalties
  (`engine.cpp:840-880`, `kernels/rocm/executor.cpp:3109-3178`); the first
  grammar-forbidden winner downloads the remaining rows once. The legal-argmax
  shortcut deliberately excludes closed JSON schemas to keep masks warm for
  later sampled requests (`src/core/sampling.cpp:231-245`,
  `engine.cpp:857-869`).
- **Sampled verification is full-vocabulary CPU work per member**:
  `SelectBatchLogits` transfers + synchronizes + host-copies each member's
  rows, then distribution/CDF/residual run on CPU FP64
  (`kernels/rocm/batch.cpp:992-1013`, `src/core/sampling.cpp:844-1005`).
- **Batched drafting has intermediate drains**: `MtpForwardBatch` and
  `MtpHeads` each synchronize before returning
  (`kernels/rocm/batch.cpp:376-388,499-510`); completion loops members
  serially (select → verify → rollback → frontier) with per-member
  synchronizations (`engine.cpp:1209-1238`).
- **TP2 disables graphs unconditionally** (`kernels/rocm/executor.cpp:2025-2032`),
  so decode/verification/MTP all run eager. A verification pass performs
  2 × num_layers exchanges (mixer + MoE sums per layer); a draft-body pass
  adds one MoE exchange; head-only passes add none
  (`executor.cpp:2243-2249,2627-2647,3392-3396,3441-3465`).
- **Narrow (1–8-row) selector launches use the context-capacity grid**:
  `live_blocks` is only supplied when `n_tokens > 8`
  (`executor.cpp:1612-1623`); `SelectBlocks` otherwise sizes the grid by
  `max_blocks` (`kernels.hip.cpp:6770-6792`). Excess workgroups return early
  but are still dispatched. The capacity grid exists for graph replay, which
  TP2 never does.
- **Vocabulary heads are replicated on both ranks** (target verification +
  draft heads project the full 248 320-row shared Q8 output:
  `executor.cpp:1991-2023`, `kernels/rocm/batch.cpp:459-489`).
- **MTP is the only proposal source** — the engine's draft loop calls
  `MtpForward` (`engine.cpp:798-805`) and the HTTP/bench layers reject other
  backends for this model (`inference_backend.cpp:3576-3587`). The PLE n-gram
  table is an input embedding (hash rows read for known tokens), **not** a
  speculative prompt-lookup implementation.
- Batch decode calls `Attention()` per session rather than one request-grid
  launch (`batch.cpp:903-923`); narrow all-reduce still launches a separate
  peer-add pass (the fused peer combine refuses < 16 rows:
  `executor.cpp:1687-1695,2463-2477`, `kernels.hip.cpp:5269-5280`).

## 3. Observability gaps (Phase 0 targets)

- `decode_modes` counts **calls**, not tokens or time; acceptance excludes
  no-proposal periods (`src/cli/serve/text_generation_scheduler.cpp:1172-1190`,
  `generation_metrics.hpp`).
- `plan=serial-fallback` can simply mean one active decoder in a multi-session
  pool (`text_generation_scheduler.cpp:2047-2050`) — the retained log shows
  speculative work under that label.
- `SupportedPlans()` still carries an obsolete comment claiming TP2 batched
  MTP advances one token each (`inference_backend.cpp:2590-2592`).
- Missing per-cycle signals: chosen vs executed draft depth, first-rejection
  position, draft-head/body/verify/sampling/rollback/TP-wait phase times,
  transferred logit bytes, catch-up debt, mask-fallback cause. The 87.1%-acc +
  32-policy-AR request shows the current counters cannot attribute cooldown
  profitability.

## 4. Avenues (ranked)

### D1 — TP2-specific draft-cost calibration  (highest priority)

**Mechanism (unmeasured).** TP2 changes the speculation economics: the trunk
and draft MoE are sharded, but draft attention/projections and both vocabulary
heads are replicated, and each cycle pays queued exchanges. The fixed
single-host curves plus the configured-capacity concurrency cannot represent
this; widths may be systematically too deep or too shallow.

**Plan.** Measure complete-cycle costs at widths 0–7 on the pair (greedy and
sampled, d0/d32k, C1/C2, catch-up + verification + sampling + rollback
included) → new deterministic `kMtpCycleMilliseconds` profile for TP2; fix the
concurrency initialization to physical occupancy; consider a cheap
expert-union/depth signal for the greedy batch controller. Keep sampled
policies deterministic (fixed table) to preserve seeded replay; version the
cost-profile identity in continuations.

**Context.** EVICT/EcoSpec/the "Limits of Speculation" analysis all find MoE
verification cost is token- and routing-dependent and the optimal rule is
marginal-cost vs expected-accepted (§7). Warning: EVICT's own eager-mode
ablation **inverted** its gain — CPU-side control cost can eat GPU savings.
TP2 here is permanently eager, so controllers must stay O(small) per cycle.

### D2 — Live-range selector grids for eager narrow decode (exact, small)

**Mechanism (unmeasured).** For 1–8-row launches, pass the live block count
(instead of capacity `max_blocks`) when running eager under TP2. Removes
empty-but-dispatched workgroups; scores/ranking/arithmetic unchanged
(`executor.cpp:1612-1623`, `kernels.hip.cpp:6780-6784` already support a
`live_blocks` argument). Single-host graph paths keep the capacity grid.

**Control that isolates it:** identical live history, different configured
context capacities.

### D3 — Grammar/penalty-aware draft proposals (acceptance lever)

**Mechanism (unmeasured).** Drafts currently ignore the constraint and
penalties; on tool-heavy traffic many proposals are grammatically dead on
arrival. Candidates: (a) greedy drafting selects a request-penalized,
grammar-legal winner (exact `Allows` check on the tentative state); (b) sampled
drafting filters the top-64 support to legal/penalized-competitive tokens and
exports that **actual q** (exact discrete-mass invariant preserved). Target
p, rejection sampling and residual correction stay untouched, so the output
distribution is preserved by construction; only proposal efficiency changes.

**Constraints.** Greedy seeded replay across builds will change (documented,
not a quality regression); sampled replay must hold within a build. Advance
tentative grammar only over legal tentative tokens; handle empty legal support.
Grammar masks in gufo are CPU-side — VeloSpec-style fused GPU mask/argmax
kernels do not map directly; the mask-density → draft-budget signal does.
No retained experiment rejects this.

### D4 — Exact compact target verification (sampling-path)

**Mechanism (unmeasured).** Two focused moves, both exact:

1. **GPU top-k for bounded-top-k requests** (server default top-k = 20):
   select candidates on GPU **after** exact penalties and grammar masking,
   transfer compact ids/logits, keep canonical FP64 filtering/CDF/acceptance
   on CPU. Preserves token-ID tie order and `min_keep`. Not valid for
   `top_k=0` (full-mass contract for top-p/residual).
2. **Extend the legal-argmax shortcut to closed JSON schemas**
   (`sampling.cpp:231-245`): a legal maximum under the same penalty/tie rules
   is the masked maximum; weigh the loss of mask warming for later sampled
   requests. Narrow side-case: temperature>0/top-k=1 is deterministic but
   currently takes the sampled path (`sampling.cpp:223-225,311-317`).

**Context.** SonicSampler (bounded top-128, "effectively lossless" only
empirically; BF16 ordering) and FlashSampling (exact Gumbel-max fused into
the head; changes the RNG sequence → not seeded-replay compatible as-is)
support the direction without being drop-ins. The grouped TP variant of
FlashSampling is the relevant template if D5/vocab sharding is ever taken.

### D5 — Draft-head frequency-ranked row subset (qualified revisit)

Restrict only the **draft** head to a frequency-ranked subset of the existing
Q8 rows (descriptor view, no second weight copy); target verification stays
full-vocabulary. FR-Spec (ACL 2025) reports ~12% over EAGLE-2 in their
setting with unchanged output-distribution equivalence.

**Historical record (must be cited in any experiment):** gufo already had
(a) `--draft-vocab` prefix-64K row view — added `34a8fff` ("graph-replayed
decode, FR-Spec draft head…", bundled 38 vs 22 tok/s), removed in `bd96a89`
(#235 bundle); (b) a private Q4 shortlist + Q8 rescoring — `bcf0b34`
(bundled 44.73→47.10), Q4_0 shrink `72291a8`, removed in `bc4c4a5` (bundled
with predictor-math fixes). **No isolated TP2 benchmark rejected either**;
the removals were bundled. The genuinely untried variant is a
corpus-frequency-ranked, noncontiguous subset (both prior versions used
token-ID-prefix or requantized copies). A current same-model community Strix
Halo project runs Q5 draft + 65k vocabulary on a different backend/stack —
supporting evidence only. Acceptance impact must be measured; QUALITY.md
already disclaims upstream draft-sampler equivalence.

### D6 — Coalesce batch completion boundaries (C2+ relevance)

One drain for body+head submission; gather sampled logit ranges into one
transfer phase; enqueue independent rollback/frontier copies with a single
final drain. Keep per-request private frontier/grammar/RNG state and row
ownership before the next shared head overwrites scratch
(`batch.cpp:376-510`, `engine.cpp:1170-1238`). Historical precedent: one-host
graph capture of shared decode stages was rejected; this is drain-count
reduction, not graphs.

### D7 — Narrow peer-add/HC-combine fusion

A decode-specific sibling of the retained paired-prefill peer fusion (which
refuses < 16 rows) would remove one add launch/pass per all-reduce — not the
exchange or peer wait. Preserve per-stream parallelism and reduction order;
do not repeat the rejected constant-width Vec4 retune.

### D8 — Suffix/prompt-lookup drafting as a second proposal source

Exact, training-free, CPU-side (~20 µs/token reported): per-request (+
optionally cross-request) suffix tree over prompt + prior outputs proposes
copied continuations; verify with the existing exact target path; fall back
to MTP when match score is weak (SuffixDecoding's τ-hybrid rule). Best case
is our file-rewrite/agent-loop shapes, where the model re-emits known text.
Engineering: new proposal backend alongside MTP (currently rejected at
`inference_backend.cpp:3576-3587`), chain length still capped by
`max_speculative`/rollback reserve, recurrent-state rollback unchanged.
Gate on Phase-1 workload data showing repetitive-output share.

### D9 — Parallel block-diffusion drafter (DFlash-class)

Architectural: needs a trained drafter for this target (none published for
Flash-Next), KV-injection plumbing, and a new integration. Out of near-term
scope; re-evaluate only if checkpoint availability changes (§7).

**Small bounded items:** final-token selection-only path for MTP tails
(`inference_backend.cpp:2583-2592` vs `tp_executor.cpp:848-856` — one target
forward per finishing request); admission-grammar cache sizing/isolation
(16-entry schema caches, 4 runner bindings — TTFT and decode stalls during
admissions, `src/core/json_constraint.cpp:1685-2428`).

## 5. Historical precedents — do not re-litigate

| Precedent | Implication for this plan |
| --- | --- |
| Vocabulary rows/block enlargement; wider Q8/Q5 decode tiles (rejected ×2) | D5 is row-subset selection, not another retile |
| Persistent packed SSM weights (−14% @ 8-row decode) | any weight-format change must qualify every decode consumer |
| Captured shared decode stages; side-stream overlap; graphs on one host (~1%) | D6 must be drain/launch reduction, not capture |
| One-byte KV pilot (drift 5–10× TP2 noise, decode ≤0.75%) | closed; no KV quantization |
| Greedy batch cost controller scope; six/three fixed drafts (27B) | adaptive width helps only with correct costs → D1 |
| Routed epilogue dead-tile skipping (−2.45% e2e) | runtime bounds on unrolled loops can perturb scheduling — D2 must keep grid math trivial |
| Approx selector screening; shared selection lists; query sharing | D2 is launch-bounds only, never selection changes |

## 6. Campaign plan (measurement-first)

1. **Phase 0 — instrumentation (code, small).** Additive completion-log
   fields: tokens/time per decode-mode, chosen vs executed width,
   first-rejection position, per-phase timers (draft head / draft body /
   target verify / sampling / rollback / TP wait), transferred logit bytes.
   Fix the `SupportedPlans` comment and the `serial-fallback` label trap.
   Unit/toy tests only.
2. **Phase 1 — baseline matrix (diag pair, prod-lineage binary).**
   {prose, code-ish, tools-constrained greedy, tools-constrained sampled,
   repetitive control} × {C1, C2} × {d0, d32k}. Deliverables: attribution
   table (wall-time share per phase), measured TP2 cycle-cost table (D1
   input), workload repetition statistics (D8 gate). No code changes.
3. **Phase 2 — exact small wins.** D2 (selector live-range, TP2-eager only)
   and D1 (cost table + concurrency init). Gates: pool/hosted suites, paired
   A/B canary-clean interleaved pairs, member checksums canonical on both
   ranks.
4. **Phase 3 — data-chosen.** Exactly one of D3/D4/D5, chosen by Phase-1
   shares (constraint rejection rate → D3; sampling+transfer share → D4;
   draft-head share → D5). Each carries its §4 exactness gates.
5. **Phase 4 — gated larger work.** D8 if repetition share justifies; D6/D7
   if C2 traffic matters; D9 evaluation only.
6. **Every retained change:** EXPERIMENTS.md row (+BENCHMARKS/QUALITY as
   applicable), paired A/B evidence, guardian deploy with canary.

**Test matrix for exactness-affecting changes (D3/D4/D5/D8):** seeded
sampled replay within a build; greedy replay documented as build-dependent
when q changes; rollback-prefix checks 1..7 at odd tails (1/8/9/32/33);
`tests/functional/tp2_constraints.py` 9/9 on a fresh pair; session sampling
suite via hosted build (devshell GLIBC skew is documented environmental);
`--cost-audit` re-run when D1 lands; TP2 toy-pair grammar/refusal tests.

## 7. Research references (mechanisms borrowed, numbers not transferable)

| Work | Setting | What we borrow | Caveat |
| --- | --- | --- | --- |
| EVICT (arXiv:2605.00342) | A100, SGLang, EAGLE-3 trees | cost-aware verification-width utility rule for D1 | gain inverted in eager mode; tree/pruning machinery N/A for chains |
| EcoSpec (arXiv:2607.12696) | H200-class, DeepSeek/Qwen/GPT-OSS | marginal expert-activation cost in draft selection | needs drafter-side expert prediction we lack |
| MoE-Spec (arXiv:2602.16052) | — | expert-budget concept | **lossy** (truncation/substitution) — excluded |
| Limits of Speculation (arXiv:2609.22156) | Qwen3-Coder + EAGLE-3 | marginal-cost/expected-progress threshold rule | oracle study, not a runtime |
| SuffixDecoding (NeurIPS 2025; vLLM suffix) | production agents | suffix-tree proposer + τ-hybrid fallback for D8 | CPU-side proposer fits our CPU grammar side |
| FR-Spec (ACL 2025, thunlp/FR-Spec) | Llama-3/Qwen2, native CUDA | frequency-ranked draft-only vocab subset for D5 | our prior removals are unattributed bundles (§4 D5) |
| SonicSampler (arXiv:2607.20475) | B200, Triton, BF16 | tiled fused mask/penalty/top-k + verification kernels for D4 | bounded top-128 only empirically lossless; BF16 ≠ our FP32/FP64 exactness |
| FlashSampling (arXiv:2603.15854) | H100–B300, vLLM | exact argmax-decomposes-over-tiles fusion; grouped TP head variant | Gumbel-max changes RNG sequence (seeded-replay break); logits-tile P2P assumes NVLink-class fabric |
| VeloSpec (github shiloz-stack/VeloSpec) | A100, Qwen3.5 4B/0.8B | grammar-guided draft + mask-density→K budget for D3 | small standalone project; fused GPU masks assume XGrammar-style GPU masks |
| AdaptiveSpec (arXiv:2609.02897); Cactus; ResiSpec; LinguaSpec | various | — | **lossy** acceptance/verification relaxation — excluded by policy |
| DFlash/DFlash2 (arXiv:2602.06036, z-lab) | H200/B200, SGLang/vLLM | block-diffusion drafting concept (D9) | no Flash-Next checkpoint; training required |
| drluoto/flash-next-strix-halo | same model, Strix Halo, Vulkan llama.cpp | community evidence for Q5 + 65k draft vocab (D5) | different engine/backend/quant; its ROCm-wrong-logits claim contradicts our healthy ROCm stack |
| vLLM/SGLang hybrid+MTP internals | docs | GDN spec conv-state sizing (`num_spec` in conv shape), eager fallback precedents | reference only |

## 8. Non-goals

- Two-replica / data-parallel serving (out of scope by directive; TP2 only).
- Lossy speculative acceptance or verification relaxation (Cactus,
  AdaptiveSpec margins, MoE-Spec budgets, deferred/relaxed verification).
- Tree-structured speculation: parked. Per-branch recurrent GDN state +
  eager TP2 mirroring + EVICT's eager-mode warning make it a poor fit until
  D1 data says otherwise.
- KV-cache quantization (closed 2026-10-06), graph capture on TP2 (host-driven
  collectives), and any retune family with a negative precedent (§5).
