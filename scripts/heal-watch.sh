#!/usr/bin/env bash
# heal-watch.sh — last-mile healer for the TBSTREAM self-heal chain.
# The kernel (v6 module) detects a wedged peer, forces a link
# disconnect/retrain and re-enumerates the XDomain. The recreated
# thunderbolt0 interface comes up unconfigured and the stream configfs
# entries are gone; this daemon re-applies the network + stream setup
# whenever the peer becomes unreachable but the XDomain is back.
RANK=${1:-0}
PEER=10.55.0.$(( 1 - RANK + 1 ))
LOG=$(dirname "$0")/../evidence/heal-watch.log
echo "[$(date +%F\ %T)] heal-watch start rank=$RANK peer=$PEER" >> $LOG

while sleep 5; do
  if ping -c1 -W1 $PEER >/dev/null 2>&1; then
    continue
  fi
  # Peer unreachable: if the XDomain exists, the kernel heal chain has
  # (re)enumerated it — re-apply network + streams.
  if ls /sys/bus/thunderbolt/devices/ | grep -qE '^[0-9]+-[1-9]$'; then
    echo "[$(date +%F\ %T)] peer dead, xd present: re-applying bringup" >> $LOG
    timeout 90 bash $(dirname "$0")/bringup.sh $RANK >> $LOG 2>&1
  else
    echo "[$(date +%F\ %T)] peer dead, no xd (kernel heal pending)" >> $LOG
  fi
done
