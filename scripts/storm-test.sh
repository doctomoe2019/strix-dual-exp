#!/usr/bin/env bash
# Storm test v2: cycle probes until wedge; then poll self-heal markers.
. "$(dirname "$0")/env.sh"
LOG=$(dirname "$0")/../evidence/storm-log.txt
: > $LOG
mark() { echo "[$(date +%H:%M:%S)] $*" >> $LOG; }
errs1() { dmesg | grep -cE "timeout reading config|deactivation failed"; }

mark "storm v2 start (module 58DFA308E3DA892B7B5E95E)"

# Phase 1: cycle until wedge
for TAG in U1 U2 U3 U4 U5 U6 U7 U8 U9 U10 U11 U12 U13 U14 U15 U16 U17 U18 U19 U20 U21 U22 U23 U24 U25; do
  OUT=$(bash $(dirname "$0")/probe-pair.sh $TAG --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --context 4096 --max-tokens 16 2>&1 | grep -E "R1-RC=|errs|ping=")
  mark "cycle $TAG: $(echo $OUT | tr '\n' ' ')"
  E1=$(errs1)
  E2=$(timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"' 2>/dev/null)
  if [ "${E1:-0}" != "0" ] || [ "${E2:-0}" != "0" ]; then
    mark "WEDGE at $TAG (hostA=${E1:-?} hostB=${E2:-?}) — self-heal watch starts"
    break
  fi
done
if [ "${E1:-0}" = "0" ] && [ "${E2:-0}" = "0" ]; then mark "no wedge in 25 cycles"; exit 0; fi

# Phase 2: poll local markers every 5s for 300s (no ssh in hot loop)
T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt 300 ]; do
  sleep 5
  P=$(ping -c1 -W1 10.55.0.2 >/dev/null 2>&1 && echo ok || echo dead)
  RT=$(dmesg | grep -c "forcing link retrain")
  EL=$(( $(date +%s) - T0 ))
  echo "[$(date +%H:%M:%S)] t+${EL}s ping=$P local-retrains=$RT" >> $LOG
  if [ "$P" = "ok" ]; then
    sleep 5
    P2=$(ping -c1 -W1 10.55.0.2 >/dev/null 2>&1 && echo ok || echo dead)
    if [ "$P2" = "ok" ]; then
      mark "RECOVERED after ${EL}s without reboot"
      OUT=$(bash $(dirname "$0")/probe-pair.sh POST-HEAL --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --context 4096 --max-tokens 16 2>&1 | grep -E "R1-RC=|errs|ping=")
      mark "post-heal cycle: $(echo $OUT | tr '\n' ' ')"
      mark "self-heal VERDICT: success"
      exit 0
    fi
  fi
done
mark "NO RECOVERY in 300s — self-heal failed"
