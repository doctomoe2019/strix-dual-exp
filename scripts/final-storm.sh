#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Final validation: continuous probe cycling THROUGH wedges.
. "$(dirname "$0")/env.sh"
# A cycle that wedges waits for autonomous recovery (kernel heal +
# heal-watch), then cycling continues. Verdict after N cycles.
LOG=$(dirname "$0")/../evidence/final-log.txt
: > $LOG
mark() { echo "[$(date +%H:%M:%S)] $*" >> $LOG; }
TOTAL=0; WEDGED=0; HEALED=0; CLEAN=0

for TAG in V1 V2 V3 V4 V5 V6 V7 V8 V9 V10 V11 V12; do
  E0=$(dmesg | grep -cE "timeout reading config|deactivation failed")
  E20=$(timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"' 2>/dev/null)
  OUT=$(bash $(dirname "$0")/probe-pair.sh $TAG --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf --context 4096 --max-tokens 16 2>&1 | grep -E "R1-RC=|ping=")
  TOTAL=$((TOTAL+1))
  E1=$(dmesg | grep -cE "timeout reading config|deactivation failed")
  E21=$(timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"' 2>/dev/null)
  if [ "${E1:-0}" != "${E0:-0}" ] || [ "${E21:-0}" != "${E20:-0}" ]; then
    WEDGED=$((WEDGED+1))
    mark "cycle $TAG: WEDGED ($(echo $OUT | tr '\n' ' ')) — waiting for autonomous heal"
    # Wait up to 120s for full recovery (ping)
    T0=$(date +%s); OK=0
    while [ $(( $(date +%s) - T0 )) -lt 120 ]; do
      sleep 5
      if ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1; then
        sleep 3
        if ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1; then OK=1; break; fi
      fi
    done
    if [ "$OK" = "1" ]; then
      HEALED=$((HEALED+1))
      mark "cycle $TAG: autonomous heal completed in $(( $(date +%s) - T0 ))s — continuing"
    else
      mark "cycle $TAG: HEAL FAILED — manual attention needed"
      break
    fi
  else
    CLEAN=$((CLEAN+1))
    mark "cycle $TAG: clean ($(echo $OUT | tr '\n' ' '))"
  fi
done
mark "VERDICT: total=$TOTAL clean=$CLEAN wedged=$WEDGED autonomously_healed=$HEALED"
