#!/usr/bin/env bash
# Phase-3 probe pair runner: run qwen38_flash_next_tp_probe / _gpu_probe on
# the TP2 pair (rank 1 on strix2 over ssh, rank 0 here), or gpu_probe
# single-host on rank A. Both ranks run byte-identical probe binaries
# (sha256 printed by every run; verified in the window logs).
#
# Usage:
#   ple-native-probe.sh pair  TAG BINARY [ARGS...]   # world-size-2 run
#   ple-native-probe.sh single TAG BINARY [ARGS...]  # world-size-1, rank A
#   ple-native-probe.sh sha                          # probe binary digests
#
# PLE_EV / PLE_PREFIX override the evidence dir and log-name prefix
# (defaults: .../ple-native/phase3 and 03).
set -u
. /root/strix-dual-exp/scripts/env.sh
: "${HOST_B:=strix2}" "${TBNET_BASE:=10.55.0}"
EV="${PLE_EV:-/root/strix-dual-exp/evidence/ple-native/phase3}"
PFX="${PLE_PREFIX:-03}"
BOOT=18517
TPA=/root/goal-worktrees/2026-10-17-ple-native-bf16/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
TPB=/root/ple-native
R0=$TPA/qwen38_flash_next_tp_probe
R1=$TPB/qwen38_flash_next_tp_probe
G0=$TPA/qwen38_flash_next_gpu_probe
G1=$TPB/qwen38_flash_next_gpu_probe
mkdir -p "$EV"

stamp() { date '+%F %T%z'; }

sha() {
  sha256sum "$R0" "$G0"
  ssh root@$HOST_B "sha256sum $R1 $G1"
}

# Quote args for the remote command line: plain tokens pass through,
# anything with whitespace/specials travels as base64 in an env assignment
# and is decoded inside a quoted command substitution.
REMOTE_ENV=""
REMOTE_ARGS=""
build_remote() {
  REMOTE_ENV=""
  REMOTE_ARGS=""
  local i=0 a b64
  for a in "$@"; do
    i=$((i + 1))
    if [[ "$a" =~ ^[A-Za-z0-9_./:=%,+@-]+$ ]]; then
      REMOTE_ARGS="$REMOTE_ARGS $a"
    else
      b64=$(printf '%s' "$a" | base64 -w0)
      REMOTE_ENV="$REMOTE_ENV P$i=$b64"
      REMOTE_ARGS="$REMOTE_ARGS \"\$(printf %s $b64 | base64 -d)\""
    fi
  done
}

wait_rank1() {
  for t in $(seq 1 60); do
    ssh root@$HOST_B "pgrep -f 'qwen38_flash_next_(tp_probe|gpu_probe).*--tp-rank 1' >/dev/null" || return 0
    sleep 2
  done
}

pair() {
  local tag="$1"; shift
  local bin="$1"; shift
  local binb
  case "$bin" in
    "$R0") binb=$R1 ;;
    "$G0") binb=$G1 ;;
    *) echo "unknown binary $bin" >&2; return 2 ;;
  esac
  local r0log="$EV/$PFX-probe-$tag-r0.log" r1log="$EV/$PFX-probe-$tag-r1.log"
  echo "[$(stamp)] PAIR tag=$tag bin=$bin args=$*"
  sha256sum "$bin"; ssh root@$HOST_B "sha256sum $binb"
  build_remote "$@"
  ssh root@$HOST_B "$REMOTE_ENV nohup $binb $REMOTE_ARGS --tp-world-size 2 --tp-rank 1 \
    --tp-bootstrap-host $TBNET_BASE.1 \
    --tp-bootstrap-port $BOOT > /root/ple-native/$PFX-probe-$tag-r1.log 2>&1 & echo \$!" \
    > /tmp/opencode/ple-p3-rank1.pid
  sleep 2
  local t0=$(date +%s)
  "$bin" "$@" --tp-world-size 2 --tp-rank 0 --tp-bootstrap-port $BOOT > "$r0log" 2>&1
  local rc=$?
  local t1=$(date +%s)
  wait_rank1
  scp -q root@$HOST_B:"/root/ple-native/$PFX-probe-$tag-r1.log" "$r1log"
  echo "[$(stamp)] PAIR tag=$tag rc0=$rc wall=$((t1-t0))s"
  echo "-- rank0 $r0log"; tail -6 "$r0log"
  echo "-- rank1 $r1log"; tail -6 "$r1log"
  return $rc
}

single() {
  local tag="$1"; shift
  local bin="$1"; shift
  local log="$EV/$PFX-probe-$tag-w1.log"
  echo "[$(stamp)] SINGLE tag=$tag bin=$bin args=$*"
  sha256sum "$bin"
  local t0=$(date +%s)
  "$bin" "$@" --tp-rank 0 > "$log" 2>&1
  local rc=$?
  local t1=$(date +%s)
  echo "[$(stamp)] SINGLE tag=$tag rc=$rc wall=$((t1-t0))s"
  tail -6 "$log"
  return $rc
}

case "${1:-}" in
  pair) shift; pair "$@" ;;
  single) shift; single "$@" ;;
  sha) sha ;;
  *) echo "usage: $0 pair|single TAG BINARY [ARGS...] | sha" >&2; exit 2 ;;
esac
