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

