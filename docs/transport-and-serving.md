# TP2 over USB4v2: transport and serving architecture

## Problem

Serve a single LLM with two-rank tensor parallelism across two hosts
that have no NIC fast enough for cross-rank traffic, but do have
80 Gb/s-class USB4v2 host interfaces (Barlow Ridge, JHL9580; our
link trains at 40 Gb/s dual-lane symmetric) that Linux
already knows how to drive.

## Transport

The stock kernel offers two usable building blocks on a USB4
host-to-host link:

- **tbnet** (thunderbolt-net): an IP network over the XDomain protocol.
  Fine for control traffic, too slow/heavy for bulk tensor exchange.
- **The NHI DMA rings** exposed by the thunderbolt driver: HopID-tagged
  TX/RX rings with optional end-to-end (E2E) flow control, normally
  consumed by tbnet's IP tunneling.

`thunderbolt_stream` (out-of-tree, `kernel/build-tree/stream.c`) takes
the second path and wraps it into something a userspace rank can treat
like a message pipe:

- One **session** = one configfs stream endpoint under the XDomain
  network service directory. Sessions are created/armed via configfs
  (`in_hopid`/`out_hopid` auto-allocation, `busy_poll` mode), then used
  through a `/dev/tbstream*` character device.
- A small **frame protocol** on top of the DMA rings: SOF/DATA/CLOSE
  frame markers, so both sides can distinguish payload from teardown
  and drain cleanly.
- **E2E flow control** with credit accounting between the paired rings;
  `busy_poll` trades interrupts for latency where the rank loop already
  spins.
- **Per-session HopID rotation** across the valid ring window (clamped
  to the NHI's actual hop_count): empirically a strong mitigation
  against teardown-time control-plane stalls on v2 host interfaces —
  see the investigation log.
- Teardown order mirrors the upstream thunderbolt-net fix for
  CVE-2026-74691: DMA paths are disabled while the rings are still
  live so in-flight data can drain, then the rings stop.

## Serving (gufo)

- gufo's TP2 path gets a `tbstream` transport next to its existing
  verbs/RDMA one (see `gufo/0001-*.patch`): rank 0 boots as a
  bootstrap listener, rank 1 connects, and the model's cross-rank
  exchanges (prefill/decode tensors, control) ride the stream session.
- Qualification uses the TP2 batched probe (same code path as serving,
  bounded token counts) driven pairwise by `scripts/probe-pair.sh`.
- Operational hardening learned the hard way is part of the patch:
  quiesced device close on exit, bounded teardown with a backstop —
  the graceful-exit closure described in the investigation log.

## Keeping it alive

- `scripts/bringup.sh` — per-host: tbnet addressing (MTU 9000 control
  plane) plus stream configfs arming; idempotent.
- `tbstream-heal@.service` + `heal-watch.sh` — last-mile healer: when
  the kernel-level self-heal re-enumerates the link, the recreated
  interface comes up unconfigured; the healer re-applies addressing and
  stream setup.
- Kernel-level self-healing (patch 0002) recovers the one failure mode
  this hardware exhibits. The full story, including the dead ends, is
  in `wedge-investigation.md`.

## Base and divergence

Base kernel: vanilla Linux 7.3-rc3. The entire divergence of the
kernel side is `kernel/patches/` (three patches). The stream module is
additive and out-of-tree. Everything else on these hosts is stock.
