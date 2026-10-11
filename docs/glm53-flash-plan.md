# GLM-5.3-Flash on the pair — first-leg plan (reference)

Status: P4 COMPLETE (2026-10-09); P5 IN PROGRESS — the prefill-speed
detour closed 2026-10-10 (goal 2026-10-10-glm-prefill-250: serving
prefill 35.1 → 84.4 tok/s) and its continuation, the vLLM-port campaign
(goal 2026-10-10-glm-prefill-250-vllm), closed 2026-10-11 at **115.0
tok/s** serving-level (chunk 4096, ~3.4K cold prompts; 105.9 @ 5.9K,
86.7 @ 15.9K vs the vLLM 278–294 band) after weight-stationary rewrites
of the three mover families plus a bit-identical split-launch sparse MLA
— the ≥ 250 objective is closed NOT MET on a measured roofline (the
expert family is register-bound, the Q8_0 family at ~99 % of its DRAM
ceiling; both at their floors leave ≈ 183 tok/s), with the final
per-family roofline and ranked residual ceilings in the goal worktree's
`notes/final-ws-250.md` and evidence in
`evidence/glm53-flash/p7v/`; 32K-deep prefill exercised at 47.2 tok/s
(pre-ws) and 62.0 tok/s (ws kernels, probe); the
4K→128K→256K ladder itself still pending; P6 records accumulating
(`docs/models/glm-5.3-flash/README.md` carries the measured throughput
and method). Owner: agent sessions + user.
Scope of this document: the full first leg — bring GLM-5.3-Flash up as a
second model on the two-host TP2/tbstream pair, correctness first, and
qualify genuinely exercised 256K context. Optimization (MTP, kernel work)
is out of scope until the AR baseline is recorded.

Operational rules from `AGENTS.md` (both repos) apply unchanged: production
Qwen serving stays live except during announced maintenance blocks; the
gufo upstream is never pushed; the public mirror never receives hostnames,
addresses, machine identifiers or credentials; pair experiments use the
hardened start/stop harness and restore production afterward.

## 0. Objective and definition of done

**Goal:** correct text/code/tools serving of GLM-5.3-Flash on the TP2 pair
with one active session and a qualified 256K (262,144-token) context,
ending in a measured autoregressive baseline.

Done means all of:

- A runnable TP2 GLM server (Chat + Responses, buffered and streaming).
- Text, code and native tool calls exercised by a real coding agent with
  independently verified tool results.
- Actually-tested near-full 256K prompts (with room for output), covering
  early/middle/late recall, continuation, cancellation and memory stability.
- Independent numerical evidence (operator references + fixed-token logit
  references), reproducible execution (rank lockstep, seeded replay).
- Bounded, measured loading/cache/runtime memory inside the qualified envelope.
- Recorded baseline: load time, memory peaks, cold-prefill latency, decode
  vs depth, warm continuation cost.

No speed gate. Performance work is the next leg.

## 1. Model facts (pinned)

Source of record: official `zai-org/GLM-5.3-Flash-BF16` `config.json` +
`chat_template.jinja`, llama.cpp `src/models/glm5-next.cpp` +
`src/llama-memory-hybrid-idx.cpp`, transformers
`modeling_glm5_next.py` (revisions pinned in the artifact manifest).

- 320B total / ~18B active; 45 trunk layers + 1 NextN (MTP) block.
  MTP block 45 is **skipped** in the first leg (AR only).
- Hybrid trunk: 34 KDA linear-attention layers + 11 DSA sparse-MLA layers
  (indices 3,7,11,...,43). Hidden 4096, vocab 154,880, native context
  1,048,576. mHC: 4 streams, Sinkhorn 20 iterations, eps 1e-6; final head
  is an **unweighted mean** over streams.
- KDA: 64 heads x 128, per-(head,dim) channel decay, short conv kernel 4,
  forget gate lower bound -5 (sigmoid form), FP32 recurrent state.
- DSA/MLA: kv_lora_rank 512, q_lora_rank 1536, 64 heads, qk_nope_head_dim
  256, v_head_dim 256, **RoPE dimension 0** (nope-only); attention scale
  stays 1/sqrt(256). wk_b absorbed into queries; cache retains only the
  normalized 512-wide latent per token/layer; wv_b applied after attention.
- Indexer: 32 heads x 128, learned 4-token k-pool compression (gate + APE),
  topk 2048 original tokens = 512 pools, incomplete tail always selected
  (3 tokens), shared across the layer quad via `prev_sel`.
- MoE: first 3 layers dense (FFN 12288); remaining 42 layers: 288 routed
  experts, top-8, 1 shared expert, expert FFN 2048; sigmoid gating with
  noaux_tc bias correction, normalized top-k, routed scaling 2.5,
  SwiGLU clamp 10.
- Template: `[gMASK]<sop>` framing, `<|system|>/<|user|>/<|assistant|>/<|observation|>`;
  reasoning effort low/high/max (default max) via a leading system line;
  thinking always opens with `<think>`; tool calls are native XML
  `<tool_call>name<arg_key>k</arg_key><arg_value>v</arg_value>...</tool_call>`;
  tool results wrapped in `<tool_response>` under `<|observation|>`.
  EOS ids: 154820, 154827, 154829.

## 2. Artifacts

| Artifact | Pin |
| --- | --- |
| Primary checkpoint | SixVolts `GLM-5.3-Flash-Q4_K_XL` (5 shards, 186,523,559,232 B = 173.714 GiB), repo revision `f9dd17e251f5e685770f532596f0e575b0f60109`; per-file sha256 recorded at download time |
| Alternate (later gate) | Unsloth UD-Q4_K_XL, HF revision `a38483c8cd5df544f53d70fb281afe97369d5ab6` |
| Official config/template/tokenizer | `zai-org/GLM-5.3-Flash-BF16` (BF16 repo, for reference equations and template goldens) |
| llama.cpp reference | master `src/models/glm5-next.cpp`, `src/llama-memory-hybrid-idx.cpp` |
| transformers reference | `main` `modeling_glm5_next.py` |

Primary-quant rationale: Q4_K routed experts + Q8_0/F32 elsewhere gives the
simplest kernel bring-up and the most memory headroom; quality vs Unsloth
is qualified by us, not assumed. Q6_K tensors (present in Unsloth, absent
here) are unsupported by current production kernels — the loader rejects
them explicitly.

## 3. Memory budget and capacity plan

Per-host physical reality: ~122.7 GiB RAM, GTT limit 120 GiB backed by the
same RAM. Planning ceiling for the runtime: **108 GiB** until measured.

| Component (per rank) | SixVolts Q4_K_XL |
| --- | ---: |
| Ideal AR weight share (TP2, MTP skipped) | ~84.8 GiB |
| Compact latent+indexer cache @256K, F16 | 2.92 GiB (F32: 5.84) |
| Head-sharded KDA FP32 recurrent state | ~68 MiB |
| Replication excess + scratch + staging + runtime | measured in P0/P3 |

Cache is stored **compacted**: only the normalized 512-wide MLA latent per
token/layer (aliased K/V) plus pooled/complete indexer keys and the small
pooling frontier. Expanded per-head KV (~88 GiB/rank at 256K) is a
non-goal. The latent/indexer cache is replicated per rank; query/value head
split 64→32 per rank governs compute, not cache bytes.

Context ladder: 4K → 32K → 128K → 262,144 (prompt + reserved output).
512K/1M capacity gates and on-demand slab allocation are follow-ups after
256K qualifies; CPU offload adds no capacity on this UMA node.

Snapshot policy for leg 1: **one mutable active continuation** per session,
live-state prefix reuse only, no immutable full-prefix copies. Edits that
diverge from executed history rebuild explicitly. Bounded/immutable
snapshots are a later cache phase.

## 4. Work packages

### P0 — Artifact + memory contract (in progress)

- [x] Plan recorded (this file).
- [x] Header capture of all 5 shards (ranged HTTP; no weight download):
      metadata keys, tensor names/types/dims per shard
      (`evidence/glm53-flash/headers/`, `P0-INVENTORY.md`).
- [x] P0 ledger: per-tensor ownership classes, real names (which differ
      from llama.cpp's mapping in places), shard byte sums cross-checked
      against file sizes. **AR weights 169.650 GiB full → 85.909 GiB per
      rank at TP2; nextn block 4.055 GiB excluded.** Per-rank subtotal at
      256K with F16 cache and KDA state: ~88.9 GiB vs the 108 GiB ceiling.
- [x] gufo package `src/models/glm5_next/`: `Config::FromGguf`,
      `ModelWeights::Bind`, `distributed/tp_plan` ledger with block-boundary
      validation; tests `glm5_next.config` + `glm5_next.tp_plan` green;
      `glm5_next_inventory_probe` ready for the downloaded artifact.
      Format check clean; full cpu-test suite unchanged (one pre-existing
      unrelated failure: `tp_instruction_latency_test`).
- [ ] Full checkpoint downloaded (rate-limited background job, ~80 MB/s
      cap), sha256-verified against the pinned oids, manifest in
      `evidence/glm53-flash/download/MANIFEST.txt`; then run the inventory
      probe and cross-check it against the header census.
      Gate: nothing in P1+ needs the weights on both hosts until P3.

**Gate P0:** every required tensor has a supported route and the
load+runtime plan fits the 108 GiB ceiling with headroom.

### P1 — Independent reference + tokenizer/template (in progress)

- [x] CPU reference (`src/models/glm5_next/reference.cpp`, model-private):
      mHC with Sinkhorn + unweighted head mean; KDA channel decay, conv
      history, FLA l2 norm, absorbed-layout MLA (scores as k_b-absorbed
      dots against cached latents, v_b expanding the probability-weighted
      latent — the same cache-content contract the engine will use);
      k-pool indexer with signed head weighting and always-selected tail;
      sigmoid/noaux_tc routing with normalized top-k, scaling and clamped
      SwiGLU; on-the-fly dequant of F32/F16/BF16/Q8_0/Q4_K. Structural
      test green: chunked-vs-tokenwise exact equivalence at four split
      points, per-step capture equality, deterministic replay, selection
      sanity (pool + tail composition, current token always selected).
- [x] Tokenizer: `glm4` pre-tokenizer mode in the shared tokenizer
      (digits group 1–3, no NFC; Qwen keeps single digits + NFC — both
      pinned by hosted tests). Vocabulary id alignment verified against
      the official tokenizer.json: all 154,856 tokens identical, 321,649
      merges identical, specials at the right ids ([gMASK] 154822,
      <sop> 154824, <|user|> 154827, <|assistant|> 154828,
      <|observation|> 154829, eos 154820); 24 [PAD…] alignment tokens
      beyond. Official-tokenizer goldens generated for 21 probes
      (`evidence/glm53-flash/tokenizer-goldens.json`); end-to-end golden
      encode via `glm5_next_tokenizer_probe` runs once all shards are on
      disk (the split GGUF carries the full tensor table in every shard,
      so the reader needs all five).
- [x] Template goldens + compiled renderer: the official template is
      rendered by jinja into 23 goldens covering efforts, reasoning
      preserve/clear/inline, tool blocks, call serialization (string and
      JSON-embedded values) and observation runs (id-sorted, unsorted and
      duplicate-id fallbacks) —
      `evidence/glm53-flash/template-goldens.json`, template pinned at
      sha256 `0c4099f3…09c5c5`. `src/models/glm5_next/chat_template.{hpp,
      cpp}` implements the compiled renderer (byte-exact against 12
      structural golden cases in the hosted test) plus
      `ValidateGgufTemplate` sha pinning. The GGUF also carries
      `tokenizer.ggml.token_type` marking exactly the 36 control tokens;
      the shared tokenizer now honors CONTROL/USER_DEFINED entries, so
      `[gMASK]`/`<sop>` and friends tokenize as single specials.
- [x] Numerical contracts validated on real weights. Debugging trail:
      the scalar reference initially produced garbage; a numpy oracle
      (layer 0, F32/Q8_0 only — `reference/oracle-layer0.py`) plus a
      llama.cpp CPU build (no-repack) as ground truth localized the bug
      to the KDA FLA l2 norm (per-element instead of per-vector). With
      that fixed, the reference reproduces llama.cpp's behavior on the
      same artifact: "The capital of France is" → ' Paris' top-1 at
      p≈0.53 (llama.cpp: ≈0.51), sharp distributions everywhere
      (`reference/capital-france.out`). Along the way, verified against
      ground truth: conv tap order and layout, mHC Sinkhorn algebra,
      MoE router/clamped SwiGLU, MLA absorbed-k_b scores with scale
      1/sqrt(256), v_b as the plain post-attention projection, and the
      decay-gate convention bound·sigmoid(−a·raw) with a=−exp(A_log).
      Trace capture per layer/sub-block added for P2 qualification.
      Reference dequant covers F32/F16/BF16/Q8_0/Q4_K/Q5_K/Q6_K.

**Gate P1 reached:** reference logits behave like the trained model on
real weights; tokenizer/template goldens pass; operator conventions are
pinned by two independent oracles.

**Gate P1:** reference logits for fixed short prompts; tokenizer/template
goldens pass; operator tolerances frozen.

### P2 — Operators on a real-weight slice (layers 0–3)

Three KDA/dense layers + one DSA/MoE layer on one host, eager kernels,
actual quantized weights. Slice ledger: **6.175 GiB encoded** (incl. all
288 experts of layer 3), 12 MiB KDA FP32 state, ~0.84 MiB conv history;
DSA latent cache 8 MiB + pooled keys 0.5 MiB per 4K tokens (FP32).

Oracle repair before any GPU work (2026-10-08): the reference's indexer
key LayerNorm omitted the mean subtraction (`w*(x*inv)+b` instead of
`w*((x-mean)*inv)+b`); short prompts could not expose it because every
complete pool is selected below the 512-pool budget. Fixed via the
exported `IndexerLayerNorm` helper with a nonzero-mean hosted fixture;
Paris re-validated (' Paris' top-1 p=0.526). The reference now also
provides the **four-layer boundary** (`layer_limit` → truncated logits +
pre-head collapsed readout) and **deep operator diagnostics** (mHC
pre/post/comb, KDA conv/gate/qn/kn, DSA latent/q_abs/pooled/scores,
router probs/experts/weights) dumped by `glm5_next_reference_probe
--deep --trace --layers 4`. Fixtures pinned under
`evidence/glm53-flash/p2/fixtures/` (5 tokens, [gMASK]-framed prompt).

Note: the artifact's `indexer.types` are all `full` — every DSA layer
computes its own selection; the shared-`prev_sel` path is not exercised
by this checkpoint.

**Frozen numerical limits (GPU vs CPU oracle; tighten only, never
loosen):**

| Operator | Limit |
| --- | --- |
| Quantized/F32 projections (K = hidden or lora) | rel RMS ≤ 5e-5, max |Δ|/scale ≤ 1e-4 |
| RMSNorm/LayerNorm/Sinkhorn outputs | max abs Δ ≤ 1e-6 |
| KDA conv + l2 norm rows | rel RMS ≤ 5e-5 |
| KDA recurrent state after ≤ 512 tokens | rel RMS ≤ 2e-5 |
| Indexer pooled keys / scores | pooled rel RMS ≤ 5e-5; scores max abs Δ ≤ 1e-5 |
| Selected pool IDs / expert IDs / expert sets | exact match |
| Attention output (per layer) | rel RMS ≤ 5e-5 |
| Block outputs and collapsed readout | rel RMS ≤ 5e-5 |
| Truncated slice logits (vs CPU, same boundary) | top-1 match on fixed probes; rel RMS ≤ 2e-4 |
| Chunked GPU vs tokenwise GPU | identical bytes (state-owner arithmetic must not depend on chunking) |

Contracts:

- MLA: absorbed-W_KB queries over 512-wide latents, scale 1/sqrt(256),
  W_VB after attention; F32-sensitive tensors keep F32 (no inherited
  F16-narrowing shortcuts from the Qwen uploader).
- IndexPool: complete-pool selection with native signed head weights;
  512 pools x 4 tokens + visible tail; pooling-frontier caching across
  chunks.
- KDA: channel-wise decay axis, FP32 state, conv frontier ownership.
- mHC: GLM normalization/scaling/bias order; Sinkhorn iteration order;
  final unweighted mean.
- MoE: corrected-score selection, native weighting, clamp.

Phases: P2.1 device slice upload + ledger probe → P2.2 projections +
mHC → P2.3 KDA → P2.4 indexer + latent MLA → P2.5 dense FFN + MoE →
P2.6 integrated slice executor. Tests: awkward lengths (1/8/9/32/33),
pooling boundaries (offsets 0–3 mod 4), the 2052-token first-pruning
boundary, dirty tails, chunk splits; captured-intermediate comparison
against the P1 reference fixtures. **COMPLETE 2026-10-09** — all
phases qualified on real weights (see the log).

**Gate P2:** slice logits match reference within contract across
chunkings.

### P3 — Full TP2 engine

- Partitioner + bounded loader (final layouts, per-rank resident ledger)
  wired to the existing `Communicator` (scopes, ordinals, deadlines).
- Eager layer schedule; MoE/attention/FFN partial reductions before mHC
  updates. Prefill chunk 512 initially (512x4096 FP32 partial = 8 MiB,
  inside the 32 MiB window). Both ranks on one chunk/collective schedule.
- Probe: fixed-token logits, selected expert/pool ids, resident + peak
  memory per rank, rank agreement, first-differing operator on mismatch.

**Gate P3:** full checkpoint loads on both hosts; reference-qualified
short-context generation; lockstep across restarts and chunk boundaries.

### P4 — Serving integration + native tools (complete 2026-10-09)

- `GlmTextRunner` (runner/pool/scheduler/continuation-cache interfaces);
  `glm5-next` dispatch in `InferenceBackend::load` incl. TP2 admission;
  GLM sampling defaults; reasoning-effort mapping (low/high/max).
- `JsonConstraint::ToolFormat::kGlm`: grammar + renderer + streaming parser
  + TP2 recipe rebuild agree on `<tool_call>/<arg_key>/<arg_value>`.
- Qualification: auto/required/named tools; scalar/nested/literal-XML args;
  multi-call + result pairing; reasoning/content split; buffered+streamed;
  EOS/stop/limit/cancel.

**Gate P4:** a real coding agent completes a bounded read→edit→test→report
task with correctly typed arguments and clean API output.

**Reached:** 18/18 short-context API cases on the actual TP2 pair, plus a
real OpenCode read/edit/test/report loop with independently verified tool
results. Serving is one active session at 4096-token capacity with F32 wire
and 512-wide prefill. The 262,144-token runtime ceiling remains a capacity
limit awaiting P5's exercised-context qualification.

### P5 — Continuation + 256K qualification

- Cache: compact append-only resident cache behind a slab-ready interface;
  one mutable active continuation; live prefix reuse; explicit rebuild on
  divergence; TP-coordinated cancel/invalidate; cache metrics report
  reused vs recomputed work. Tool/reasoning replay measured with real
  client histories (structured re-render can change token history).
- Ladder 4K→32K→128K→262,144 (incl. output reserve): recall
  early/middle/late, code-reference tasks, append-preserving multi-turn,
  prefill+decode cancellation then next request, context exhaustion,
  repeated requests, memory stability; independent sparse-attention/
  indexer checks on captured deep-context inputs.

**Gate P5:** near-full-context requests correct; continuation measured;
peaks inside the envelope.

### P6 — Baseline closeout

- Records: `docs/models/glm-5.3-flash/{README,QUALITY,BENCHMARKS,TP2}.md`
  in gufo; evidence under `evidence/glm53-flash/`; binary/manifest hashes
  in the local handover (private, never published).
- Matrix: format check, CPU contract suite, GLM unit tests, affected
  shared parser/grammar/TP regressions; Qwen-pair control for any shared
  change; standard speed benchmark + numerical quality tests.
- Ops: hardened pair harness (verify binaries/processes both hosts, gate
  inference on successful startup, both rank logs captured, exchange
  deadlines respected, production restored before analysis).

## 5. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Heavy disk I/O wedges the production pair (prior NVMe incident) | Rate-limited background download; no pair experiments during heavy I/O; maintenance blocks for any dual-host work |
| Metadata/tensor-name drift between llama.cpp naming and the artifact | Header dump is authoritative for binding; llama.cpp only supplies semantics |
| Q4_K/Q5_K/Q6_K kernel coverage gaps | Primary artifact avoids Q6_K; unsupported types fail loudly at load |
| FP32-sensitive tensors silently narrowed | Explicit per-type contract in the loader; slice tests catch it |
| Long-context prefill scratch exceeds budget | Chunk 512 start; peak-memory census in P3 probe before any raise |
| Continuation semantics differ from Qwen assumptions | P5 measures real client histories; rebuild-on-divergence default |
| Cache-precision drift | F16 cache is a gate, not an assumption; F32 fallback budgeted |

## 6. Records and file layout

- Plan (this file): `docs/glm53-flash-plan.md` (public-mirror-safe).
- Evidence (gitignored): `evidence/glm53-flash/` — header dumps, P0 ledger,
  download manifest, later run logs.
- gufo (local branch, never pushed upstream): `src/models/glm5_next/`,
  `tests/models/glm5_next/`, `docs/models/glm-5.3-flash/`.
- Private ops (never published): local handover file.

## Log

- 2026-10-09 (P4 COMPLETE): GlmTextRunner, glm5-next HTTP dispatch and
  TP2 control integration landed. One mutable active continuation, bounded
  chunk scheduling, measured session claims, exact incremental decoding,
  developer-message conversion, prefix validation and failed-state reuse
  rejection; partition/reducer/control admission checked before serving.
  Omitted context selects 4096, while the 262,144 ceiling is described as
  capacity rather than a completed long-context qualification. The official
  BF16 model-card reference pins the preset at temperature 1/top-p 0.95.
  GLM effort mapping and explicit thinking-off rejection are wired.
  kGlm grammar/recipe/parser use native arg_key/arg_value framing; whitespace
  in strings and delimiter spellings inside nested JSON survive unchanged.
  Shared grammar semantics bumped to 3; both ranks run an identical packaged
  candidate. The initial runner test mistakenly tried the full TP1 model
  on one qualification host and failed allocation; qualification was moved
  to the actual pair and the loader now checks the resident plan before
  upload. The known dev-shell GLIBC skew was avoided with the packaged
  tp2-tbstream build. A real cancellation bug was caught: a following
  admission timed out at 30 seconds while rank 1 completed a 45-second
  prefill unit, poisoning the pair. GLM now chooses a bounded 180-second
  broker window; other providers retain their existing default. The broker
  also retains the pending object across unlocked waits, avoiding iterator
  invalidation when another request registers. CPU deadline/recipe/parser
  regressions PASS. Final candidate: all 18 API cases PASS (Chat/Responses,
  streamed and buffered, auto/required/named/parallel/zero-argument tools,
  typed/nested/literal args, results, structured output, stops/limits,
  overflow/off rejection, continuation and immediate cancel recovery).
  A raw continuation reused 13/19 prompt tokens; prefill-cancel recovery
  took 46.9s with the in-flight chunk finishing, decode-cancel recovery 2.7s.
  Real OpenCode + concise filesystem/test MCP fixture PASS in 195.5s:
  read source, change subtraction to addition, execute Python assertions,
  accurately report ok; independent negative/zero/positive checks PASS.
  The first built-in-tool agent attempt was retained as a failed fixture
  run (inherited wrong cwd, large replay cost and timeout). Histories that
  re-render differently still rebuild honestly; P5 characterizes that cost.
  Two-session Qwen TP2 AR constraint control 9/9 PASS. Production restored,
  /ready 200. Evidence: evidence/glm53-flash/p4/ (both candidate builds,
  both rank logs, api-final/report.json, agent-mcp/, qwen-control/).
  Next: P5 continuation and exercised 32K/128K/256K ladder, then P6 baseline.

- 2026-10-08 (P2 start): oracle repair + qualification scaffolding. Found
  and fixed the indexer key LayerNorm missing mean subtraction (invisible
  to short prompts: all pools selected below budget); added a nonzero-mean
  hosted fixture, a four-layer execution boundary with pre-head collapsed
  readout, deep operator diagnostics (mHC/KDA/MLA-indexer/router) in the
  reference, and `--deep/--layers` dumps in the probe. Paris re-validated
  post-fix (' Paris' top-1 p=0.526). Four-layer deep fixtures pinned
  (`evidence/glm53-flash/p2/fixtures/`). P2 numerical limits frozen
  (table above); slice ledger computed (6.175 GiB encoded). P2.1 landed:
  `kernels/rocm/device_model.{hpp,cpp}` uploads the whole-tensor slice
  through the shared bounded `hip::WeightUpload` pipeline (type-checked
  F32/Q8_0/Q4_K, zeroed tail margins); `glm5_next_slice_probe` builds
  under `gpu-test` and cross-checks the resident ledger against the
  tensor table.
- 2026-10-08 (P2.1–P2.2): slice upload verified on the GPU (112 tensors,
  6.175170 GiB encoded, ledger match) after fixing a systematic upload
  bug — GGUF tensor offsets are data-section-relative but the upload
  pipeline preads absolute file positions, so every device tensor was
  shifted by the shard's data base; the binding now derives absolute
  offsets from the mapping (the byte-count ledger could not see this;
  content qualification did). P2.2 kernels (embedding dequant, grouped
  RMSNorm, centered LayerNorm, double-accumulating F32 GEMV, mHC
  Sinkhorn mixer, collapse/combine/mean) qualified via
  `glm5_next_mhc_ops_test` at 2.4e-07 max deviation over 40 blocks.
- 2026-10-08 (P2.2–P2.5 complete on the GPU): every block of the
  four-layer slice now executes real weights on-device and matches the
  CPU oracle near-exactly. Kernels landed in
  `kernels/rocm/kernels.hip.cpp`: KDA conv+history/gates/l2-prepare/
  channel-decayed recurrence/o-norm+gate; DSA indexer
  append/pool/scores, latent caching, absorbed-query and sparse latent
  MLA; clamped SwiGLU, MoE accumulation; mHC Sinkhorn mixer, grouped
  RMSNorm, centered LayerNorm, double-accumulating F32 GEMV. Quantized
  projections and the vocabulary head reuse the shared core GEMV
  (Q8_0/Q4_K). Three qualification binaries run against the pinned
  fixtures: mhc (chain+head), kda (+KDA attention), dsa — now the full
  slice executor, 40 blocks × 5 tokens all-real: worst intermediates
  KDA 2.8e-07, DSA 2.2e-07, FFN/MoE 1.0e-06 rel RMS, logits 7.5e-07
  with top-1 matched (limits 5e-5/2e-4). Selections, expert ids and
  routing weights match exactly. Bugs found on the way: conv-history
  row index, shared-gamma OOB in grouped RMSNorm, head-offset qn/kn
  indexing, AppendRows destination row, a ClampedSwiglu up-clamp
  ternary that skipped the lower bound (dense layers hid it; the
  layer-3 shared expert exposed it via a 5% output shift), and host
  float-sqrt symbol versioning vs the gpu-test toolchain (reference
  host code now rounds through double sqrt; fixtures regenerated,
  Paris unchanged at p=0.526).
- 2026-10-09 (P2.6): GPU-side exact top-k selection landed
  (`SelectPools`: bitonic over ≤1024 pools with packed score/index keys,
  ties to the lower pool index like the reference's stable sort, kpool
  expansion + tail + ascending compose in one block; host fallback
  above 1024 pools). Probe grew `--random-tokens N SEED` (deterministic
  LCG shared with the tests), `--sel-only` and seeked logits rows, so
  long-boundary fixtures stay small. 37-token qualification over the
  full real slice: 296 blocks, worst ffn 1.8e-06, logits 1.18e-06 rel
  RMS with top-1 matched, all 34 GPU selections equal to the host order
  and the oracle's selections (9 pools, every tail offset). Timing
  record: **30.06 ms/token avg / 34.11 ms max** for the eager tokenwise
  slice (incl. host cross-check roundtrips), 59.9 GiB HIP free beside
  production.
- 2026-10-09 (P2 COMPLETE): the 2052-token first-pruning-boundary
  qualification passed. CPU fixture (4 layers, deterministic LCG
  tokens, ~72 min) followed by the GPU run over all 2052 tokens:
  16,416 blocks executed, **2049/2049 GPU-kernel selections identical
  to the oracle's** (513 pools competing for 512 slots at the final
  token — the pruning boundary), final-token logits 8.7e-07 rel RMS
  with top-1 matched. Timing records: 30–31 ms/token for the eager
  tokenwise slice including host cross-check roundtrips (5- and
  37-token runs); the boundary run's async-submit average is 0.02
  ms/token (launch-bound, not a latency number). HIP free 59.9 GiB
  throughout; production untouched. Every operator family of the slice
  — mHC, KDA, DSA indexer + latent MLA, dense FFN, Q4_K MoE, exact
  top-k selection, vocabulary head — now has real-weight GPU
  qualification against the CPU oracle at 1e-6-class agreement.
  **Gate P2 reached:** slice logits match the reference within contract
  (5/37/2052-token histories; tokenwise kernels make chunk splits
  trivially identical — batched prefill kernels are P3 work). Next: P3
  full TP2 engine (partitioner + loader on both hosts, chunked prefill,
  MoE/attention partial reductions, lockstep probe).

- 2026-10-09 (P3.7): device-side routing + repaired batch embedding +
  the serving engine. The batched embedding kernel's Q8 reads were
  unsigned (negative quantized payloads dequantized wrong); it is fixed,
  geometry-checked and error-propagating, replacing the diagnostic
  per-token fallback. MoE routing moved onto the GPU for both paths —
  sigmoid in double, noaux_tc selection with ties to the lower expert id,
  normalized top-k weights in selection order — with no per-layer host
  readback or drain; the tokenwise routed FFN now runs the batched
  implementation one token wide (two small device-to-device handoffs),
  and the tokenwise DSA selection reuses the tiled batch selector, so
  the single-block SelectPools kernel and its host fallback are deleted
  (dsa_ops_test migrated to the tiled kernel; selection above 1024 pools
  no longer round-trips through the host). The GLM_HASH_DEBUG region-dump
  leftover is gone. src/models/glm5_next/engine.{hpp,cpp} wraps the
  qualified loader + executor for serving: exact-prefix Sync (extension
  prefills only the new tokens; divergence/truncation resets and
  replays), Evaluate, retained logits, stop ids from the config, the
  glm4-mode tokenizer, context validated against the planned 262,144
  runtime ceiling (the deep-context ladder is still pending), and honest byte accounting (SessionBytes ==
  session->StateBytes() at 4096 tokens). Evidence ledger correction: the
  earlier "full-45-layer 4100-token" claim was a 24-layer run; 4100 at
  full depth now genuinely passes. Qualification (post-format binaries
  for the single-host and engine gates): 4-layer oracle battery
  (5/37/512) byte-identical with oracle rel RMS <= contract; dsa ops
  with the migrated selection PASS; full-depth rank-partial tokenwise vs
  batched byte-identical at 512, 2052 and 4100 tokens; engine test PASS
  (cold determinism, split/exact-extension/Step-appended state equality
  vs cold runs, divergent/truncated replay, accounting, tokenizer);
  two-rank tbstream pair: oracle corpus paris/text/code/cont-paris PASS
  both ranks at rel RMS <= 2e-6, prefill-compare at 512 MATCH on both
  ranks, and a 4100-token batched pair prefill PASS with all 9 logit
  rows byte-equal across ranks (pair binary b8d35cda, pre-format source
  — semantically identical; the shipped formatted source re-passed the
  4-layer battery, the engine gate and full-depth 512 single-host).
  Remaining for P3: none — execution path complete; P4 serving
  integration (GlmTextRunner + glm5-next dispatch + kGlm tool format)
  is next. Ops notes: the box wedged once loading the full slice beside
  production (swap death) — full-slice tests now always park production
  first; A's reboot wedged the USB4 controller pair (DMA tunnel
  activation failures) and /tmp cost the pair runner scripts — the
  recovery that worked: reboot both hosts, then
  strix-dual-exp/scripts/bringup.sh per host (explicit HopID 16/16 +
  busy_poll), verified with the standalone tbstream_probe exchange
  before any pair run. Evidence:
  evidence/glm53-flash/p3/runs/{p3-7-oracle,p3-7-cmp512,p3-7-lcg4100,
  p3-7-engine-test,p3-7-single-*}.
- 2026-10-09 (P3.6): contract hardening + large-pool selection + full-model
  byte equality. Instrumented the tp_probe compare to name the first
  diverging (layer, sub, token), rejected pool-bound overshoot in
  StepBatch before any device write, failed the executor test on the
  bisect mismatch, added --skip-oracle (tokenwise-vs-batched byte
  equality only) plus --layers/--tp-rank so the full 45-layer slice can
  be qualified without transport, and retired the single-thread
  batch-embed fallback's silent swallow. The batched pool selector is
  now tiled: per-tile top-512 folded into a running best set, exact
  stable ordering, signed-zero-safe; bound raised from 1024 to 65536
  pools (one 512*65536 score row = 128 MiB); the batched F32 GEMMs and
  IndexerAppend now reduce through BlockSumDouble's serial order so
  batched == tokenwise bit-for-bit at every depth. Selected
  pool ids exact at tile sizes 1023..65536 across tie patterns
  (random/zero/signed-zero/plateau/constant, small-k truncations,
  boundary cases 1024/1025, 3-row mid-chunk causality) —
  tests/models/glm5_next/batch_select_test. A real bug surfaced during
  this: a batch-vs-token F32 reduction-order divergence showed up as
  exactly one latent ULP at layer 23 token 305 in the 512-wide run; the
  depth bisect (<=23 PASS, 24+ fails) and the fixed-512-history chunk
  sweep localized it, single confirmed ULP per divergence site, no
  bitscreams anywhere (raw false positives at depth-23 boundaries).
  Qualification: single-host four-layer battery green post-fix
  (5+37+512), full-45-layer rank-0 runs PASS at 512, 2052 and 4100
  tokens (512-wide), and the two-rank pair compares MATCH in both
  directions at 512-token and 2052-token prompts (tw vs batched within
  rank; final logit hashes agree across ranks, top-1 agreement on the
  decode tail). Production parked only during the pair window and
  restored after; both hosts rebuilt from synced source (binary hash
  6585afc6...). Remaining for P3: GPU-side router (host routing is
  still staging copies through the single 32 MiB window), then P4.
- 2026-10-09 (P3.5 batched prefill qualified): a static review pinned
  the width-dependent prefill failure (PASS at <=384, illegal memory
  access at 400+) to a scratch-buffer overflow, not a transport bug:
  the routed MoE SwiGLU wrote `batch * experts_used * expert_ff` floats
  into `b.act`, allocated for one `max_ffn` row per token. Capacity
  cutoff 384 exactly = 512*12288 / (8*2048) (TP1; TP2 identical ratio
  512*6144 / (8*1024)), matching the empirical boundary. Fix: a
  dedicated `expert_act` scratch ([tokens][experts_used][expert_ff],
  +32/+16 MiB/rank (TP1/TP2 — outright buffer, not a delta)) used by the routed SwiGLU and pair-dense down GEMV,
  plus a Create-time check that resident expert widths match the
  partition. Fixed alongside: the `pools == 0` fresh-short-batch path
  now launches tail-only selection (BatchMlaAttention previously read
  stale/uninitialized counts), the unsupported pool count (>1024) is
  rejected up front in StepBatch before any device write, async
  host-vector uploads in the tokenwise router/selection paths drain
  before the vectors die, Session::Reset/HashState/CreateSession
  zeroing are stream-ordered (non-blocking stream vs default-stream
  ops), and dead debug blocks were removed. Also rewired the tp_probe:
  `--prefill CHUNK` runs prompts through chunked batched prefill
  (decode continuations stay tokenwise) with `$EXTRA` passed to BOTH
  ranks (the missing rank-1 flag caused the first mismatched run),
  `--lcg-tokens N` gives long deterministic prompts, and
  executor_test got honest reporting (success line gated on failures,
  reset replay now runs at every length, per-(token,layer,sub) block
  captures, non-finite guards). Qualification, single host four-layer
  slice: 5-token (plain + chunks 2/2/1 hitting the pools==0 path),
  37-token 32+5, 384/385/512-width single chunks and 2052-token in
  512-chunks all PASS - logits + full persistent state byte-identical
  tokenwise vs batched (512-wide max|diff| = 0), worst oracle rel RMS
  2.328e-06, top-1 matched; batched timing ~21 ms/token is
  qualification-only (eager batched GEMVs, host routing overhead
  included, not a production benchmark). Full 45-layer TP2 pair (both
  hosts, tbstream): oracle prompts paris/text/code/cont-paris PASS on
  both ranks at rel RMS <= 2e-6 with batched prompts; 2052-token LCG
  prompt in 512-wide chunks PASSes with byte-equal final-logit hashes
  on both ranks (h=272c99556c091315, top=371 agreement), 182.8 s wall
  for the full prefill (probe wall time; exchange-bound, not a serving
  number). Still open in P3: device-side router (routing remains
  host-side per layer/chunk), large-pool (capacity >4095 tokens) GPU
  selection for the batched path, and a serving-facing engine layer
  (P3.6). Evidence:
  evidence/glm53-flash/p3/runs/{p3-5-batch512,p3-5-lcg2052}-r{0,1}.log
  and single-host {fix5-*,long37-c32,w384,w385,w512,b2052-c512}.out.
- 2026-10-09 (P3 start): production parked for the P3 window (both
  ranks stopped cleanly); the pinned artifact is being staged to the
  peer over tbnet (measured 866 MB/s ssh+dd on the jumbo-frame link;
  the LAN path only managed 9.4 MB/s). P3 plan of record: partition
  descriptors with explicit head/channel/ff ranges (fixing the KDA
  convolutions' bucket: they split by channel rows, not columns),
  bounded strided column-spread upload in the shared WeightUpload,
  executor/session extraction from the dsa ops test, tbstream TP2
  tokenwise, 512-token chunked prefill with device-side routing and
  large-pool selection, then the qualification matrix. Runtime memory
  plan: F32 compact caches at 256K (5.844 GiB) + weights 85.909 GiB +
  KDA state/history ≈ 91.8 GiB per rank before scratch, inside the
  108 GiB ceiling.

- 2026-10-08 (late): P1 COMPLETE. All shards downloaded and sha256-
  verified; inventory probe confirms the C++ ledger (169.650 GiB full AR,
  85.908 GiB/rank at TP2). Tokenizer golden probe: 21/21 exact against the
  official tokenizer. Reference validated on real weights after finding
  and fixing a per-element (instead of per-vector) l2 norm in KDA —
  verified against a numpy layer-0 oracle and a llama.cpp CPU build
  ("The capital of France is" → ' Paris' p≈0.53 vs llama.cpp ≈0.51).
  Layout facts pinned: attn_v_b is the plain post-attention projection;
  conv weights are channel-major cross-correlation; mHC/MoE/MLA
  conventions confirmed on both oracles.
- 2026-10-08 (night): download switched to a parallel chunked fetcher
  (512 MiB ranges, six connections; the CDN throttles each connection to
  ~5 MiB/s). Template renderer landed: 23 jinja-rendered goldens, compiled
  C++ renderer byte-exact on 12 structural cases, template sha pinned.
  Shared tokenizer honors GGUF `token_type` CONTROL/USER_DEFINED entries
  (GLM's 36 control tokens incl. `[gMASK]`/`<sop>` now parse as specials;
  Qwen behavior regression-tested). Reference probe (fixed-token logits
  oracle) built for the complete artifact.
- 2026-10-08 (evening): download of shards 2–5 running (rate-limited;
  shard 1 verified after fixing the sha source — the HF tree API's oid is
  NOT the LFS sha256; expectations now come from the LFS pointer files).
  P1 landed in gufo: full scalar reference (absorbed MLA, KDA, mHC,
  indexer, MoE) with a structural equivalence test; `glm4` tokenizer mode
  in the shared tokenizer with Qwen behavior regression-tested; vocab/
  merges/specials verified id-exact against the official tokenizer.json;
  golden probes ready for the complete artifact. All glm5_next tests +
  qwen tokenizer tests green; format clean.
- 2026-10-08 (later): P0 census complete. Real tensor-name contract pinned
  from the artifact (differs from llama.cpp: `attn_k_b`/`attn_v_b`,
  `indexer.*` infix, `indexer_compressor_*`, `ssm_conv1d_*`, bare `ssm_a`,
  `exp_probs_b.bias`); AR ledger 85.909 GiB/rank at TP2. gufo package
  `glm5_next` (config/bind/tp-plan) landed with green unit tests and a
  format-clean tree; download of the pinned artifact running in the
  background with per-shard sha256 verification.
- 2026-10-08: plan recorded; P0 started — header captures, ledger, first
  gufo package code, artifact download initiated.
