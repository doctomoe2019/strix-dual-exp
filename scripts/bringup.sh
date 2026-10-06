#!/bin/bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Disciplined tbstream bring-up after reboot (per host).
# Usage: bringup.sh [rank]  (0 = hostA local, 1 = hostB local)
set -e
RANK=${1:-0}
PEER=$((1-RANK))
MYIP="$TBNET_BASE.$((RANK+1))"
PEERIP="$TBNET_BASE.$((PEER+1))"

# 1. tbnet IP + MTU
ip addr add $MYIP/24 dev thunderbolt0 2>/dev/null || true
ip link set thunderbolt0 mtu 9000

# 2. Discover the kstreamp service dir from sysfs (driver binding);
#    accept ANY router port (peer may enumerate as 0-1/0-2/0-3/0-4 after
#    a physical port change)
SVC=$(for d in /sys/bus/thunderbolt/devices/*.*; do
  case "$d" in *domain*) continue;; esac
  [ "$(readlink $d/driver 2>/dev/null | awk -F/ '{print $NF}')" = "thunderbolt_stream" ] && basename "$d"
done | head -1)
[ -n "$SVC" ] || { echo "ERROR: no kstreamp service found under any router port"; ls /sys/bus/thunderbolt/devices/ | tr '\n' ' '; echo; exit 1; }
echo "service dir: $SVC"

# 3. Create the stream configfs under the CORRECT service dir.
#    EXPLICIT HopIDs 16/16: tbnet requires HopID 8 (TBNET_HOPID) and
#    probes whenever the xd enumerates; auto-negotiation (-1) takes 8/9
#    and wins that race whenever bringup runs first (observed 2026-10-05:
#    "thunderbolt-net: failed to allocate Rx HopID" on both hosts after
#    the dual reboot). 16 never contends.
BASE=/sys/kernel/config/thunderbolt/stream
mkdir -p $BASE/$SVC 2>/dev/null || true
mkdir $BASE/$SVC/gufo 2>/dev/null || true
# Writes to an already-attached stream can fail with EBUSY (observed
# 2026-10-06: the post-reboot heal aborted at the HopID line under set -e
# and busy_poll was never applied). A failed write is fine when the
# attribute already holds the target value.
set_attr() {  # path value
  if ! echo "$2" > "$1" 2>/dev/null; then
    local holds
    holds=$(cat "$1" 2>/dev/null)
    if [ "$holds" = "$2" ]; then
      echo "note: $1 already $2 (EBUSY write tolerated)"
      return 0
    fi
    echo "ERROR: cannot set $1=$2 (holds $holds)"
    return 1
  fi
}
set_attr $BASE/$SVC/gufo/in_hopid 16
set_attr $BASE/$SVC/gufo/out_hopid 16
# busy_poll=1: interrupt-free ring polling; the decode-shape exchanges
# need it (stream.c: "Instead of interrupts, busy poll the rings").
set_attr $BASE/$SVC/gufo/busy_poll 1

# 4. Wait for genuine attach (character device + O_NONBLOCK open succeeds)
for t in $(seq 1 12); do
  [ "$(stat -c %F /dev/tbstream0 2>/dev/null)" = "character special file" ] || { sleep 5; continue; }
  if timeout 4 python3 -c "import os; os.close(os.open('/dev/tbstream0', os.O_RDWR|os.O_NONBLOCK))" 2>/dev/null; then
    echo "ATTACHED-OK (t=${t})"
    ping -c1 -W2 $PEERIP >/dev/null 2>&1 && echo "peer-reachable" || echo "WARN: peer not reachable yet"
    exit 0
  fi
  sleep 5
done
echo "ERROR: stream did not attach"
exit 1
