# SETUP.md — replicating the TP2-over-USB4v2 pair from this repo

Everything needed to reproduce the setup end to end: two stock Strix
Halo-class hosts, one USB4v2 cable, this repository, and the gufo fork.
End state: a self-healing two-rank tensor-parallel LLM serving pair with
prefill ~2100–2200 tok/s and MTP decode ~65–73 tok/s at full depth.

Everything below was verified on the pair on 2026-10-05. Placeholders:
`hostA` (rank 0, listener), `hostB` (rank 1, connector). In our repo
scripts `hostB` defaults to the ssh alias `hostB` (see
`scripts/env.sh`).

## 0. Prerequisites

- **Hardware**: two hosts with a USB4v2/TB5-class NHI (we use Intel
  Barlow Ridge JHL9580 80G on otherwise-identical AMD Strix Halo
  boards, 122 GB RAM) and one USB4 cable. Any trained rate works;
  40 Gb/s dual-lane gives ~5 GB/s per direction.
- **OS**: Ubuntu 26.04 on both hosts, interconnect over direct
  ssh (key-based) hostA↔hostB. A second (LAN/VPN) path to both hosts
  is strongly recommended — it is your lifeline during reboots.
- **Kernel**: Linux 7.3.0-070300rc3 (`7.3.0-070300rc3-generic`), with
  matching `linux-headers-*` installed. Boot cmdline must include:

  ```
  iommu=pt ttm.pages_limit=31457280 ttm.page_pool_size=31457280
  ```

  GRUB gotcha we hit: mainline rc entries sort *below* release kernels —
  after installing the kernel, pin `GRUB_DEFAULT` to the exact advanced
  entry in `/etc/default/grub` on both hosts, or the next boot silently
  falls back to the distro kernel.
- **Models**: identical files on both hosts (we keep them under
  `/models/`): the split main model shards and the MTP draft
  (`mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf`). Verify with `md5sum`.
- **Nix** (Determinate installer is fine) on hostA — gufo builds come
  from its pinned flake toolchain.

## 1. Kernel modules (from `kernel/candidate-b/`)

`kernel/candidate-b/` is the current baseline ("baseline-B"): stock
7.3-rc3 thunderbolt core + the upstream `westeri/thunderbolt` next-branch
stream.c (busy-poll lock fix, RX polling, write-side CLOSE handling,
framing-error -EIO) + our HopID rotation, HopID-ida fix, and the XDomain
self-healing chain. (`kernel/build-tree/` is the older pre-B baseline,
kept for history; do not deploy it.)

Build on either host with matching headers:

```sh
make -C /lib/modules/$(uname -r)/build M=$PWD/kernel/candidate-b modules
```

Expected `modinfo -F srcversion`: thunderbolt `6F77780E…`,
thunderbolt_stream `BB7FD35F…`. Deploy on BOTH hosts:

```sh
cp kernel/candidate-b/thunderbolt{,_stream}.ko \
   /lib/modules/$(uname -r)/kernel/drivers/thunderbolt/
depmod -a && update-initramfs -u
```

**Changing these modules requires a reboot — NEVER `rmmod` this stack on
a live pair and never PCI-unbind the NHI (both hard-freeze the hosts).**
Reboot hostB first, confirm it is back over the out-of-band path, then
hostA. Keep a rollback copy (`modules-backup/`) before every swap.

## 2. Post-boot bring-up (per boot, or scripted — step 3)

```sh
# hostA:
ip addr add 10.55.0.1/24 dev thunderbolt0; ip link set thunderbolt0 mtu 9000
# hostB:
ip addr add 10.55.0.2/24 dev thunderbolt0; ip link set thunderbolt0 mtu 9000

# Stream (both hosts; rank argument differs):
bash scripts/bringup.sh 0     # hostA
ssh hostB 'bash <repo>/scripts/bringup.sh 1'
```

`bringup.sh` discovers the kstreamp service directory, creates the
configfs stream and pins **in/out HopID 16/16** and `busy_poll=1`.
The explicit HopIDs matter: auto-negotiation (`echo -1`) takes HopID 8,
which `thunderbolt-net` requires — if bring-up wins that race at boot,
tbnet fails with "failed to allocate Rx HopID" (we hit exactly this).
Recovery if it happens anyway: rmdir the configfs stream dirs, unbind/
rebind the `thunderbolt-net` *service* driver (safe — not the NHI),
re-run bringup.

Health check after bring-up:

```sh
ping -c1 10.55.0.2                      # tbnet data path
timeout 3 bash -c 'exec 9<>/dev/tbstream0 && echo OPEN-OK'   # each host
dmesg | grep -c "ida_free called"       # must stay 0
```

## 3. Keep-alive services (one-time install)

```sh
cp scripts/tbstream-heal@.service /etc/systemd/system/
systemctl enable --now tbstream-heal@0    # hostA (@1 on hostB)
```

Plus two perf/latency units we run (create once):

```ini
# /etc/systemd/system/gpu-performance.service   [Service] Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo high > $f; done'
# /etc/systemd/system/pm-qos-latency.service   [Service] Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/power/pm_qos_resume_latency_us; do echo 100 > $f; done'
```

Enable both. The GPU one matters for benchmarks: the GPUs idle-park at
600 MHz and short MTP bursts never ramp on their own — and the unit can
fail silently after a reboot, so `systemctl is-active` it before any
measurement.

The kernel-side heal chain (keepalive probe, failure streak, forced
Lane-Disable retrain, rescan) ships inside the module; `heal-watch.sh`
is the userspace last mile (re-applies IPs + stream after a heal).

## 4. gufo

On hostA, clone gufo's `neuhaus/gufo` fork, then apply this repo's
rebased transport patch (or your own branch; ours is
`feat/tp2-tbstream` = `origin/feat/tp2-rdma` + the patch):

```sh
git clone https://github.com/neuhaus/gufo && cd gufo
git checkout -b feat/tp2-tbstream origin/feat/tp2-rdma
git am <repo>/gufo/0001-feat-tp2-tbstream-wip.patch

nix build '.#tp2-tbstream'        # serve binary — NOTE: the DEFAULT
                                   # nix package builds WITHOUT TP2;
                                   # the tp2-tbstream output is required
```

Probe binaries (host-only microbenchmark + the TP2 batched probe):

```sh
nix develop -c cmake --preset gpu-tp2-tbstream
nix develop -c cmake --build build/gpu-tp2-tbstream \
    --target tbstream_probe qwen38_flash_next_tp_batched_probe
# ship the batched probe (+ tbstream_probe) to hostB at the same path
```

Self-test any time without hardware: `tbstream_probe --mode loop`.

Create `scripts/env.sh` (gitignored; see `env.sh.example`):

```sh
HOST_B="hostB"        # ssh alias of rank 1
TBNET_BASE="10.55.0"  # tbnet /24
```

## 5. Qualify the pair (correctness + robustness)

The reference block — the same interleaved arms we gate every change
with:

```sh
ARMS=A7,A18,A17,B0 ROUNDS=3 bash scripts/ablate.sh
```

- `A7` small-frame bulk with an early close (the historical wedge
  reproducer), `A18` the same with a delivery-confirmed close, `A17`
  A18 + write batching + buffered reads, `B0` a full gufo serve cycle
  (model load → exchanges → teardown).
- Expected on baseline-B: `episodes=0 fails=0/3` for every arm, unique
  run dirs under `evidence/run-*/` with both ranks' logs and a
  4-class verdict (workload / link / recovery / identity).
- The driver aborts a campaign if a heal exceeds 120 s (recovery-first:
  never let an experiment outrun the healer).

## 6. Measure performance

GPU clocks first (see step 3). Then, via `scripts/probe-pair.sh`:

```sh
# Prefill at depth (single 61k-token member):
… --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
   --context 65536 --max-tokens 8 --prompt-tokens-0 61000
# → "prefill_tokens_per_s" ≈ 2100–2200

# Exchange microbench (decode/prefill shapes):
… --context 4096 --max-tokens 8 --allreduce-bench 512
# → rows=1 p50 ≈ 27 µs, rows=512 p50 ≈ 1.4 ms
```

Serve decode (the headline number — **MTP flags are required**, without
them you measure the ~34 tok/s non-speculative rate):

```sh
<result>/bin/gufo serve llm \
  --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --speculative mtp --mtp-model /models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
  --tp-world-size 2 --tp-rank 0 --tp-transport tbstream \
  --tp-bootstrap-port 18515 --tp-control-port 18516 \
  --tp-control-token SECRET --context 65536 --sessions 1
# rank 1 (hostB) adds: --tp-rank 1 --tp-bootstrap-host 10.55.0.1
```

Then any chat completion against `http://hostA:8080/v1/...`; the usage
block reports `completion_tokens_per_second` (expect ~65–73 tok/s on a
counting prompt; prose is acceptance-bound and lower). Prompt text rides
in files (`--prompt-file-0`), not inline args — the pair-runner passes
args through ssh unquoted.

Reference numbers (2026-10-05, baseline-B + rebased gufo): prefill 2212
tok/s @8k-probe / 2149 @61k; MTP decode 68.6 cold / 73.2 warm; exchange
p50 27.1 µs @10 KiB. Full table with provenance: `README.md` and
`docs/performance.md`; raw logs `evidence/perf-baseline/`.

## 7. Operations runbook

- **Never** `rmmod` this stack or PCI-unbind the NHI on a live pair;
  module changes go through reboot, hostB first.
- A failed run is data: the harness yields to the healer; resume only
  after ping + stream-open are green and dmesg is quiet. 120 s without
  recovery ⇒ stop and capture `scripts/wedge-forensics.sh`.
- Split-brain after a single-host reboot (keepalive green, tbnet dead):
  `ip link set thunderbolt0 down; sleep 2; up` on the *peer* — the link
  re-enumerates and heals (~30 s), no reboot needed.
- Wedge accounting in dmesg: `timeout reading config|deactivation
  failed` counts are the link-episode signal the harness uses.
- Rollback a kernel change: restore the saved `.ko` pair, `depmod -a`,
  `update-initramfs -u`, reboot hostB then hostA.

## Repo map

| Path | Contents |
|---|---|
| `kernel/candidate-b/` | current baseline-B module sources (deploy this) |
| `kernel/build-tree/` | pre-B baseline (history; do not deploy) |
| `kernel/patches/` | older divergence vs vanilla 7.3-rc3 (historical) |
| `gufo/` | the gufo transport as one rebased patch vs `feat/tp2-rdma` |
| `scripts/` | bring-up, healers, pair-runners, ablation harness, forensics |
| `docs/` | performance record, wedge investigation, upstream drafts |
| `evidence/` | gitignored run outputs (unique per-block dirs) |
| `TODO.md` | the live experiment plan + decision log |
