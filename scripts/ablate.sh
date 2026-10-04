#!/usr/bin/env bash
# Ablation driver: interleaved arms under the same boot, per-cycle
# wedge accounting on both hosts, autonomous-heal waits between cycles.
# Arms (env ARMS, comma-separated; default A,B0,B1):
#   A  tbstream_probe bw, gates volume (6.7 GB/cycle) — premise test
#   B0 gufo qualification cycle, defaults (= TX pacing 25 us/MiB on)
#   B1 gufo qualification cycle, GUFO_TBSTREAM_TX_PACING_US=0
# env ROUNDS: cycles per arm (default 4).
. "$(dirname "$0")/env.sh"
set -u
ARMS="${ARMS:-A,B0,B1}"
ROUNDS="${ROUNDS:-4}"
MODEL=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
LOG=$(dirname "$0")/../evidence/ablate-$(date +%Y%m%d-%H%M).log
: > "$LOG"
mark() { echo "[$(date +%F\ %T)] $*" >> "$LOG"; }
errs_local() { dmesg | grep -cE "timeout reading config|deactivation failed"; }
errs_remote() { timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"' 2>/dev/null; }
retrains_local() { dmesg | grep -c "forcing link retrain"; }

declare -A WEDGED TOTAL
DIR="$(cd "$(dirname "$0")" && pwd)"

run_arm() { # $1=arm $2=cycle-tag
  case "$1" in
    A)
      bash "$DIR/probe-pair-tb.sh" "A-$2" -- \
        --mode bw --bytes 1048576,5242880,33554432 --frames 200 --noverify \
        2>&1 | grep -E "RC=" ;;
    B0)
      bash "$DIR/probe-pair.sh" "B0-$2" --model $MODEL \
        --context 4096 --max-tokens 16 2>&1 | grep -E "R1-RC=|ping=" ;;
    B1)
      GUFO_ENV="GUFO_TBSTREAM_TX_PACING_US=0" \
        bash "$DIR/probe-pair.sh" "B1-$2" --model $MODEL \
        --context 4096 --max-tokens 16 2>&1 | grep -E "R1-RC=|ping=" ;;
    *) echo "unknown arm $1" >&2; return 9 ;;
  esac
}

mark "ablate start arms=$ARMS rounds=$ROUNDS module=$(modinfo -F srcversion /lib/modules/$(uname -r)/kernel/drivers/thunderbolt/thunderbolt.ko)"
IFS=',' read -ra ARM_LIST <<< "$ARMS"
for R in $(seq 1 "$ROUNDS"); do
  for ARM in "${ARM_LIST[@]}"; do
    TAG="$R"
    E0=$(errs_local); E20=$(errs_remote)
    OUT=$(run_arm "$ARM" "$TAG")
    E1=$(errs_local); E21=$(errs_remote)
    TOTAL[$ARM]=$(( ${TOTAL[$ARM]:-0} + 1 ))
    if [ "${E1:-0}" != "${E0:-X}" ] || [ "${E21:-0}" != "${E20:-X}" ]; then
      WEDGED[$ARM]=$(( ${WEDGED[$ARM]:-0} + 1 ))
      mark "arm $ARM cycle $R: WEDGED (errsA ${E0:-?}->${E1:-?} errsB ${E20:-?}->${E21:-?}) — waiting for autonomous heal"
      T0=$(date +%s); OK=0
      while [ $(( $(date +%s) - T0 )) -lt 120 ]; do
        sleep 5
        if ping -c1 -W1 ${TBNET_BASE}.2 >/dev/null 2>&1; then
          sleep 3
          if ping -c1 -W1 ${TBNET_BASE}.2 >/dev/null 2>&1; then OK=1; break; fi
        fi
      done
      if [ "$OK" = "1" ]; then
        mark "arm $ARM cycle $R: healed in $(( $(date +%s) - T0 ))s — continuing"
      else
        mark "arm $ARM cycle $R: HEAL FAILED — aborting"
        mark "VERDICT: ${TOTAL[@]}" 
        exit 1
      fi
    else
      mark "arm $ARM cycle $R: clean ($(echo "$OUT" | tr '\n' ' '))"
    fi
  done
done
mark "VERDICT: $(for A in "${ARM_LIST[@]}"; do echo -n "$A=${WEDGED[$A]:-0}/${TOTAL[$A]:-0} "; done)"
