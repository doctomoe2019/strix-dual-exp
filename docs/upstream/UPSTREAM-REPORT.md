# Upstream report draft: thunderbolt_stream teardown wedges v2 NHI control plane

> STATUS 2026-10-03 17:25: **WITHHELD — DO NOT SEND YET.**
> The discriminator session refuted the premise below: a minimal dual-fd
> harness reproducing the serve wire pattern (2 GB/direction bidirectional,
> 20 MiB frames, gufo pacing, raw _exit close with parked or running reader,
> staggered/simultaneous, with concurrent tbnet) runs 14/14 CLEAN. The wedge
> only occurs in the full gufo serving environment (GTT model load + GPU
> coherent DMA buffers + device-side spin kernels) and jams the rank whose
> exit path skips graceful teardown. Until we can reproduce it without gufo
> (next session: HIP-linked wedge-repro variant), this report has no repro
> to offer upstream. The misc_open pile-up section stands on its own and
> can be reported separately.

To: linux-usb@vger.kernel.org, Mika Westerberg, Alan Borzeszkowski
Subject: thunderbolt: stream: NHI control plane wedge after closing a stream that carried heavy traffic (Barlow Ridge, v2 host interface)

## Platform

- 2x AMD Strix Halo hosts, back-to-back Barlow Ridge JHL9580 TB5 80G NHI
  (PCI 8086:5781, host interface caps v2), certified TB5 cable
- Linux v7.3-rc3 both ends, thunderbolt + thunderbolt_stream + thunderbolt_net
  (all in-tree; SW connection manager)
- Reproduces with the in-tree tools only: configfs stream + read/write traffic

## Symptom

After a stream session that moved multiple GB (e.g. 200 x 32 MiB frames,
or an LLM prefill workload pushing ~2 GB in ~30 s) is closed, the NHI
control plane jams on BOTH hosts simultaneously:

  thunderbolt 0000:67:00.0: 0: timeout reading config space 0 from 0x12
  thunderbolt 0000:67:00.0: 0:3: hop deactivation failed for hop 0, index 9
  thunderbolt 0-3: failed to send properties changed notification
  thunderbolt 0-3: failed read XDomain properties ...

Local (route 0) config reads time out, i.e. the control channel itself is
wedged, not just the peer link. tbnet dies (carrier lost), XDomain
properties exchange fails permanently. Only a reboot of either host
recovers (the surviving host's re-enumeration resets the link).

## Reproduction statistics (scripts attached)

- Random-interleaved open/close with no traffic: wedges around 50 cycles
- Same with 2 s idle before each close: wedges around 150 cycles
- Strictly ordered open/close (one host always first), no traffic,
  1-2 s stream lifetime: 300+ cycles clean
- One heavy-traffic session (~2 GB) then close: wedges on the FIRST close,
  regardless of drain time before close (tested 3 s and 30 s) and close
  ordering/separation between hosts (tested 2 s and 17 s apart)

This points at E2E flow-control credit state being corrupted by DMA path
teardown after sustained traffic - the same class as the AMD quirk added
in f1de1fc5f6 ("thunderbolt: Add quirk to reset host interface on DMA
path teardown for AMD USB4 routers", comment: "These AMD hosts may hang
the Tx ring when the DMA paths are torn down"). That quirk's
nhi_reset_interface() is v1-only: on our v2 Barlow Ridge the version
check returns early, so no equivalent hygiene exists. We also tested
extending the quirk table to Barlow: the quirk path fires
(tb_ctl_stop/start) but with the reset no-ops this only churns the
control channel and made the failure MORE reliable - reverted.

We additionally verified that E2E cannot simply be dropped from the
stream rings: with RING_FLAG_E2E removed the data path deadlocks under
bandwidth (write timeouts, peer RX not drained) - E2E appears to be the
end-to-end flow control the USB4STREAM protocol relies on.

## Secondary bug: misc_open pile-up

An open() of an unattached stream device blocks in fops_open (waiting
for attach) while misc_open holds the global misc mutex; every
subsequent open of ANY misc device then blocks in unkillable D state.
We reproduced one stuck gufo process blocking 5 unrelated shells.
Suggesting stream open use a nonblocking probe first, or misc_open not
serialize opens against driver-blocking open paths.

## Artifacts available on request

- Repro scripts (open/close race, drain variants, ordered variants,
  serve-context harness)
- Full dynamic-debug traces from both hosts across the fatal close
  (ring alloc/stop, path activation/deactivation, config-space timeouts)
- The fatal-close trace shows the first failure is a local route-0
  config read timing out inside tb_path_deactivate mid-deactivation

## Ask

Is a v2-appropriate E2E/teardown hygiene mechanism planned (equivalent
of REG_HOST_INTERFACE_RESET for v2 host interfaces), or guidance on where
the leaked state lives so we can prototype a targeted clear?
