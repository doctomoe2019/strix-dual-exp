# TBSTREAM wedge investigation — sanitized log

Hardware: two identical AMD Strix Halo mini-PCs (board SHWSA-class, USB4
Barlow Ridge JHL9580 "TB5 80G" NHI rev 84, router NVM 61.83), back-to-back
USB4 link, custom `thunderbolt_stream` out-of-tree module (configfs
streams, E2E rings) used as the transport for two-rank TP2 LLM serving
(gufo). Kernels identical (7.3-rc3, `iommu=pt`); BIOS both on the latest
vendor image (the A/B test below forced an upgrade of one host; the exact
vendor/URL is not relevant to the findings).

All entries below are sanitized (hosts: hostA/hostB; addresses are
placeholders). Timestamps local to the experiment sessions.

## 1. The failure

After a serving session ends and its stream is released, one host's NHI
control plane wedges:

```
thunderbolt 0000:67:00.0: 0: timeout reading config space 0 from 0x12
thunderbolt 0000:67:00.0: 0:1: hop deactivation failed for hop 0, index 9
```

- Every subsequent config transaction times out (4 built-in retries).
- DMA data path unaffected until teardown; NHI stays PCI-alive (config
  space readable via setpci).
- Only a full host reboot clears it.
- The XDomain properties exchange dies; tbnet dies with it.

## 2. What it is NOT (all falsified experimentally)

| Hypothesis | Test | Result |
|---|---|---|
| HopID reuse (dirty E2E state) | wrapping per-session HopID rotation [R-series] | wedge on fresh hop, clean on reused → false |
| Gen4 signal margin | force Gen3 retrain (`gen3_link_cap`) | wedge at Gen3 cycle 1 [F1] → false |
| BIOS difference | flash both hosts to same BIOS, 12 cycles [B-series] | wedge followed neither → false |
| Software roles (rank0/rank1) | role-swap probe pair [S-series] | wedge stayed with the host → false |
| Power-on order | boot hostA alone first [G-series] | wedge host unchanged → false |
| gufo exit choreography | graceful-exit closure + 41-arm C/HIP discriminator marathon | 41/41 clean vs serve ~100% → false |

41 external discriminator arms (raw dual-fd wire harness, parked readers,
spin kernels, staggering, tbnet concurrency) all ran clean: the wedge needs
the full serving environment (model load + GPU coherent DMA + device
kernels) to appear, but is not *caused* by any user-space close pattern.

## 3. What it IS

Controlled cable experiments across three active 80 Gb/s cables:

| Arrangement | Wedging host | Rate |
|---|---|---|
| cable 1 as-shipped | hostA | ~25%/restart |
| cable 2 (certified), end X at hostA | hostA | instant |
| cable 2 flipped | hostB | instant |
| cable 3, end X at hostA | hostA | 1/7 |
| cable 3 flipped @Gen3 | hostA | instant |
| cable 3 flipped @Gen4, boot-order-flipped | hostA | instant |

**The only invariant across all layouts: which physical cable end sits at
which host.** Every cable had one "bad" end; the host on that end wedges.
Mechanistically consistent with an active-cable retimer/e-marker end
defect corrupting in-band USB4 config traffic in one direction,
rate-independently.

## 4. Recovery primitives discovered (the path to self-healing)

- Physical unplug/replug clears the wedge (a link *disconnect* resets the
  router config relay; a speed-change retrain does **not**).
- The driver's resume path never rescans ports; routers only notify on
  transitions. Plug events that arrive while the NHI is runtime-suspended
  are delivered as wakeups only and the hotplug processing is dropped.
- A stale unplug event can be processed *after* the new plug event
  (inversion), leaving a healthy link with no XDomain on either side and
  nothing scheduled — permanent silent idle.
- Sync control requests (`tb_cfg_request_sync`) issued from the XDomain
  state work against an unresponsive peer can hang the whole thunderbolt
  workqueue (D-state worker; cancel path never completes). Found the hard
  way by v2 of the fix. Quarantined by design in the final version.
- `LANE_ADP_CS_1_LD` (Lane Disable) is the software equivalent of
  unplugging the cable: set it, the LC drops the link; clear it, the link
  retrains and both routers' config relay state resets.

## 5. The fix (v6, shipped)

1. **Keep-alive probe** (xdomain.c): enumerated XDomains re-read peer
   properties every 2.5 s (change-notification suppressed for keep-alive
   reads). Stock xds schedule nothing in steady state, so a wedged peer is
   otherwise invisible.
2. **Failure streak**: 8 consecutive failed probes (~8 s) with a
   have-seen-success guard (boot-time handshake failures never trigger)
   fires the recovery, capped at 5 attempts per episode.
3. **Lane-Disable disconnect** on system_wq: LD set for 2 s, then cleared.
   The wedged peer sees a real unplug/replug.
4. **Rescan after stale unplug** (tb.c): recreates the XDomain after the
   link returns (also fixes the human-replug inversion case).
5. **heal-watch** (userspace, systemd): re-applies tbnet addressing and
   stream configfs setup on the freshly re-enumerated interface.

Failed intermediate designs (kept here so they are not retried):
v1 give-up counting (too slow + ABI break via struct field — keep
counters file-static), v2 ERROR-state UUID restart (state-work hang, see
upstream report), v3 threshold above one retry pass (never fires),
v4 Link State Change request packets (die in the wedged channel),
v5 detection via the peer's dying notification (2-in-3 race).

## 6. Validation

- Module v6 + healer on both hosts.
- 12-cycle storm at a 25% wedge arrangement: **3 wedges, 3/3 autonomous
  heals, 8 s each, zero reboots, cycling continued through all of them.**
- Post-run verification cycle clean; link full Gen4 40 Gb/s dual-lane.

## 7. Post-ship cleanup and hardening round two

Reverted as falsified: the Gen3 cap (`gen3_link_cap` module param).

Kept after a near-stock trial **regressed**: removing the HopID rotation
looked safe (it was falsified as the wedge *cause*), but with the stock
lowest-free allocator every post-heal re-attachment reuses the same HopIDs
and the wedge probability per teardown went from ~25% to near-deterministic
(heal-loop churn). Rotation is a *mitigation*, not a cure — reinstated
with a hop_count clamp.

Two further gaps found while validating the cleanup:

- **Boot-settle false positive**: a peer still finishing its boot is
  briefly unresponsive; the detector (armed after one handshake success)
  fired spurious disconnects. Fixed by arming only after 3 consecutive
  successful keep-alive probes.
- **Settle-wedge deadlock**: if the wedge strikes *during* the settle
  window, the XDomain never reaches ENUMERATED, the stock state machine
  parks in ERROR after one failed pass, and the detector never arms.
  Fixed by (a) an unarmed-fallback streak (~36 failed probes ≈ 100+ s)
  and (b) restarting discovery from ERROR instead of parking. Because
  the restart issues synchronous control requests that can, in a rare
  cancel-path race, stall a worker indefinitely, all XDomain protocol
  works now run on a dedicated ordered workqueue (`tb_xd_state`): a
  stall is quarantined to the handshake and can never freeze the
  domain workqueue (hotplug, tunnel management).

Final validated state: 12-cycle storm at a 58% wedge arrangement —
**7 wedges, 7/7 autonomous heals, 8 s each, zero reboots.**
