# strix-dual-exp

**Two-rank tensor-parallel LLM serving over USB4v2, on a pair of AMD
Strix Halo hosts, with gufo.**

This repository collects the complete experience of building and
operating that setup: a custom kernel-level stream transport for
USB4/TB5 host-to-host links, the gufo-side TP2 integration, the
operational tooling that keeps the pair alive, and the investigation
that made the link resilient enough to serve from.

## The setup

- Two identical Strix Halo mini-PCs (AMD RYZEN AI MAX+ 395 class, 122 GB
  LPDDR5X), back-to-back USB4v2 link via Barlow Ridge (Intel JHL9580)
  80 Gb/s-class NHIs, dual-lane Gen4.
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

| | tbnet (IP over the same link) | verbs (RDMA NIC baseline) | **tbstream (this work)** |
| --- | ---: | ---: | ---: |
| Round-trip latency | 67–80 µs (ping RTT) | 24 µs | **p50 22–23 µs, p99 34–42 µs** (10 KiB exchange) |
| Bulk bandwidth | 3.6–4.0 GB/s (iperf3 TCP) | n/a | 1.0–1.1 GB/s in serving config; **5.0 GB/s** @ 32 MiB frames |

The stream matches the RDMA latency baseline with no RDMA hardware at
all — a round-trip 10 KiB exchange over USB4v2 is faster than a bare
ping through tbnet's kernel IP stack. At the serving end the GPU writes
its partial sums straight into ring buffers, so there are no sockets
and no copies. Provenance in `docs/performance.md`.

**2. gufo serving over it** — two-rank tensor parallelism with all
cross-rank traffic on the stream transport, Qwen3.8-Flash-Next Q4:

| | Single host (benchmark corpus) | **Dual-host TP2 (recorded requests)** | Gain |
| --- | ---: | ---: | ---: |
| Prefill pp @ ~0 depth | 1628.5 tok/s | — | — |
| Prefill pp @ ~61–65k depth | 1316.7 tok/s | **2104.6–2195.5 tok/s** | **+60–67 %** |
| Decode tg, mixed @ ~61–65k | 32.6 tok/s | 62.6 tok/s (32-tok window, 77 % acceptance) | indicative only¹ |
| Decode tg, repetitive @ ~61–65k | 46.1 tok/s | 62.6 tok/s (same request) | indicative only¹ |
| Fits at 262 144-token context | Q4 only (87 GB) | **Q8 as TP2 shards**, loaded in ~36 s | — |

¹ The dual-host numbers so far come from the TP2 qualification
harness (width-1, short decode windows, synthetic prompts), not from
gufo's benchmark corpora with timed tg128 windows — so tg gains are
directional, not benchmark-grade. Prefill is compute-bound and
depth-matched, making those gains solid. **Running gufo's bench
harness on the pair is the pending benchmark** (see Ongoing work).

**3. A link that survives its own hardware.** The Barlow Ridge
host-to-host link has a failure mode where stream teardown desyncs
one host's NHI control plane until reboot (correlated with individual
cable ends; see `docs/wedge-investigation.md`). It is now fully
self-healing: detection, forced link disconnect/retrain, re-
enumeration and re-configuration happen autonomously in ~8 s, with
serving continuing through the event.

## Ongoing work

- **Avoid wedges in the first place**: the trigger is cable-end
  correlated and rate independent — a passive (non-retimed) certified
  cable is the leading candidate for a wedge-free physical layer.
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
  `feat/tp2-tbstream` branch (`git diff HEAD`, sanitized): the stream
  transport, the TP2 probe tooling, and graceful-exit hardening.
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
  patch against that branch, regenerable with `git diff HEAD`.
- Vanilla **Linux 7.3-rc3** is the base kernel; `kernel/patches/`
  expresses our entire divergence from it.

See `docs/wedge-investigation.md` for the detailed experiment record.
