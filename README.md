# strix-dual-exp

**Two-rank tensor-parallel LLM serving over USB4v2, on a pair of AMD
Strix Halo hosts, with gufo.**

This repository collects the complete experience of building and
operating that setup: a custom kernel-level stream transport for
USB4/TB5 host-to-host links, the gufo-side TP2 integration, the
operational tooling that keeps the pair alive, and the investigation
that made the link resilient enough to serve from.

**[SETUP.md](SETUP.md) is the step-by-step guide to replicating the
whole pair from this repository** (kernel modules, stream bring-up,
healers, gufo build, qualification and the performance measurements),
verified end to end on 2026-10-05.

## The setup

- Two identical Strix Halo mini-PCs (AMD RYZEN AI MAX+ 395 class, 122 GB
  LPDDR5X), back-to-back USB4v2 link via Barlow Ridge (Intel JHL9580)
  80 Gb/s-class NHIs; trained at 40 Gb/s dual-lane symmetric
  (5 GB/s per direction).
- gufo serves one model as TP2: rank 0 bootstraps as listener, rank 1
  connects; all cross-rank traffic rides the stream transport instead of
  a NIC.
- Kernel side: an out-of-tree `thunderbolt_stream` module (built from
  this repo, `kernel/build-tree/`) that turns the stock Linux USB4
  XDomain protocol into a frame-oriented, E2E flow-controlled pair of
  DMA rings per session, plus a small set of core-driver patches for
  resilience (below).
- Model used throughout development/qualification: Qwen3.8-Flash-Next
  UD Q4_K_XL via gufo's TP2 batched probe harness.

## What we have achieved so far

**1. A low-latency, high-bandwidth stream transport over USB4v2.** Two
hosts, frame-oriented sessions on the NHI DMA rings, E2E flow control,
zero-copy character-device interface — no NIC and no kernel IP stack in
the serving path:

| Transport | Round-trip latency | Bulk bandwidth (wire ceiling 5 GB/s) |
| --- | --- | --- |
| tbnet — kernel IP over the same link | 67–80 µs (bare ping RTT) | 3.6–4.0 GB/s (TCP) |
| verbs — RDMA NIC baseline | 24 µs (10 KiB exchange) | — |
| **tbstream — this work** | **p50 22–23 µs · p99 34–42 µs** (10 KiB exchange) | tuned: **≈5 GB/s, line rate** · serving config: 1.0–1.1 GB/s (software pacing for latency, not a hardware limit) |

The stream matches the RDMA latency baseline with no RDMA hardware at
all — a round-trip 10 KiB exchange over USB4v2 is faster than a bare
ping through tbnet's kernel IP stack. At the serving end the GPU writes
its partial sums straight into ring buffers, so there are no sockets
and no copies. Provenance in `docs/performance.md`.

**2. gufo serving over it** — two-rank tensor parallelism with all
cross-rank traffic on the stream transport, Qwen3.8-Flash-Next Q4:

| Throughput (tok/s) | Single host | Dual-host TP2 | Gain |
| --- | ---: | ---: | ---: |
| Prefill pp @32k depth | 1421.9 | **2329–2332** ⁴ | **+64 %** ⁴ |
| Prefill pp @ ~61–65k depth | 1316.7 | **2104.6 – 2195.5** | **+60 – 67 %** |
| Decode tg @ ~61–65k, mixed corpus | 32.6 | 62.6 ¹ | ~+92 % ¹ |
| Decode tg @ ~61–65k, repetitive corpus | 46.1 | 62.6 ¹ | ~+36 % ¹ |

⁴ Post-HCF1 (2026-10-06): the F16-norm combine now also emits the next
mixer's inject partials, so the mixer's separate inject pass disappears —
canary-gated paired-probe A/B @32k moved 2269 → 2329 tok/s median
(**+2.65 %**, 4/4 clean sessions, full separation; single-host cells
untouched above are the published one-host measurements). Decode ms/step
was flat across the A/B (35.3–36.0 both arms), so every decode figure
below is unchanged. The ~62k serve harness was not remeasured.

**Full progression, measured 2026-10-05; TP2 prefill refreshed
2026-10-06 (HCF1)** (post-wedge-fix stack: baseline-B kernel + rebased
gufo; one binary everywhere; cold prompt cache;
~62 k-token prompts for prefill and a counting prompt for decode; GPUs
forced high; `evidence/perf-baseline/` and `evidence/prefill-triage/hcf1/`):

| Configuration | Prefill @ ~62 k depth (tok/s) | Decode, counting (tok/s) | Decode, coding (tok/s) |
| --- | ---: | ---: | ---: |
| Single host, non-MTP | 1511 | 24.3–27.2 ² | prompt-insensitive ³ |
| Single host, MTP | 1540 | **56.6–66.1** (82 % accepted) ² | **44.9–54.6** (64–77 % accepted) |
| Dual-host TP2, non-MTP | **2330** ⁴ (was 2030 serve / 2149 probe ¹) | 34.0–35.5 (serve) · 57.8 (probe, 2-member batch) | prompt-insensitive ³ |
| Dual-host TP2, MTP | **2330** ⁴ (was 2030 serve / 2149 probe ¹) | **68.6 cold / 73.2 warm** (unchanged ⁴) | **50.5–66.9** (52–75 % accepted) (unchanged ⁴) |

The coding prompt (a binary-search function in Python) sits between
counting and prose, as intended — and it widens the dual-vs-single MTP
gap: +13 % worst-pairing to +42 % cold-vs-cold (63.9/44.9), versus
+4–21 % on counting. Speculation hides the compute advantage on
near-deterministic text; code leaves enough per-token compute for the
halved per-host weights to matter. Acceptance itself varies per run
even under greedy sampling because gufo adapts the MTP draft depth from
cycle timings (observed 133–196 accepted of 256 on the identical
prompt).

¹ Prefill rate is MTP-independent (speculation is decode-only); the
single-host 1511→1540 spread is run-to-run variance. Dual prefill via
gufo serve = 2030; the host-only probe harness measures 2149 at 61 k
(no HTTP/scheduler in the path).

² Single-host decode was re-measured after a sanity challenge:
non-MTP is stable per session (27.2 twice in a clean session; 24.3
right after a deep-prefill session — GTT state), while MTP-mode
varies ±8 % across sessions (56.6 cold / 61.8 warm / 66.1 best,
acceptance steady at 82 %). Mode-matched dual-vs-single gains at the
midpoints: prefill **+34 %** (2030/1511, serve harness), decode
non-MTP **+35 %** (≈35/≈26), decode MTP **+16 %** (≈71/≈61, band
+4–21 %) — tensor-parallel splitting halves each host's weight
traffic, which mostly benefits the bandwidth-bound non-speculative
paths. MTP correctness was cross-checked with a prose prompt: 36.0
tok/s at 48 % acceptance (single host), the expected
acceptance-driven drop.

³ Non-speculative decode has no acceptance dependence — the token
rate is pure forward time, so the counting-prompt figures hold for
any prompt class.

Zero errors and zero link events across every run. Note: the headline
decode figures require `--speculative mtp --mtp-model
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf`; without MTP serve decodes at
the ~24 (single) / ~34 (dual) tok/s non-speculative rates.

- Single-host best (depth 0) is 1628.5 pp / 59.2 tg-repetitive — the
  long-context rows above are where TP2 pulls far ahead.
- The rows above are MTP-mode on gufo's bench corpora; mode-matched
  single- and dual-host numbers including the non-MTP rates are in the
  progression table below (same day, same binary).
- The pair is also a capacity unlock: **Q8 at 262 144-token context**
  loads as TP2 shards in ~36 s and does not fit one 122 GB host at
  all.

¹ The dual-host tg numbers come from the TP2 qualification harness
(width-1, 32-token decode windows, synthetic prompts), not gufo's
benchmark corpora with timed tg128 windows — treat the tg gains as
directional. Prefill is compute-bound and depth-matched, so those
gains are solid. **Benchmark-grade dual-host runs (gufo's bench
harness, both corpora, tg128, multi-user) are the pending
measurement** — see Ongoing work.

**3. A link that survives its own hardware — and a wedge trigger that
is now fixed.** The Barlow Ridge host-to-host link has a failure mode
where stream teardown desyncs one host's NHI control plane until reboot
(see `docs/wedge-investigation.md`). Two layers now address it:

- **Root cause found and fixed (2026-10-05):** the trigger is a stream
  teardown while the peer still has the stream mid-flight — proven by an
  interleaved ablation where the identical small-frame workload went
  3/3-fail with an early close and 0/3 with a delivery-confirmed close.
  Adopting the upstream CLOSE/drain rework (plus our HopID fixes; build
  `kernel/candidate-b/`, "baseline-B") eliminates the reproducer:
  0/3 + 0/10 episodes where the old build failed 3/3 the same day, and
  9/10 clean serve-restart cycles with the one failure explained and
  fixed (rank model-load skew, now covered by the verbs transport's
  slow-peer deadlines).
- **Self-healing for whatever remains:** detection, forced link
  disconnect/retrain, re-enumeration and re-configuration happen
  autonomously in ~8 s, with serving continuing through the event.

## Ongoing work

- **Prefill scaling** (see [docs/prefill-scaling.md](docs/prefill-scaling.md)):
  the dual-host ceiling moved from 2.0–2.2 k to **~2.33 k tok/s** with the
  HC inject-into-combine fusion (HCF1, 2026-10-06, +2.65 % paired @32k);
  the remaining gap to ideal scaling is triaged — GPU compute that TP2
  does not halve, not the USB4 link, which sits 97 %+ hidden behind
  compute. **Next ranked candidate:** the short-K HC up/down epilogue
  screen — the fused HC up projection (~835 ms/rank @32k) plus the
  mixer-down W8A8 (~662 ms/rank) close out a ~4.4 s/rank hyperconnection
  chain. **Closed routes** (do not re-propose without new mechanism):
  exchange-based sharding of the replicated family (S1: mid-part
  exchanges serialize in the transport's single staging worker, −35 %),
  KV-cache 1-byte quantization (KV1: numerics 5–10× accepted TP2 noise,
  packed-reader speed ceiling ~+1–2 % prefill, decode ≤0.75 %), and the
  MoE-combine inject-emission variant (its norm compiles to
  mixed-precision `v_fma_mix*_f16`; no source-level replay is
  bit-exactible). Ranked fixes and their estimated ceilings are in the
  doc.
- **Deploy HCF1 to serving**: the retained fusion lives in gufo's
  committed branch (`4c68409`) but the deployed serve binary predates it —
  rebuild `.#tp2-tbstream`, redeploy both hosts, smoke, then refresh the
  serve-side numbers when `gufo-prod` returns.
- **Wedge residuals**: the primary trigger (teardown while the peer is
  mid-stream) is fixed by baseline-B; what remains is to quantify any
  cable-end-correlated residue with controlled cable-identification
  blocks (the earlier "cable-only" attribution was retired — the
  `0x12/0x16` timeout lines are local hop-table entries, not retimer
  routes), and to fix the keepalive notification-suppression bug in the
  healing xdomain code at the next kernel window.
- **Keep hardening the self-heal**: the settle-window recovery path is
  design-fixed but not yet observed end-to-end in the wild; the
  control-channel stall race quarantined behind the XDomain workqueue
  is worth root-fixing (see `docs/upstream/`).
- **Continue the optimization program** to fully exhaust whatever
  performance is still gainable in the transport and serving path —
  starting with benchmark-grade dual-host numbers (gufo's bench
  harness over the pair, tg128 windows, both corpora) and multi-user
  batching, so the decode-side gains are measured as rigorously as
  the prefill side.

## What is in here

- `kernel/` — the out-of-tree `drivers/thunderbolt` build tree (core +
  stream module) and, for review, the same changes as a three-patch
  series against vanilla Linux 7.3-rc3:
  1. rescan XDomain after a stale unplug event;
  2. XDomain self-healing: keep-alive probe, failure streak, forced
     Lane-Disable link disconnect, and a dedicated quarantine workqueue
     for the XDomain state machine;
  3. stream HopID rotation plus a teardown-order fix mirroring the
     upstream CVE-2026-74691 thunderbolt-net fix.
- `gufo/` — the user-space side as one WIP patch against gufo's
  `feat/tp2-tbstream` branch (diff vs the `feat/tp2-rdma` base, sanitized):
  the stream transport, the TP2 probe tooling, graceful-exit hardening,
  and the retained prefill optimizations (fused peer combine, TP2 launch
  plans, GDN row-split, HC inject emission into the combine).
- `scripts/` — day-2 operations: link bring-up, pair qualification and
  storm validation, forensics capture, and the `tbstream-heal@`
  last-mile healer (systemd unit included).
- `docs/` — architecture notes, the performance record (recorded pp/tg/
  latency tables with provenance), the full experiment log of the link
  robustness investigation, and an upstream report draft for a control
  channel stall found on the way.

## Operating picture

The pair runs unattended: a healer unit on each host re-applies network
and stream setup after any link re-enumeration, and the kernel-level
self-healing recovers from the one failure mode this hardware exhibits
(a control-plane desync triggered by certain active cables at stream
teardown — see `docs/wedge-investigation.md`). In the final validation
storm (58% wedge-rate arrangement) the system autonomously healed
**7/7 wedges in 8 s each, zero reboots**, with serving cycles continuing
throughout.

## Credits

This project stands on a great deal of upstream work:

- The **Linux USB4/Thunderbolt driver** ( drivers/thunderbolt ) by
  Andreas Noever and Intel Corporation contributors — our stream module
  is an extension of that code base, and the build tree here carries
  their sources under their original licenses and headers.
- **Mika Westerberg** and **Alan Borzeszkowski**, upstream maintainers,
  whose public guidance (notably the dirty-HopID direction) and queued
  work informed the analysis: the CLOSE-handling rework, the
  interrupt-mask shadow-copy fix, and the busy-poll lock fix on the
  `next` branch of the upstream tree.
- The **upstream thunderbolt-net teardown fix for CVE-2026-74691**,
  which our stream teardown-order patch deliberately mirrors.
- **gufo, and Sven Neuhaus in particular** — the serving framework this
  transport was built for. This project's `feat/tp2-tbstream` branch
  builds directly on his upstream TP2 work: the
  rank-1-without-scheduler startup, the TP2 pair collectives error
  propagation, and the TP control-byte refactors. `gufo/` here is a
  patch against that branch, regenerated from the committed tree.
- Vanilla **Linux 7.3-rc3** is the base kernel; `kernel/patches/`
  expresses our entire divergence from it.

See `docs/wedge-investigation.md` for the detailed experiment record.

## License

[MIT](LICENSE) for this repository's own content — documentation, scripts,
and the gufo WIP patch (itself a derivative of the MIT-licensed
[gufo](https://github.com/neuhaus/gufo), with attribution in the credits
above). The `kernel/` tree is a derivative work of the Linux kernel
(thunderbolt driver) and is GPL-2.0-only, as its upstream headers state;
our kernel changes are published under GPL-2.0 with them.
