#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# heal-watch.sh — last-mile healer for the TBSTREAM self-heal chain.
# The kernel (v6 module) detects a wedged peer, forces a link
# disconnect/retrain and re-enumerates the XDomain. The recreated
# thunderbolt0 interface comes up unconfigured and the stream configfs
# entries are gone; this daemon re-applies the network + stream setup
# whenever the peer becomes unreachable but the XDomain is back.
RANK=${1:-0}
PEER=$TBNET_BASE.$(( 1 - RANK + 1 ))
LOG=$(dirname "$0")/../evidence/heal-watch.log
echo "[$(date +%F\ %T)] heal-watch start rank=$RANK peer=$PEER" >> $LOG

while sleep 2; do
  # Enforce the serving prerequisites EVERY pass, not only on peer death.
  # (2026-10-06 incident: after a single-host reboot the heal bringup
  # aborted at an EBUSY HopID write, leaving busy_poll=0 on a live stream
  # — decode exchanges silently ran the interrupt-paced path.)
  for g in /sys/kernel/config/thunderbolt/stream/*/gufo; do
    [ -d "$g" ] || continue
    if [ "$(cat $g/busy_poll 2>/dev/null)" != "1" ]; then
      if echo 1 > $g/busy_poll 2>/dev/null; then
        echo "[$(date +%F\ %T)] repaired busy_poll=1 on $g" >> $LOG
      else
        echo "[$(date +%F\ %T)] WARN: busy_poll not writable on $g (holds $(cat $g/busy_poll 2>/dev/null))" >> $LOG
      fi
    fi
  done
  # A missing stream with the XDomain up (e.g. this host rebooted while
  # the peer stayed up, so the peer ping never fails) needs a full
  # bring-up, which is idempotent.
  if ! ls /sys/kernel/config/thunderbolt/stream/*/gufo >/dev/null 2>&1; then
    if ls /sys/bus/thunderbolt/devices/ | grep -qE '^[0-9]+-[1-9]$'; then
      echo "[$(date +%F\ %T)] stream missing, xd present: re-applying bringup" >> $LOG
      timeout 90 bash $(dirname "$0")/bringup.sh $RANK >> $LOG 2>&1
    fi
    continue
  fi
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
