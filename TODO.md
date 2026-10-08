# TODO — wedge resolution plan (FINALIZED 2026-10-05; adaptive)

Status: EXECUTING. Healing stays IN every live build; after the one
authorized baseline reboot the kernel is FROZEN and recovery takes
precedence over experiments.

Hypothesis under test (replaces "cable-only"):

> Certain traffic/scheduling patterns expose ring-progress or flow-control
> defects in the stream/NHI stack. Timeouts, premature teardown, reattach
> and recovery churn can escalate those into persistent control-plane
> failures. Cable/port/firmware may modulate susceptibility but are not
> established as the sole cause.

Withdrawn/qualified conclusions (do not build on these):
- `timeout reading config space 0 from 0x12/0x16` = LOCAL hop-table
  entries 9/11 (offset 2*hop_index), NOT in-cable retimer routes.
- "both sides >=1 MiB syscalls" is NOT established (A17 also added a
  teardown pairing barrier; A7 lacked it; big read requests can return
  tiny results — strace-b3.log shows 2 MiB asks returning 64/12288/90240).
- The kernel TX "coalescer" does not accumulate writes (flushes previous
  stage per write) — its negative result proves nothing. Keep disabled.
- "8 s heal" is harness-quantized (5 s + 3 s), not a latency measurement.
- Old scoring called userspace-failed runs "clean" (RC 134/139 counted
  clean when dmesg counters didn't move).

## Ground rules (every stage)

- NEVER rmmod this stack on the live pair; no PCI rebind; no live kprobes
  on module text. Kernel replacement = reboot (hostB first, then hostA).
- RECOVERY FIRST: after the baseline reboot, a failed trial ends after
  diagnostic capture; the runner yields to the healer; resume only after
  stable connectivity + fresh stream qualification. If recovery has not
  completed within 120 s of the first failure, STOP the campaign and
  report. No automatic reboot/escalation. A healed failed trial stays a
  recorded failure.
- Record per block: boot ids + uptime, LOADED module srcversions on BOTH
  hosts (/sys/module/.../srcversion), tx_coalesce/busy_poll readback,
  gufo binary sha, trained rate/lanes.
- Scoring: 4 classes, never conflated: (1) workload success (both ranks
  RC=0, full delivery, integrity ok), (2) transport failure (stall /
  ENXIO / deadline / truncation / nonzero RC), (3) link episode (new
  timeout/deactivation lines + health interruption), (4) recovery span
  (first-failure -> restored, measured from dmesg timestamps).
- Unique run dirs per block; preserve BOTH ranks' logs; copy rank-1 logs
  back. Settle gap after any wedge (heal + quiet dmesg) before next cycle.
- External timeout = workload failure, not automatically "wedge".
- 0/N clean is screening only (0/3 => ~63% upper bound). Validation
  blocks need a positive control and larger N.

## Stage 0 — harness + reference measurements on CURRENT kernel (no reboot)

- [x] 0.1 Finalize this plan; record in repo.
- [ ] 0.2 ablate.sh: 4-class scoring, unique timestamped run dirs, rank-1
      log retrieval, identity header per run (loaded srcversions, gufo
      sha, boot ids), settle gaps, post-cycle dmesg snapshots for heal-span
      measurement.
- [ ] 0.3 Add arm A18 = A7 + --pairing teardown (delivery-confirmed close)
      -> isolates the completion barrier (A18 vs A7) and batching/reader
      (A18 vs A17).
- [ ] 0.4 Reference block on the CURRENT kernel, same gufo binary:
      ARMS=A7,A17,A18 (+B0 gufo cycle) x 3 rounds, interleaved. This is
      the corrected "before" data and removes the biggest confound.

## Stage 1 — ONE kernel candidate + ONE reboot cycle (authorized)

- [ ] 1.1 Build candidate in a SEPARATE tree (kernel/candidate-b/), from:
      - pristine 7.3-rc3 base
      - stream.c: westeri/thunderbolt next-branch version wholesale
        (busy-poll lock fix, RX polling, CLOSE write-side handling,
        framing-error -> -EIO; upstream stop/release ordering replaces
        our teardown reorder; NO coalescer)
      - re-apply our stream.c essentials onto it: hop rotation clamp +
        ida fix (detach zeroing, keep_hopids from tbstream_remove,
        attach alloc-failure clearing) — as separate upstream-reportable
        hunks
      - nhi.c: stock + tb_ring_poll_pending() + descriptor-write-in-poll
        (4d84caebab18) — no struct/ABI changes, thunderbolt-net untouched
      - xdomain.c/tb.c: our current healing versions unchanged
        (keepalive, lane-disable retrain, rescan, quarantine wq)
      - heal-watch + tbstream-heal@ units unchanged
- [ ] 1.2 Compile-verify the whole module set; keep known-good artifacts.
- [ ] 1.3 Deploy + reboot ONCE: hostB first, verify over LAN ssh, then
      hostA. Verify RUNNING srcversions, healers active, stream opens,
      tbnet up. If anything is unreliable: STOP, no further reboots.
- [ ] 1.4 Re-run the Stage-0 reference block (same gufo binary) on the
      new baseline. DECISION GATE:
      - clean where before failed -> kernel freeze, validation block,
        then Stage 5 planning (hardware, next access window).
      - still failing -> kernel freeze anyway, continue Stage 2/3
        (userspace) on this baseline.

## Stage 2 — confound removal + userspace fixes (kernel FROZEN, no reboots)

- [ ] 2.1 Small-message 2x2: {direct, batched} writes x {ordinary,
      buffered} reads, identical pairing barrier in every cell; log actual
      syscall request/return distributions.
- [ ] 2.2 gufo transport fixes, one at a time, requalified each:
      busy-poll poll() fallback, EOF/stop handling in reader,
      StopReader lifetime vs buffer free, buffered-reader grow preserving
      unread bytes.
- [ ] 2.3 Rate vs shape at matched volume (controlled producer rates).
- [ ] 2.4 Optional: bidirectional progress loop / bounded app buffering
      (design per donnerkeule lessons; only if 2.1-2.2 don't resolve).

## Stage 3 — gufo rebase (separate from kernel comparison)

- [ ] 3.1 Rebase feat/tp2-tbstream onto pinned neuhaus feat/tp2-rdma
      (2833856; rdma branch adds integration extras — cherry-pick only
      what's needed). Keep: ESRCH fix, rank-1 retry window, transport
      fixes from 2.2.
- [ ] 3.2 Build via `nix build .#tp2-tbstream`, deploy both hosts,
      requalify correctness + performance on the frozen kernel.

## Stage 4 — deferred until next physical access window

- [ ] Descriptor/doorbell batching (tb_ring_tx_more/notify port).
- [ ] Kernel-owned RX backlog / admission bounds (donnerkeule model).
- [ ] Keepalive notification-suppression bug fix (xdomain.c:1951) —
      prepared as a patch, loaded only with the next kernel window.
- [ ] tbnet-disable isolation arm (healer uses tbnet reachability — needs
      a redesigned health signal first).
- [ ] Cable identification/orientation blocks; verified-passive cable;
      cross-controller (AMD-native vs Barlow) at matched Gen3.
- [ ] Upstream report: ida corruption vanilla bug, accepted-TX-tail loss,
      close-after-small-frame repro + upstream-fix deltas, ctl cancel-path
      hang, rescan gap.

## Stage 5 — closeout

- [ ] gufo-prod re-enable criteria: N clean serve restarts + wedge
      transparency on the final build; bench-grade numbers after.
- [ ] Commit/PR decision with neuhaus (credits: Linux thunderbolt/
      Noever/Westerberg/Borzeszkowski; gufo/Sven Neuhaus; donnerkeule
      write-striping findings as design reference).

## Do not regress

- Healing chain in every live build (post-baseline: kernel frozen).
- Hop rotation + ida fix; E2E mandatory (dropping deadlocks); reboot
  order hostB-first; iommu=pt cmdline; FLAKE build = `.#tp2-tbstream`;
  freeze gufo binary during kernel A/B; never change kernel and gufo in
  the same comparison.

## Log

- 2026-10-08 ~07:40 PHASE 0+1 EXECUTED, PHASE 3 CLOSED (evidence/decode-tg/
  ph1-attribution/): extended the d1-stabilization cycle-trace patch with
  per-phase rank-0 wall timers (catch-up, draft build/head/body, verify
  forward, selects, CPU sampling, rollback), grammar attribution (greedy
  divert count; sampled zero-target-p rejections) and epoch timestamps;
  diag binary 7511dcae both hosts (patch reverted after, gufo tree clean,
  format pass). Matrix 5 fixtures x {C1,C2} x {d0,d32k} 20/20 clean.
  RESULT: target verification forward = 72-86% of attributed decode time in
  every cell; sampling+transfer+rollback <= 2.4% (D4 REJECTED by data);
  greedy grammar diversions = 0 everywhere, sampled tools 12-15% of rounds
  grammar-dead (D3 below bar); draft head 4-14% (D5 ceiling 2-7% e2e);
  D8 copy share 15-58% on 8-grams (thinking-heavy; real-traffic share
  unknown, stays parked). NEW POOLS: verify forward itself (only batching
  + acceptance move it) and C2 unattributed wall 20-45% (scheduler
  interleave/TP wait) -- rank-1 profiling pass recommended before D6/D7.
  Per-request tok/s: rep 79.3/65.3 (d0/d32k), prose 61.8/47.9, code
  43.5/47.3, tools ~50; C2 rep aggregate ~122. Ops: clean block, prod
  restored first, canary 73.1 spec-decoding. Records pushed.
- 2026-10-08 ~06:00 EMA 0.85 RETAINED + DEPLOYED (reversal of the overnight
  rejection): paired-CI re-analysis of the saved A/B records showed five of
  seven fixtures improving with CIs excluding zero (decA1 +3.10 [+2.54,
  +3.66], decA2 +1.66, codeA2 +3.96, proseA +1.99, toolsA1 +9.07; codeA1
  -0.79 with CI spanning zero), every pair positive on the improving
  fixtures, greedy outputs bit-identical. The reported seeded-replay
  failure was RETRACTED -- only server-minted tool-call IDs differed;
  content identical across passes (hash bug). Lesson recorded: retention
  standard = repeatable net improvement, not a fixed 5% cutoff. Gates:
  mtp_sampling unit suite + format clean; tp2_constraints 9/9 on the
  deployment binary; held-out greedy prompts bit-identical to baseline
  across builds; within-build seeded replay exact (qual.py). gufo 2f9510c
  (controller + EXPERIMENTS row) + 10cb479 (kept D2 selector test);
  deployed 87e2fb95 BOTH hosts (backup gufo.0d559497); prod restart clean,
  canary 72.9 tok/s spec-decoding, tools smoke 57.7 tok/s @76.3% acc with
  decode_modes policy:0 (cooldown-AR rounds gone on this class; old logs
  showed policy:16-48/request). WIP patch regenerated + pushed.
- 2026-10-08 ~00:30 D1-STABILIZATION LEG CLOSED (evidence/decode-tg/
  d1-stabilization/): matched-input E0 established the controller is
  DETERMINISTIC per request (3 fresh-process passes bit-identical; the
  d1-policy "bimodality" was nonce-level workload variation) and within ~8%
  of the per-request forced-width optimum on hard text while BEATING every
  fixed width on easy text (decA2 80 vs w7 78.5); the loss concentrates in
  cooldown-retry storms (210/822 rounds policy-AR on the hard fixture).
  Forced-width controls confirmed greedy width-invariance bit-exactly and
  measured per-chain cycle costs (1/3/5/8-row chains: 29.4/29.5/59.3/86.1
  ms -- narrow verify nearly free). Exact offline policy replay is
  FALSIFIED: draft-head state after catch-up is not bit-identical to
  mid-chain state, so acceptance streams are policy-dependent (pos-1252
  counterexample recorded). EMA 0.75->0.85 candidate (unit-tested, format-
  clean) gained only 0-3.8% per fixture in a 4v4 ABBA serving A/B with
  bit-identical greedy outputs -- REJECTED below the 5% bar and reverted
  (patch preserved). NEW FOLLOW-UP FLAGGED: candidate toolsA1 fixed-seed
  outputs varied across passes (baseline 4/4 identical) -- seeded replay
  appears to depend on checkpoint-cache-restored draft-policy state, a
  latent determinism fragility independent of the rejected change. Ops: one
  amdgpu-userptr stall wedged the pair mid-E0 (self-recovered; serve-pair
  stop now waits for remote clear); prod restored + canary green; candidate
  and diag binaries preserved under /root/probe-d1s-*.
- 2026-10-07 ~19:45 D1 POLICY EXPERIMENT (evidence/decode-tg/d1-policy/):
  matched full-serving A/B on the diag pair found the C1-vs-C2 cost-curve
  arm is NOT the lever (single run inside the adaptive band) -- instead a
  forced-width serving sweep (diagnostic GUFO_FORCE_DRAFTS build, reverted
  after) shows (1) optimal width is workload-dependent: repetitive fixture
  monotone to the 7-draft cap (51.7 -> 76.7/78.0 tok/s), code-shaped peak at
  w5 and -20% at w7; (2) the production adaptive draft-width controller is
  BIMODAL per request: converged runs beat every forced width (decA 80.8
  tok/s at width ~4.2 / 92% acceptance) while collapsed runs deliver ~AR+eps
  (45 tok/s) -- a 15-45% loss per affected request, and the run-to-run
  spread explains the historical 73.6-78.1 vs 59.5/45.8 tok/s discrepancy on
  the same fixture. Mechanism hypothesis: one rejection at a depth hammers
  its 0.75-EMA estimate to ~0.45 and arms a 16-token AR interval (the
  policy:AR calls in prod logs). NEXT: D1 continuation = draft-width
  controller STABILIZATION (mtp_policy.hpp dynamics: slower EMA / Beta
  counts, >=d evidence attribution, width hysteresis, retry-interval
  re-costing), measured with this serving harness (decA + codeA + the
  tools-sampled fixture), gated on seeded sampled replay determinism.
  Ops: maintenance block closed cleanly, prod restored + canary 72.5 tok/s
  spec-decoding; diag binaries /root/probe-d1p-{a,b,f} both hosts; launcher
  gotcha recorded: remote nohup backgrounding hangs this peer's sshd (use a
  locally-detached foreground ssh instead).
- 2026-10-07 ~18:40 DECODE PHASE-2 EXECUTED (D2 rejected, D1 measured-closed;
  docs/decode-tg-plan.md status note): D2 selector live-range grids for eager
  narrow TP2 decode were implemented in gufo (bound the score grid when the
  executor can never graph-replay), unit-gated with new deep-capacity
  live-range cases in the selector operator test (kept — they cover the
  pre-existing wide-path live_blocks contract), and A/B'd on the pair with
  interleaved tp_batched_probe MTP runs (33k-token counting prompts, 2
  members, greedy): 4v4 bit-identical and dead even (89.3 vs 89.3 tok/s
  medians, per-step 172 vs 172 ms), the baseline shows NO capacity
  sensitivity (ctx 65536 == 262144), so the empty selector workgroups were
  already free -> executor change REVERTED per no-gain doctrine. D1: full
  TP2 cost audit over the pair (depths 0/4k/32k x C1..C8 x widths 1..8,
  evidence/decode-tg/d1-costs/): TP2 cycles 25-35% cheaper in absolute
  terms, but width choice is ratio-driven and the ratios are preserved --
  optimal widths match the single-host curves across the 0.4-0.8 acceptance
  band (production logs: 64-87%) and diverge ~1 width only where tokens/ms
  is flat -> no TP2 profile, no concurrency-init change. INCIDENT
  (environmental): first full-depth audit run died at the depth-0->4096
  transition with a tbstream write timeout coincident with local NVMe I/O
  timeouts + controller reset (dmesg); streams stayed healthy, split-depth
  reruns clean -- new trigger candidate for the exchange-timeout family
  alongside the recorded pc4096 hazard. Prod: maintenance block closed,
  gufo-prod restarted, /ready green, canary spec-decoding. Gufo tree holds
  the EXPERIMENTS row + kept test (uncommitted, per policy). NEXT by plan:
  Phase-3 decision among D3 (grammar/penalty-aware drafts) vs D4 (compact
  exact top-k verification) on workload-share evidence; D8 gated on
  repetition share.
- 2026-10-07 ~16:20 DECODE/TG PLAN RECORDED (docs/decode-tg-plan.md) after a
  read-only code audit + online research session: prefill is paused; ranked
  TG avenues D1-D9 with exactness gates, historical precedents (incl. the
  unattributed removals of the earlier --draft-vocab prefix view and the
  private Q4 shortlist) and a measurement-first campaign (Phase 0
  instrumentation -> Phase 1 baseline phase-timing matrix -> Phase 2 exact
  small wins D2 selector live-range + D1 TP2 cost calibration -> Phase 3
  data-chosen among grammar-aware drafting / compact exact top-k / FR-Spec
  draft row subset -> Phase 4 gated: suffix-decoding proposer, batch drain
  coalescing, DFlash-class evaluation). Lossy acceptance methods and
  two-replica serving are explicit non-goals. No measurements taken yet.
- 2026-10-07 ~15:30 WORKLOAD-SHAPE CAMPAIGN + PROD CONFIG WIN: measured the
  real agent shapes through the TP2 stack (evidence/prefill-triage/
  serve-shapes/). Findings: extensions at depth run 1969-2112 (mostly genuine
  attention cost); deep edits restore at the divergence point (cached 32825
  of 32830 — checkpoint granularity is fine); tiny turns pay a 2.3x
  per-token penalty (431-row chunk, 0.45s absolute); prefill during active
  decode lost 45% to the default 512-token budget; concurrent prefills lost
  24% to shredded chunks. FIX DEPLOYED: --prefill-chunk 2048 (SERVE_PREFILL_CHUNK
  unit env + guardian passthrough) — prefill-during-decode 1234 -> 2022 tok/s
  on prod (+64%), decode itself improved (73.6 -> 78.1), concurrent +13%,
  single/cold unaffected (canary 2233.0). 2048 = paired 1024+1024 lanes
  (C1-optimal). HAZARD FOUND: --prefill-chunk 4096 with concurrent decode
  POISONS the tbstream communicator (overlapped exchange write timeout,
  graceful exit, streams survived; logs preserved). Remaining ceilings are
  modest: interleave ~8% vs sequential (serialization parked below bar),
  sequential multi-request overhead ~5%, tiny-turn batching small absolute.
  Next-tier options (cross-request suffix batching, in-prefill checkpoint
  export, 4096-poisoning root cause) all have bounded gains — see SUMMARY.
- 2026-10-07 ~13:55 CHUNK-ALIGNED CHECKPOINTS RETAINED + DEPLOYED
  (follow-up to the gap attribution): TextRunnerDescriptor gained
  prefill_chunk_tokens (Flash-Next runner reports PrefillCapacity);
  intermediate cache checkpoints round up to chunk multiples and merge,
  so a lone cold prefill never clamps below the engine's own chunk.
  Gates: pool toy tests incl. a new aligned-grid case, hosted CPU
  contract suite PASS; live pair: cold 8k 2235-2237 tok/s @4096-chunks
  (stock 1969-2032 @2048), 32k unchanged 2247.7, continuation restores
  from the aligned 8192 checkpoint, snapshots still captured (0.68GB vs
  0.94GB), constrained MTP healthy (spec, 73.2% acceptance). gufo 3e6ec75
  + 512f62b (EXPERIMENTS row); WIP patch 15085 lines, secret-clean.
  DEPLOYED 0d559497 BOTH hosts (backup gufo.a28a6448); guardian accepted
  first cycle with canary 2221.2 (was ~2000 band) — the +11% cold-prefill
  recovery is live in prod. session_test GPU gate skipped: devshell
  GLIBC_2.43 skew (known environmental; hosted suite is the CPU gate).
- 2026-10-07 ~13:00 PREFILL GAP ATTRIBUTED (matched-probe campaign,
  evidence/prefill-triage/gap/): the ~2300 probe references reproduce on
  today's tree (AR and MTP both 2215-2339 @8k-32k, canonical checksums).
  MTP draft catch-up ±1.5%, input content ~1%, snapshot captures ~0%
  (2.6 GB captured during a 32k prefill with no rate loss), full serving
  stack ~2% at 4096-chunk sizes. The one real deficit: the intermediate
  checkpoint grid (2048-token interval) clamps cold <=8k prefills into
  2048-token engine chunks -> paired 1024 trunk batches -> -10..12%; a
  no-clamp diagnostic build recovered 2223-2229 @8k (causal proof,
  reverted after measurement, prod binary a28a6448 verified
  byte-identical after rebuild). The E2E-observed 1655-1822 was mostly
  depth-loaded PARTIAL extension prefill (cache restore + suffix at
  depth) plus one concurrent pair, not cold prefill. FOLLOW-UP CANDIDATE:
  round checkpoint positions up to PrefillCapacity multiples (needs
  cache/continuation gates). Prod restored and healthy after two
  maintenance blocks (canary 2006).
- 2026-10-07 ~10:20 PROD AT FULL 256k CONTEXT (user flagged: prod must run
  the model's native 262144, not the 65536 guardian default): set
  SERVE_CONTEXT=262144 in gufo-prod.service (daemon-reload, restart);
  pair accepted first cycle (canary FAST 1984.1, logs
  .../20261007-101846), both ranks log context_tokens=262144, rank1 gpu
  device 49.0/122.8 GiB. Earlier "65k" reading was the guardian default,
  not the model limit (GGUF qwen4exp.context_length = 262144 verified).
- 2026-10-07 ~09:45 DEPLOY a28a6448 (from d3e7ab8, includes the pinned
  rejection-lockstep test + token-accounting refactor): binary replaced on
  BOTH hosts via mv with backup gufo.42fc94e6; systemctl restart
  gufo-prod; guardian accepted first cycle (canary FAST 1969.6 prefill
  tps, logs .../20261007-094150); /ready green; smoke tools request r5:
  finish tool_calls API-level, decode_modes=spec:22/constr:0/policy:1/
  budget:0/unavail:0, constraint=1 tools=1, 43/67 drafts 64.2%, 54.8
  tok/s, no AR fallback. User running the next end-to-end LLM run against
  this deploy; logs in evidence/serve-guardian/20261007-094150/.
- 2026-10-07 ~09:35 AUDIT FOLLOW-UPS PINNED (test-only, no behavior change,
  no deploy — deployed binary stays 42fc94e6): (A) the TP2 toy pair now
  covers a REAL grammar-mask rejection: reject_at injects an inadmissible
  raw peak at the cycle's first draw and again after an accepted token
  (absolute positions 3 and 10 over the prompt), greedy AND
  random-sampling (temp/seed/penalty, deferred draw-state residual) — both
  ranks independently mask and must land on the same token
  (RequireSameCalls pins digest lockstep; output stays the constrained
  object; spec cycles retained, no AR fallback). (B) the thinking markers
  are single-sourced in quote_tracker.hpp: inference_backend's buffered
  reasoning_tokens search tokenizes kThinkEnd instead of a re-typed
  literal, the new inline ReasoningTokenCount carries the split /
  never-closed / zero semantics with unit tests (marker absent at-start
  mid first-of-many multi-piece empty). Gates: hosted CPU contract suite
  PASS; 9 focused tests green; format clean. gufo 658e269 + d3e7ab8.
  Model-layer DeepSeek marker duplicates stay (model-local by design).
- 2026-10-07 ~08:50 UPSTREAM TOOL CORRECTNESS INTEGRATED (user-approved
  plan, both fixes): (1) upstream #441 native-tool parity — native syntax
  kept for every schema, request-wide JSON fallback removed (both TP2
  recipe builders adapted to the new ToolParameters(schema,strict,format)
  signature; tool_required stays in WithTools), delimiter/overlap and
  implicit-reasoning-end parser fixes, span-preserving tokenization, warm
  initial-mask reuse; 688-decision llama.cpp grammar fixture imported.
  (2) upstream #434 Responses tolerance — hosted tools skipped, namespace
  functions flattened + echoed, null reasoning replay, Codex request
  fields tolerated. (3) TP2 corrections from the audit, landed first
  (3b07878): DescribeConstraint removed — the recipe is now emitted by
  ConstrainChatRequest from the composing decisions (fixes
  tools+tool_choice:none+response_format mirroring response-only vs
  response-or-tool across ranks), and every kSingle is gated on rank 1's
  sequence-correlated admission verdict (kAdmission response; protocol
  v19) before rank 0 schedules model work — rebuild/initialization
  failures reject the request cleanly. Gates: hosted CPU contract suite
  PASS (sandbox); tp2_constraints.py 9/9 on a fresh 2-session live pair,
  drafts 15-36 on every constrained request; prod tools request
  finish=tool_calls, spec-mode decode 53.4 tok/s. gufo 3b07878, 9869526,
  0a13415, 37004ed; WIP patch regenerated; deployed binary 42fc94e6 BOTH
  hosts (backup gufo.2d4a43ec); guardian accepted first cycle.
- 2026-10-07 ~07:35 TP2 CONSTRAINED MTP SHIPPED (user-approved campaign):
  tool/schema requests now decode speculatively over TP2. Root cause of the
  AR fallback was rank 1 never seeing the constraint; the fix carries a
  ConstraintRecipe on the control protocol (v18), rank 1 rebuilds the
  grammar through the same composition code, and the handshake compares
  constraint-vocabulary fingerprints. Live production: same tools request
  33.1 -> 52.4 tok/s (spec:22, 64% acceptance). Gates: tp_control_test +
  tp_executor_test (constrained toy MTP, recipe round trip) PASS;
  tp2_constraints.py 9/9 on a live pair with drafts on every constrained
  request (15-36 each). gufo a85e9e4 (decode-mode logging + ignore_eos
  positional fix found by the audit) + 0b9907a (feature) + 9dcd6d8 (docs);
  WIP patch regenerated, pushed both remotes. Deployed binary 2d4a43ec
  BOTH hosts (backup gufo.e82b25db); guardian accepted first cycle.
  Upstream check: canonical gufo + all TP branches still have the
  constraint fallback (nothing to backport). Evidence:
  evidence/prefill-triage/tp2-constrained-mtp/.
- 2026-10-06 ~20:55 GUFO-PROD RE-ENABLED on the guardian (user call):
  unit ExecStart = scripts/serve-guardian.sh, SERVE_PORT=15003 (the old
  serve-prod-native.sh no longer existed; old unit backed up under
  /root/archive/pre-saga/; start-time drop_caches dropped). Accepted on
  its first cycle (c1 1991.9 FAST; prod-port canary 2007.0; /ready
  green). Enabled for boot; rank death or 3 slow cycles → systemd
  restart after 30 s with a fresh retry budget; wedge recovery stays
  with the heal chain. Watch item: a slow-plateau draw (see PHASE A)
  should be preserved for Phase B attribution when it appears.
- 2026-10-06 ~20:40 SLOW-SESSION PHASE A CLOSED — the guardian's rejections
  were cold-first artifacts, the canary/guardian are reclocked, and a pair
  was accepted and torn down cleanly. Facts
  (evidence/prefill-triage/slow-session/PHASEA.md): cold first requests
  measure 1303–1850 tok/s vs the warmed pair band ~1990–2000; every pair
  tracked past two warmed requests reached ≥1927 (one accepted run
  converged 1385→1810→1927→2000→1997); single-host probe 8/8 in the fast
  band (1671 median) today. Fixes: canary nonce + uncached-full-prefill
  validation (ERROR ≠ SLOW), WARMUP mode; guardian warmup→measure→confirm
  flow, /ready readiness, PORT env forwarded, per-run persistent rank
  logs, remote-kill and process-detection fixes, retry budget reset, no
  default drop_caches/compaction. Withdrawn: "ten genuinely slow draws"
  (cold artifact) and the TTM-pool-recycling rationale (drop_caches=3
  reaches the pool shrinker; ordinary weight backing is not pooled; idle
  pools empty). Open: one draw plateaued at ~1780–1798 through two warmed
  requests (n=1) — ramp-vs-plateau unresolved; a future slow-plateau pair
  must be PRESERVED for Phase B attribution (placement/queue/host-phase
  hypotheses ranked in the investigation write-up), not re-drawn.
- 2026-10-06 ~18:25 REBOOT-READINESS GAP CLOSED in the heal chain (both
  hosts; commit pending). Post-reboot check showed hostA's stream at
  busy_poll=0: the boot healer's bringup.sh aborted at the in_hopid
  write ("Device or resource busy" on the already-attached stream) under
  set -e, never reaching busy_poll=1 — and the watcher only re-applied
  config on peer death, so the drift persisted while the peer stayed up.
  busy_poll is the interrupt-free ring-poll mode (stream.c:133) the
  decode exchanges require; without it RX is paced per-frame by
  interrupt->wake->repost. FIXES: (1) bringup.sh attribute writes are now
  EBUSY-tolerant when the value already matches (verified idempotent on
  the live attached stream: both HopID writes tolerated, ATTACHED-OK);
  (2) heal-watch.sh enforces busy_poll=1 on every 2s pass and re-applies
  a full bring-up when the stream is missing with the XDomain up
  (verified: manual drift to 0 repaired within one pass, logged).
  Scripts synced to hostB, tbstream-heal@1 restarted clean, busy_poll=1
  on both hosts. SETUP.md documents the self-healing behavior. Also
  noted: gufo-prod.service + postboot-validate.service are disabled;
  tbstream-heal@<rank> is the only enabled boot automation and now owns
  the serving prerequisites.

- 2026-10-06 ~15:50 W1 ROUTED PACKED-LAYOUT CAMPAIGN CLOSED (mechanism
  validated, integration PARKED; gufo 13d7d1c docs-only, code REVERTED
  clean; evidence/prefill-triage/routed-w1/ incl. the 280-line
  re-appliable prototype patch + bench logs). Built sibling kernel
  instantiations behind opt-in packed_q5/packed_k flags + a 512-expert
  bench with rotating padded routing maps and an allocation-placement
  (aa) control. Results (byte-identical outputs everywhere, aa within
  ±0.4%): Q5_1 down stage-major meta/code planes (codes uint4)
  -4.1/-5.2/-7.5% @1024/2048/4096 tokens k=320 (-4.4..-5.5% k=640);
  Q4_K paired gate/up chunk-planar 1KiB planes -4.5/-3.5/-2.1%.
  Alternatives beaten: down 48B-record-contiguous -4.4%, gate/up
  superblock-grouped records -2.4%. MEASUREMENT TRAP: a "−25%" gate/up
  datapoint was an addressing bug whose loads aliased into one ~320B
  window (dense overlapping reads = fast garbage); caught by the output
  hash. WHY PARKED: modeled full rollout = down 1731ms×5.4% + gate/up
  2097ms×3.4% ≈ 164ms/rank ≈ +1.1% e2e @32k (HCS1's +0.86% didn't
  separate); single-copy production (USER REQUIREMENT) requires
  converting ALL consumers (RoutedF16 all widths, non-paired gate/up,
  fallbacks, MMQ decode vector kernels — persistent-SSM decode
  regression precedent); paired gate/up ~half activation-reread-bound
  (838MB logical vs 441MB weights/call) so weight layout caps it ~4%.
  Revisit triggers: decode-side packed MMQ reader lands anyway; gate/up
  activation rereads addressed; single-host headline work (down gain
  doubles). GPU load-time repack cost ~35GB/rank once, tensor-wise temp
  ≤~460MiB — cheap when triggered. routed_wmma_ops_test exit 0 on both
  the prototype and reverted builds; dense_gemm_bench canonical hashes
  reproduced post-revert.

- 2026-10-06 ~14:40 V2 HC STAGE-DEPTH SCREEN CLOSED (rejected; gufo 6b06771
  test/bench+guard commit; evidence/prefill-triage/hc-v2/). Mechanism:
  deepen the LDS K-stage of the HC up (DenseF16GEMM<256,128,BK,4,2,8,true>)
  and down (W8A8BlockedWmma<64,128,BK,2,4,true>) kernels to cut the
  2-barriers-per-stage count. Results @2048 isolated (dense_gemm_bench,
  n=15): up BK=2 471->522us (-9.3%, hcs route); down BK=8 401->478us
  (-19.2%, BIT-EXACT hash) — occupancy loss from the fatter LDS stage
  dominates; both kernels at practical WMMA ceilings (28.5/33.5
  TFLOPS-equiv). Up epilogue barrier count is LDS-capacity-locked
  (double-buffered gates needs 33.3KB > 24KB stage). HAZARD found+guarded:
  W8A8 kPrefetch=(BM*BK)/256 floors with no bounds check — BK=5/6
  instantiations silently computed on unstaged weight rows (wrong hashes);
  static_assert((BM*BK)%256==0) added (all in-tree instantiations pass;
  DenseF16 template legitimately supports partial stages via ceil+a_live —
  assert is W8A8-only). Bench gained the hcd case (down baseline 401us
  @2048 / 529us @2049, hashes recorded). Screen done in-tree with env-var
  dispatch scaffolding, REVERTED before commit; final build re-verified
  baseline hashes+operator tests (7 exact). No paired A/B spent (isolated
  regressions can't recover e2e). HC up/down epilogue-efficiency family
  EXHAUSTED at kernel level. NEXT by ledger: routed-expert weight
  layout/streaming prototype (the ~6.9s routed family), or slow-session
  diagnostic; serve binary daff7d61 unaffected (no production path change).

- 2026-10-06 ~13:30 HCS1 RETAINED: F32 mixed-store skip on the wide FFN
  mixer route (gufo 3174c40; serve binary still pre-HCF1, deploy pending).
  MoePart's fused HC projection skips the F32 mixed store — all its
  consumers read the F16/Q8 cached copies (F16 router, Q8 shexp, F16 routed
  rows); attention mixers keep the store (BF16 indexer re-narrow + F32
  alpha_beta re-read F32 directly; alpha_beta IS F32 in this GGUF, router
  F16). kSkipF32 template sibling -> storing variant's codegen untouched;
  HcMix mixed_reread flag + cached router-type scan + MoE-observer check.
  Kernel isolated 580->471us (-18.8%) @2048; route verified via profiled
  instantiation names (48 skip + 48 keep per chunk). Gates: operator
  sentinel check exact (96/2049); gpu_probe dump == canonical 8ddefb67;
  canonical member checksums both ranks every clean session; decode flat.
  INCIDENT (protocol): the FIRST paired matrix was accidental A/A — the
  scan initially included alpha_beta (F32 but only consumes the ATTN
  mixer's row), suppressing the skip (0 skip-kernels in profile; +0.1%
  "median" = noise). Route-fires profile caught it; everything re-run
  (aa-control/ holds the A/A logs). Corrected paired TP2 @32k 4v4
  canary-clean: 2288.6-2332.5 (A median 2310.2) vs 2303.4-2334.8 (B median
  2330.1) = +0.86%, 7/8 B>=A-median, not fully separated; 8k even.
  Retained on kernel evidence (pure store removal, zero arithmetic change)
  despite <1% timing. NEXT by ledger: HC up/down epilogue screen continues
  (V2 barrier-merge candidate; then the down kernel), or the routed-expert
  weight-layout prototype; slow-session diagnostic as filler. rocprofv3 -i
  counter collection is BROKEN in this nix wrapper (silent no-op, even
  -- echo) — do not burn time on PM counters; kernel-trace mode works.
- 2026-10-06 ~10:15 HCF1 RETAINED: HC inject partials fused into the F16
  combine (gufo worktree uncommitted on 7d6379f; serve binary 31127d4c does
  NOT contain it — deploy decision pending; prod still down). The plain and
  peer F16-norm combines emit the next mixer's inject partials from the
  norm they write (LDS-staged row — aliased over the peer kernel's dead
  s_row stage — replayed with the inject pass's exact grouping/loads/
  reduction -> byte-identical partials; separate sibling kernels keep the
  non-emitting codegen untouched). Two build lessons encoded: (1) mirroring
  the reference's SOURCE SHAPE (staged wq register array -> v loads ->
  s-major adds) was required for bit-exact dots — a differently-shaped loop
  with identical arithmetic reassociates under -ffast-math; (2) the
  MoE-fused combine's norm compiles to v_fma_mixlo/hi_f16 (mul chain fused
  with F16 rounding) so NO source-level replay can match it — variant
  closed after two pinned orderings failed. Gates: hc_mix_ops_test exact
  (37/2048, plain+peer, aliased buffers); single-host dump MD5 identical;
  canonical member checksums every session; route-fires verified via
  profiled kernel counts (inject pass 376->184 @8k single-host; emitting
  combine +1.7%/call -> net ~+0.8% single-host, in session noise). PAIRED
  TP2 A/B (canary-gated interleaved, 4 discards): @32k A 2261.9-2290.8
  (median 2269.1) vs B 2321.6-2332.1 (median 2329.3) = +2.65%, 4/4 FULL
  SEPARATION; @8k +2.3% 2/2; decode flat. Final-binary pair smoke 2330.6
  tok/s canonical. gpu_probe sqrtf shim RE-ADDED (diagnostic target only;
  Nix libm needs GLIBC_2.43). Evidence: evidence/prefill-triage/hcf1/
  (SUMMARY.md + all pair logs). Probe inventory: probe-g1 (A, =7d6379f),
  probe-hcf1 (B, =worktree, both hosts). NEXT by ledger: short-K HC up/down
  epilogue efficiency screen (HC up = DenseF16GEMM<256,128,1,4,2,8,true>
  835ms/rank + mixer-down W8A8 662ms/rank @32k), or extend HcCombineMoeF16
  only via a kernel redesign (mixed-fma norm blocks source mirroring).
- 2026-10-06 ~08:45 KV1 KV-CACHE QUANTIZATION CLOSED (user decision:
  performance-inconclusive, not worth pursuing; evidence/kv1-drift/).
  Drift pilot: every 1-byte KV format (int8 + F16 scale per 32/16/8
  block, per-element E4M3; V-only and K+V; draft cache untouched) drifts
  8-22% top-1 flips / mean KL 4e-3..5e-2 across synthetic+real 16k-38k
  histories (428 teacher-forced full-vocab rows each; arm A bit-identical
  to the unmodified tree; flips occur even at reference margins >0.7).
  TP2's accepted reduction noise is 98.4% top-1 / KL 0.0055, so no format
  qualifies as a default. Speed: writer overhead ~0 (32k single-host
  prefill medians A/v8/e4m3 = 1557/1550/1558 tok/s, n=6 interleaved);
  reader ceiling from attn_bench (sparse WMMA largely DRAM-bound:
  8.80ms @32k vs 3.36ms dense with only 1.65x the keys) is ~+3-4%
  prefill absolute best case, ~+1-2% realistic after in-reader dequant,
  decode <=0.75% -> a repeatable speedup gate is unreachable. Pilot code
  (GUFO_QFN_KV_PILOT kernels/plumbing + gpu_probe sqrtf shim) REVERTED;
  rebuilt gpu_probe md5 == probe-g1 reference (a9bf4547). Profiling note
  for the next campaign: the ledger's ~838ms "router/indexer dense"
  family is actually the fused HC UP projection (DenseF16GEMM
  <256,128,1,4,2,8,true> grid 40x4096, 1504 calls @32k) — with HC combine
  (peer 2481ms), mixer down W8A8 (662ms), mix epilogue F16 (386ms
  inject-only pass) and up (835ms), the HC chain is ~4.4s/rank of the
  14.4s pass. NEXT: HCF1 — fuse the next mixer's HC inject partials into
  the combine kernel that writes the F16/Q8 norm (removes the separate
  HcMixEpilogueF16<false> pass, ~386ms/rank ~= 2.7% ceiling, helps single
  AND dual); then short-K HC up/down epilogue efficiency screen.
- 2026-10-06 00:50 S1 IMPLEMENTED + REJECTED, tree back to f61f17a (docs
  7d6379f). The mixer-down N-split was built end-to-end and proven BIT-EXACT
  twice (operator: HcDownHalfGemm F32-out + SiluScale + HcLoAssemble
  narrowing == fused HcDownF16Gemm bits at 96/2049 tokens; e2e: canonical
  member checksums through the real pair path). Required transport surgery:
  StartTagged/FinishTaggedPartial in Communicator + tbstream (a started
  exchange finished by payload match instead of FIFO order — needed because
  the mixer's lo exchange interleaves with the pair loop's part-boundary
  StartPartials; the naive FIFO acquire popped the wrong exchange and
  poisoned with "size mismatch"). PERF COLLAPSED: 32k prefill 1490 tok/s
  (-35%): the transport's SINGLE STAGING WORKER serializes each mid-part
  1.25MB lo exchange behind the preceding 20MB boundary staging (~10ms),
  and the host-side finish blocks the queue engine -> ~5ms exposed per
  mixer x 1504 calls ~= 7s vs the 260ms GPU saving. The queued (GPU-staged)
  path can't be used mid-pair (requires zero started exchanges). LESSON
  (measurement): the probe's CollectiveTrace decorator must delegate new
  transport virtuals — the first 4 "A/B" pairs were accidental A/A until a
  profile showed 0 assembly-kernel launches; always verify a gated route
  fires via a kernel counter, not just checksums. Ledger updated: exchange-
  based sharding of the replicated family CLOSED on this transport until
  small mid-part frames can be GPU-staged (pair-loop boundary exchanges ->
  queued path, or a second staging channel). Reverted everything except the
  knowledge; rebuilt probe md5 == probe-g1 (a9bf4547). Probe inventory:
  probe-g1 = CURRENT tree, probe-s1 = the rejected split (md5 5fc7fa25,
  both hosts), probe-c2 reference. Evidence: evidence/prefill-triage/
  s1-split/ (logs incl. the 3136-exchange trace, prof-s1). REMAINING
  LEVERS: single-host kernel-level speedups (help both) + the transport
  staging redesign (its own project). Serve binary unchanged (f61f17a
  code, 31127d4c — the split never reached a serve build).
- 2026-10-05 23:30 G1 RETAINED + R1 CLOSED (gufo @ f61f17a: 40a7e82 GDN
  finer row-split + docs; serve 31127d4c deployed+smoked both hosts).
  G1: block-size-templated GdnRowSplitKernel; TP2's 24-value-head geometry
  dispatches 128-thread/32-row blocks (96 vs 48 blocks; lanes/DPP per row
  unchanged -> bit-exact, checksums canonical every session; gdn_ops_test
  gained the 8k/24v-head geometry). Kernel mean 1466.6->1294.5us (-11.7%,
  matched profiles, routed/attention/combine controls <=0.2%); e2e @32k
  +0.19/+1.04/+0.60/-0.47/+0.03/+0.99 (5/6, median +0.40%); 8k even
  (clean pairs -0.9%/-0.3%, final matched pair 2305.3 vs 2305.2 — early
  spread was drift). R1a REJECTED: bounding the paired/wide epilogue loops
  by live_tok_tiles (dropping only write-guarded dead tiles) SLOWED the
  routed kernels +6-9%/call and -2.45% e2e — the runtime bound perturbed
  the unrolled live path; epilogue tails are not the family's bound (3rd
  scheduling/tiling rejection; it is weight-streaming-bound, ~360ms excess
  vs ideal). R1b deprioritized (see prefill-scaling item 8). S1 LEDGER
  written (docs/s1-sharding-ledger.md): the one positive candidate is the
  N-split of the fused HC mixer down (~260ms/rank, +1.8% ceiling,
  bit-exact, +1.4GB wire under existing overlap); post-bottleneck splits
  bandwidth-dead; router/indexer needs a shape-capture pass. SERVE SMOKE
  (62k MTP): prefill 1983.8 tok/s (in the 1880-2117 band), decode 71.5
  @100% acceptance, 0 errors; IDLE CHECK PASSED (2.5min idle then request
  -> 200) — and this RETRACTS yesterday's "rank1 idle control-channel
  drop" bug: the archived serve-r0.log shows event=shutdown_requested
  signal=15 at exactly 21:22:59, i.e. my own kill -TERM propagated; no
  spontaneous idle failure exists. Slow-mode canary fired ~40% of tonight's
  sessions (warmup 2750-3085ms) — discard/retry discipline held; GPU idle
  38C, no wedge signatures after 20+ probe sessions + 1 serve cycle.
  Probe inventory: probe-c2 (1f5ddd2 ref), probe-g1 (=current tree 40a7e82),
  probe-r1a (rejected variant). Evidence: evidence/prefill-triage/g1-r1a/
  (incl. prof-g1/prof-r1a DBs). NEXT: S1 mixer-down N-split per ledger,
  then router/indexer shape capture.
- 2026-10-05 22:00 P1+C2 SHIPPED (gufo @ 1f5ddd2: 6c8dd0a launch plan /
  3b85080 LDS-staged combine + docs; serve d02fddc4 deployed both hosts,
  smoke OK). P1: the TP2 2560x3072 attn_out/ssm_out GEMMs reuse the
  one-host 2560x6144 five-row-tile launch order — bit-exact, +0.4/+0.9/+0.7%
  @32k (3/3), 8k even. C2: HcCombinePeerVec4Kernel stages local+peer rows
  in 20KB LDS (same bytes, every reduction unchanged) — bit-exact (operator
  exact 37/2048), +1.8/+1.6/+0.7/+0.3% @32k over the P1 twin (4/4 clean
  pairs, median +1.15%), 8k even, kernel mean 1713.5->1643.7us (-4%,
  controls <=1.4%); the honest mechanism is smaller than the traffic
  thesis (re-reads not all DRAM-bound). Steady-state ref @32k now ~2265.
  OPS ISSUES hit while deploying the smoke: (1) gufo serve now REQUIRES
  --tp-control-token; (2) my pgrep pattern "[n]ewbin/gufo" never matched
  "./gufo serve" cmdlines -> I misread a HEALTHY serving pair as dead and
  killed it — always pgrep "[.]/gufo serve" or by PID; (3) a duplicate
  serve launch OOM'd (kernel oom-kill + hipMalloc fail + 10s page-alloc
  stalls that made ssh/tool calls hang — check for an existing serve before
  launching); (4) NEW OPEN BUG: rank1 exited ~1min idle after two correct
  requests with "TP control peer closed the channel" (rank0 alive, no
  errors its side; control = tbnet 10.55.0.1:18516) — investigate before
  long-idle production; (5) benign known WARN at every gufo exit on
  hostB: ring_interrupt_active "interrupt for RX ring 10 already
  disabled" during tbstream_dev_stop (upstream-report material). Pair left
  healthy: streams attached, no wedge signatures. Probe inventory: probe-m1
  (=fb0dc77 reference), probe-p1 (+P1), probe-c2 (=current tree, +C2),
  plus the H1/C1 variants. NEXT by ranking: G1 (GDN 4-block row-split for
  TP2's 48-block geometry), R1 (routed experts w/ captured routing), S1
  cost model.
- 2026-10-05 21:00 H1 REJECTED + C1 CLOSED (gufo @ 3954b59 docs-only; code
  back to fb0dc77 state; serve binary c4d3dce unchanged/current):
  H1 (fixed-geometry hidden=2560 Vec4 combine specialization, both plain
  and peer kernels): bit-exact by construction, operator test exact at
  37/2048; ISA had shown 41% integer/select ops — but kernel moved only
  -1.4%/call (1690 vs 1714us, matched slow-mode profiles, expert-GEMM
  controls +-1-2%) and end-to-end 2/3 pairs <=+1%, single-host even
  (1543-1588 both arms @32k). Combine is latency/bandwidth-bound, not
  issue-bound. Reverted; EXPERIMENTS row recorded. C1 (chunk-width
  re-sweep, single-variable builds, canary pairs, checksums canonical):
  1536 lanes -3.7/-5.0% (exchanges 1632->2208); 3072 lanes +1.3/+0.9/+1.4%
  @32k (exchanges ->1248) but -2.1% @8k (ragged 2048-tail chunk). 2048
  retained; depth-adaptive width only for long-prompt-dominated workloads.
  Probe binaries on both hosts: probe-h1 (=H1, reverted upstream),
  probe-lane1536/3072 (=sweep variants, kPrefillChunkTokens back to 2048 in
  tree), probe-m1 = CURRENT reference. Remaining ranking after today:
  #1 combine via different mechanism (residual layout/store width — bigger
  design), #2 replicated-family split w/ cost model (HC low-rank caps it),
  #3 single-host kernel work (only route to 3k).
- 2026-10-05 19:30 STAGE 1 CORRECTED + ALIAS FIX + STAGE 1b SHIPPED (gufo @
  fb0dc77: d118e85 alias guard, c9293ea kv-only paired catch-up, fb0dc77
  probe warmup/MTP; evidence/prefill-triage/ab-stage1b/): (1) Stage-1's
  "wins 8/8, median +1.9%" MIS-COUNTED (4 pairs) and both arms measured the
  process's FIRST prefill — an A/A with identical binaries swung ±5%, so the
  gain was noise. Probe now warmups first (A/A ±0.7%); steady-state Stage-1
  effect vs a no-fusion twin: median +0.9% (kernel-level: AddRows 631ms
  gone, fused 2605 vs 2826ms pair). Residual SLOW MODE ~1-in-5 sessions
  (-6% BOTH ranks, whole session incl warmup => memory placement, not
  first-touch); warmup doubles as canary (retry pairs >2.3s). Steady-state
  refs @32k: non-MTP ~2235 tok/s, MTP ~2180. (2) ALIAS BUG in Stage-1 found
  by audit + reproduced: moe_observer path passed block_out as BOTH local
  input and summed output of HcCombinePeerVec4Kernel; every stream re-reads
  the row => peer added twice; corrupted ALL MoE hashes + member checksum on
  the diagnostic path (production unaffected, no observer). Fix: wrappers
  refuse block_summed==block_local (observer takes the separate add); fixed
  binary's --moe-input-hashes stream + checksums IDENTICAL to pre-Stage-1
  baseline, ranks agree. (3) STAGE 1b RETAINED: ForwardPair catch-up now
  kv_only (unpaired prefill's path; next full forward rebuilds residual).
  Gates: paired tp_probe --split MTP logits bit-identical both ranks; member
  tokens == pre-change binary == greedy AR decode; 4104-token seam covered.
  Perf (canary-gated pairs): +3.0/+1.2% @8k, +1.5/+2.9% @32k, median +2.1%,
  4/4 pairs. Probe also gained --mtp-model (paired MTP harness: DecodeStep
  greedy, rank agreement via logit hashes). Serve nix rebuild in flight.
  NEXT: H1 combine specialization (2605ms family, #1 at 17.4%; ISA first),
  then C1 chunk/lane sweep (now measurable at ±0.7%), P1 shape table.
- 2026-10-05 17:20 STAGE 1 SHIPPED (fused peer-add combine, gufo @ 9addbac,
  evidence/prefill-triage/ab-stage1/): SplitReduce.finish->acquire; paired
  lane's combine folds the peer partial in registers (HcCombinePeerVec4Kernel,
  bit-exact by construction; f16/q8+narrow fallback to plain add; MoE observer
  gets summed row written back). Gates: operator test exact at 37/2048 tokens;
  end-to-end member checksums + both-rank logit hashes IDENTICAL to baseline
  binary. Interleaved 4x4 pair A/B @32k: candidate 2190-2221 vs base
  1941-2174, wins 8/8 paired, median +1.9%, per-run sigma ~7 vs ~108 (variance
  collapse; base's bad sessions disappear). Traffic saving modest: the 20MiB
  block buffer is largely MALL-cache resident. Also corrected triage (docs/
  prefill-scaling.md): down_e-exchange idea was WRONG (100MiB payload, window
  overflow), excess %s double-counted MoeEpilogue, WaitValue 10.6ms was the
  small-prompt/decode path not prefill; memory-copy trace: 1538x20MiB D2H
  staging copies = 32.25GB @2.11GB/s during the 15.3s pass, 98.5% concurrent
  with compute (~1-2% contention tax). Next (Stage 2): combine-kernel
  efficiency (>=210MiB/boundary at ~168GB/s vs ~240 ceiling, ~800ms/rank
  headroom, helps single AND dual), then replicated dense/W8A8/mix family
  (~1.2s/rank, cost-model first — HC mixing is low-rank, capping exchange-
  based splits). 3k needs kernel-level single-host work. Ops: /root/probe-base
  + /root/probe-cand on both hosts for A/B; nix serve rebuild in flight.
- 2026-10-05 16:10 PREFILL SCALING TRIAGE COMPLETE (docs/prefill-scaling.md,
  evidence/prefill-triage/): dual prefill is GPU-COMPUTE-bound, not
  link-bound (97.6% GPU busy at 32k; WaitValue 0.07%; exchanges fully
  hidden). Each rank burns 72% of a single host's GPU time per token; the
  30.7% excess splits into: combine-family lost fusion 35% (TP2 disables the
  fused MoE-epilogue-into-combine, executor.cpp:1892), TP2-only kernels
  (AddRows 631ms + MoeEpilogue 546ms @32k) 26%, un-halved replicated dense/
  W8A8/mix families 26%, expert/GDN split inefficiency 13%. Matched-curve
  tooling: new single-host prefill_probe on feat/tp2-tbstream (same synthetic
  walk + Session::Sync as tp_batched_probe). Speedups: 0.91x @2k (pair LOSES
  below one chunk), 1.43x @8k, 1.31-1.41x @32k, 1.32-1.36x @61k. MTP catch-up
  neutral on dual (serve 1880-2117 non-MTP vs 2030 MTP @62k); single-host
  MTP prefill FASTER at 8k/32k (+9.5/+3.3%, unexplained depth interaction).
  Variance ±6%/session -> interleave future A/B rounds. Next lever (est.
  2.3-2.4k tok/s): exchange halved-F16 down_e instead of F32 MoE output to
  restore fused combine; then splitting the replicated HC/indexer dense
  family (~2.6k ceiling). 3k needs single-host kernel work. rocprofv3 DBs in
  /tmp/opencode/prof-{dual,single}/ (copy before reboot).
- 2026-10-05 12:15 PERFORMANCE BASELINE (baseline-B kernel + rebased
  gufo b7ee0a9, GPUs forced high both hosts, evidence/perf-baseline/):
  | Metric | Today | Historical | Verdict |
  |---|---|---|---|
  | prefill 8K x2 (probe) | 2212 tok/s | 2164 | +2.2% |
  | prefill 61K single (probe) | 2149 tok/s | 2104.6 (serve) | +2.1% |
  | decode MTP serve, counting | 68.6 cold / 73.2 warm tok/s | 61.6 | +12/+19% |
  | decode non-MTP (sanity) | ~34 tok/s | 33.8 | parity |
  | exchange p50 10 KiB (decode shape) | 27.1 us | 26.9 | parity |
  | exchange p50 5 MiB (prefill shape) | 1393 us | 1296 | +7% (no serving impact) |
  Zero poison/timeouts/wedge errors in every run; dmesg clean. The
  user-facing ~2100pp/~65tg targets are MET or EXCEEDED. Gotcha that
  cost two runs: the headline decode numbers REQUIRE --speculative mtp
  --mtp-model /models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf; without
  them serve decodes at the non-MTP ~34 tok/s (matches history exactly).
  gpu-performance.service failed on hostB after the reboot — restart it
  before any measurement (clocks park at 600 MHz otherwise).
- 2026-10-05 11:50 SESSION MILESTONES (all on frozen baseline-B):
  - **B0x10 serve-restart block: 9/10 clean, 0 link episodes** (run-
    20261005-105857). The 1 failure was rank SKEW (rank0's 10th model
    load ~68 s behind; rank1's 30 s deadline expired; rank0 then got
    EPIPE instantly — clean failure semantics, no wedge). Fixed by
    adopting the verbs transport's slow-peer deadlines (180 s exchange,
    240 s GPU wait) in tbstream.
  - **Stage 3.1 REBASE DONE**: feat/tp2-tbstream = origin/feat/tp2-rdma
    (2833856) + 3 commits (transport+hardening, conflict-marker fix,
    rank0-listens fix). Conflicts resolved: serve.cpp (upstream RoCE
    device/port options + rdma_ready logging folded into our transport
    switch + retry window), verbs.cpp (upstream RoCE selection kept),
    TP2.md (union). Lesson: verify `grep '<<<<<<<'` after scripted
    conflict resolution — one marker survived into a commit.
  - **Stage 2.2 transport fixes shipped**: busy-poll poll() POLLERR
    yield, EOF -> prompt kStreamClosed (2 s), reader-lifetime buffer
    leak-instead-of-UAF, buffered-reader grow carries unread bytes,
    slow-peer deadlines. Loop-mode + A7/A18/B0 x2 all clean on the
    rebased binary (run-20261005-11xxxx).
  - **Serve smoke END-TO-END OK**: rebased gufo (nix .#tp2-tbstream,
    b7ee0a9) pair over tbstream on baseline-B: ranks paired first try,
    chat completion answered, zero poison/timeouts. Binaries: /root/
    newbin/gufo both hosts + cmake-build probes redeployed to hostB.
  - Remaining: keepalive-notification bug fix (next kernel window);
    Stage 4 deferred items; gufo-prod re-enable decision (criteria:
    N clean serve restarts — evidence so far 9/10 with the one failure
    explained+fixed); bench-grade numbers.
- 2026-10-05 ~10:55 STAGE-1 DECISION GATE PASSED. Baseline-B (thunderbolt
  6F77780E, stream BB7FD35F, both hosts LOADED and verified):
  **A7 0/3 fail, 0/3 episodes; A18 0/3; A17 0/3; B0 0/3 — all clean**
  (run-20261005-105121, autonomous postboot block). Same A7 traffic was
  3/3 fail + 3/3 episodes on the old build the same morning. The upstream
  CLOSE/drain rework fixed the teardown-under-truncation wedge trigger.
  ADOPT baseline-B. KERNEL FROZEN for this window (per plan). n=3 caveat:
  A7x10 validation block running; honest bounds: 0/3 => ~63% upper CI,
  0/10 => ~26%.
- 2026-10-05 ~10:50 REGRESSION FOUND+FIXED (ops, not kernel): after the
  dual reboot BOTH hosts hit "thunderbolt-net: failed to allocate Rx
  HopID" — heal-watch's bringup (auto -1 HopIDs, takes 8/9) won the race
  against tbnet's probe (needs HopID 8). Fixed: bringup.sh now pins
  in/out_hopid=16/16 (never contends); recovery was stream rmdir +
  thunderbolt-net SERVICE driver rebind (safe; NOT the NHI). tbnet +
  stream both healthy at 16/16. postboot-validate.service DISABLED after
  its successful one-shot run.
- 2026-10-05 (session start): plan finalized per user: healing stays in;
  ONE reboot authorized for the kernel baseline; after that kernel frozen
  and recovery takes precedence (120 s recovery deadline, no auto-reboot,
  user away for hours). Execution begins at Stage 0.
- 2026-10-05 10:34 Stage-0 RESULT (run-20261005-102932, current kernel
  0CAA7B4C/2572A827, tx_coalesce=N): **A7 3/3 workload-fail + 3/3 link
  episodes; A18 (A7 + --pairing teardown ONLY) 0/3 clean; A17 0/3 clean;
  B0 gufo 0/3 clean.** A18 receiver fully delivered all 67 MiB each run
  (2.35/5.21/5.13 GB/s). Timeline (A7-c1 dmesg): sender finishes in ~14
  ms, early close -> SENDER-side hop-deactivation config timeouts
  (05:55:20-27) -> receiver still mid-drain hangs -> remote timeout kill
  -> hostB teardown errors follow. **Mechanism: teardown while the peer
  still has the stream mid-flight / tail unconsumed.** "Both sides >=1
  MiB syscalls" is DEAD as the explanation; the completion barrier is
  the discriminator. Explains: serve wedges at restart (rank0 _Exit
  after peer loss = teardown under desync), long-lived sessions safe,
  A17's earlier "fix" (it had the barrier all along).
- 2026-10-05 11:0x Stage-1: candidate-b built clean first try
  (thunderbolt 6F77780E, stream BB7FD35F: upstream-next stream.c
  wholesale [busy-poll lock fix, RX polling, CLOSE write-side handling,
  framing-error -EIO, upstream stop ordering] + hop rotation + ida fix
  re-applied; nhi.c stock + tb_ring_poll_pending + descriptor-write-
  in-poll; healing xdomain/tb unchanged; NO coalescer, NO teardown
  reorder). Deployed to /lib/modules + initramfs BOTH hosts (backup:
  /root/modules-backup-preB on each). hostB rebooted first: running
  6F77780E/BB7FD35F, 0 ida warnings, healer active. Cross-version ping
  smoke (old hostA <-> new hostB): p50 16.3 us, both RC=0.
  postboot-validate.service ARMED on hostA: at next boot it waits for
  pair health then reruns ARMS=A7,A18,A17,B0 ROUNDS=3 autonomously ->
  evidence/postboot-*.log. hostA reboot is the last action of this
  session; validation results are on disk for the next session.

