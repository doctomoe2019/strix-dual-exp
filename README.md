# strix-dual-exp

Investigation and fix for the **USB4/Thunderbolt stream teardown wedge** on
Barlow Ridge (JHL9580) host interfaces: after closing a stream session that
carried heavy traffic, the NHI control plane of one host desynchronises and
every further config-space transaction times out until reboot. Pair of
identical AMD Strix Halo hosts, host-to-host USB4 link, custom
`thunderbolt_stream` kernel module used as a GPU-to-GPU transport.

Outcome: the wedge is hardware/cable correlated (per-cable-end, rate-,
BIOS-, host- and boot-order independent), but the *impact* is fully
recoverable in software — **self-healing in ~8 s without reboots**.

## Contents

- `kernel/patches/` — the three changes vs vanilla Linux 7.3-rc3:
  1. `0001` tb.c: rescan XDomain after a stale unplug event (covers
     unplug/plug event inversion around fast replugs; also the recovery
     path after a forced link retrain).
  2. `0002` xdomain.c: the self-heal chain — keep-alive properties probe
     every 2.5 s, consecutive-failure streak (armed after 3 successes,
     unarmed fallback ~36), and a Lane-Disable forced link disconnect
     (LANE_ADP_CS_1_LD) that clears the peer's wedged config relay.
     Discovery restarts from ERROR instead of parking, and all XDomain
     protocol works run on a dedicated quarantine workqueue so a stalled
     sync request can never freeze the domain workqueue (see
     `docs/upstream/` for the hang that motivates this).
  3. `0003` stream.c: per-session HopID rotation (with hop_count clamp)
     — empirically a strong wedge-rate mitigation on re-attach — plus
     the teardown order fix (paths before rings), mirroring the upstream
     CVE-2026-74691 thunderbolt-net fix.
- `kernel/build-tree/` — full out-of-tree `drivers/thunderbolt` sources
  (core + stream module) with the patches applied. Build with
  `kernel/build-deploy.sh`.
- `gufo/` — the user-space side as one WIP patch against gufo's
  `feat/tp2-tbstream` branch (`git diff HEAD`, sanitized): TP2 stream
  transport, probe tooling, graceful-exit closure.
- `scripts/` — operational tooling: link bring-up, pair probe runner,
  storm/self-heal validation, forensics capture, and the
  `tbstream-heal@.service` last-mile healer (re-applies network config
  and stream setup after the kernel-level heal).
- `docs/investigation-log.md` — the full sanitized experiment log.
- `docs/upstream/` — draft upstream report for the control-channel hang
  found on the way (D-state reproducer included).

## Results

Final validation (12 probe cycles, 58% wedge rate arrangement):
**12 cycles, 7 wedges, 7/7 autonomous heals, 8 s each, zero reboots.**

## Layout notes

- `scripts/env.sh` (gitignored) carries per-site values; see
  `env.sh.example`.
- `evidence/` (gitignored) holds local forensics captures.
