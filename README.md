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
- `docs/` — architecture notes, the full experiment log of the link
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
- **gufo** and its authors — the serving framework this transport was
  built for (`gufo/` here is a patch against its `feat/tp2-tbstream`
  branch, regenerable with `git diff HEAD`).
- Vanilla **Linux 7.3-rc3** is the base kernel; `kernel/patches/`
  expresses our entire divergence from it.

See `docs/wedge-investigation.md` for the detailed experiment record.
