#!/bin/bash
# Disciplined tbstream bring-up after reboot (per host).
# Usage: bringup.sh [rank]  (0 = hostA local, 1 = hostB local)
set -e
RANK=${1:-0}
PEER=$((1-RANK))
MYIP="10.55.0.$((RANK+1))"
PEERIP="10.55.0.$((PEER+1))"

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
echo 16 > $BASE/$SVC/gufo/in_hopid
echo 16 > $BASE/$SVC/gufo/out_hopid
echo 1 > $BASE/$SVC/gufo/busy_poll

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
