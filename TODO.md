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

