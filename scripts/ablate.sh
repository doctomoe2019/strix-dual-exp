#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Ablation driver v2: interleaved arms under the same boot, 4-class
# scoring, unique run dirs, both-rank log capture, recovery-first heal
# handling (kernel-frozen safe).
#
# Scoring classes (never conflated):
#   workload: ok / fail      (both ranks RC=0, full delivery, no error text)
#   link:     clean / episode (dmesg timeout/deactivation counters moved)
#   recovery: seconds | HEAL-TIMEOUT (ping-stable after first failure)
#
# Arms (env ARMS, comma-separated):
#   A7   host-only small-frame bw (the reproducer, no pairing barrier)
#   A18  A7 + --pairing teardown  (delivery-confirmed close)
#   A17  A18 + --batch-bytes 1M + --reader-buffered (full intervention)
#   B0   gufo qualification cycle
#   (legacy arms A,A2-A6,A8,A12-A16,B1-B3 kept for compatibility)
# env ROUNDS: cycles per arm (default 3).
. "$(dirname "$0")/env.sh"
set -u
ARMS="${ARMS:-A7,A18,A17,B0}"
ROUNDS="${ROUNDS:-3}"
MODEL=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
BASE="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$BASE/evidence/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/ablate.log"
: > "$LOG"
export RUN_DIR

mark() { echo "[$(date +%F\ %T)] $*" | tee -a "$LOG"; }

errs_local()  { dmesg | grep -cE "timeout reading config|deactivation failed"; }
errs_remote() { timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"' 2>/dev/null; }
errlines_local()  { dmesg -T | grep -E "timeout reading config|deactivation failed|forcing link retrain|new host found" | tail -40; }

identity() {
  {
    echo "date: $(date -Is)"
    echo "hostA: boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime=$(uptime -p)"
    echo "  thunderbolt=$(cat /sys/module/thunderbolt/srcversion 2>/dev/null)"
    echo "  thunderbolt_stream=$(cat /sys/module/thunderbolt_stream/srcversion 2>/dev/null)"
    echo "  tx_coalesce=$(cat /sys/module/thunderbolt_stream/parameters/tx_coalesce 2>/dev/null)"
    echo "  busy_poll=$(cat /sys/kernel/config/thunderbolt/stream/*/gufo/busy_poll 2>/dev/null | tr '\n' ' ')"
    echo "  probe_sha=$(sha256sum /root/gufo/build/gpu-tp2-tbstream/tbstream_probe 2>/dev/null | cut -c1-16)"
    echo "  gufo_sha=$(sha256sum /root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next/qwen38_flash_next_tp_batched_probe 2>/dev/null | cut -c1-16)"
    timeout 10 ssh -o ConnectTimeout=5 $HOST_B 'echo "hostB: boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime=$(uptime -p)"; echo "  thunderbolt=$(cat /sys/module/thunderbolt/srcversion 2>/dev/null)"; echo "  thunderbolt_stream=$(cat /sys/module/thunderbolt_stream/srcversion 2>/dev/null)"; echo "  tx_coalesce=$(cat /sys/module/thunderbolt_stream/parameters/tx_coalesce 2>/dev/null)"' 2>/dev/null
    for d in /sys/bus/thunderbolt/devices/*-*; do
      [ -e "$d/rx_speed" ] && echo "  link $(basename $d): rx $(cat $d/rx_speed)x$(cat $d/rx_lanes) tx $(cat $d/tx_speed)x$(cat $d/tx_lanes)"
    done
  } >> "$LOG"
}

# $1: tag base for this cycle's logs
classify() { # $1=arm $2=cyc $3=runner-output $4=r0log $5=r1log
  local arm="$1" cyc="$2" out="$3" r0="$4" r1="$5"
  local r0rc r1rc workload="ok" why=""
  r0rc=$(echo "$out" | grep -o 'R0-RC=[0-9]*' | cut -d= -f2)
  r1rc=$(echo "$out" | grep -o 'R1-RC=[0-9]*' | cut -d= -f2)
  [ "${r0rc:-X}" = "0" ] || { workload="fail"; why="R0-RC=${r0rc:-missing}"; }
  [ "${r1rc:-X}" = "0" ] || { workload="fail"; why="$why R1-RC=${r1rc:-missing}"; }
  # Failure text in either rank's log (mismatch, timeout, ENXIO, poison...)
  if grep -qE "mismatch|timed out|timeout waiting|No such device|poisoned|exchange failed" "$r0" "$r1" 2>/dev/null; then
    workload="fail"; why="$why error-text"
  fi
  # Receiver must have moved bytes (tb bw arms print "received"/"ok" lines)
  if echo "$out" | grep -q "R1-RC" && [ "$arm" != "B0" ]; then
    grep -q "received\|rank 1: ok" "$r1" 2>/dev/null || { workload="fail"; why="$why no-delivery"; }
  fi
  echo "$workload|$why"
}

# Recovery-first heal wait: ping-stable (2x1s) within 120 s, then quiet
# dmesg (no new error/retrain lines for 10 s), else ABORT.
heal_and_settle() { # $1=arm $2=cyc
  local arm="$1" cyc="$2" t0 t_ok span base now
  errlines_local > "$RUN_DIR/${arm}-c${cyc}-dmesg-fail.txt" 2>/dev/null
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 120 ]; do
    if ping -c1 -W1 ${TBNET_BASE}.2 >/dev/null 2>&1; then
      sleep 1
      if ping -c1 -W1 ${TBNET_BASE}.2 >/dev/null 2>&1; then t_ok=$(date +%s); break; fi
    fi
    sleep 1
  done
  if [ -z "${t_ok:-}" ]; then
    mark "arm $arm cycle $cyc: HEAL-TIMEOUT (120s) — ABORTING CAMPAIGN"
    errlines_local > "$RUN_DIR/${arm}-c${cyc}-dmesg-abort.txt" 2>/dev/null
    verdict
    exit 1
  fi
  span=$(( t_ok - t0 ))
  # Quiet dmesg: no new wedge/retrain lines for 10 consecutive seconds.
  base=$(errs_local); now=0
  while [ $now -lt 10 ]; do
    sleep 2; now=$((now+2))
    if [ "$(errs_local)" != "$base" ]; then base=$(errs_local); now=0; fi
  done
  sleep 5
  errlines_local > "$RUN_DIR/${arm}-c${cyc}-dmesg-settled.txt" 2>/dev/null
  mark "arm $arm cycle $cyc: recovered ping-stable in ${span}s (+settle)"
}

declare -A EPISODES FAILS TOTALS
verdict() {
  mark "VERDICT: $(for A in "${ARM_LIST[@]}"; do echo -n "$A: episodes=${EPISODES[$A]:-0} fails=${FAILS[$A]:-0}/${TOTALS[$A]:-0} "; done)"
  mark "run dir: $RUN_DIR"
}

run_arm() { # $1=arm $2=unique-tag
  case "$1" in
    A)  bash "$DIR/probe-pair-tb.sh" "A-$2" -- --mode bw --bytes 1048576,5242880,33554432 --frames 200 --noverify ;;
    A2) bash "$DIR/probe-pair-tb.sh" "A2-$2" -- --mode bw --bytes 1048576,5242880,33554432 --frames 200 --noverify --pairing teardown ;;
    A3) bash "$DIR/probe-pair-tb.sh" "A3-$2" -- --mode fulldup --bytes 1048576,5242880,33554432 --frames 200 --noverify --pairing teardown ;;
    A4) bash "$DIR/probe-pair-tb.sh" "A4-$2" -- --mode fulldup --bytes 1048576,5242880,33554432 --frames 200 --noverify --pairing teardown --idle-seconds 40 ;;
    A5) bash "$DIR/probe-pair-tb.sh" "A5-$2" -- --mode bw --bytes 1048576,5242880,33554432 --frames 200 --noverify --exit-open ;;
    A6) bash "$DIR/probe-pair-tb.sh" "A6-$2" -- --mode fulldup --bytes 1048576,5242880,33554432 --frames 200 --noverify --pairing teardown --exit-open ;;
    A7)  bash "$DIR/probe-pair-tb.sh" "A7-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify ;;
    A8)  bash "$DIR/probe-pair-tb.sh" "A8-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify --batch-bytes 1048576 ;;
    A12) bash "$DIR/probe-pair-tb.sh" "A12-$2" -- --mode bw --bytes 20416,49088,81856 --frames 470 --noverify ;;
    A13) bash "$DIR/probe-pair-tb.sh" "A13-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify --reader-glutton ;;
    A14) bash "$DIR/probe-pair-tb.sh" "A14-$2" -- --mode bw --bytes 1048576 --frames 400 --noverify --reader-glutton ;;
    A15) bash "$DIR/probe-pair-tb.sh" "A15-$2" -- --mode bw --bytes 5242880,33554432 --frames 120 --noverify ;;
    A16) bash "$DIR/probe-pair-tb.sh" "A16-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify --reader-buffered --pairing teardown ;;
    A17) bash "$DIR/probe-pair-tb.sh" "A17-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify --reader-buffered --batch-bytes 1048576 --pairing teardown ;;
    A18) bash "$DIR/probe-pair-tb.sh" "A18-$2" -- --mode bw --bytes 20544,51264,81984 --frames 470 --noverify --pairing teardown ;;
    A7V10) bash "$DIR/probe-pair-tb.sh" "A7V10-$2" -- --mode bw --bytes 20544,51264,81984 --frames 4700 --noverify ;;
    B0)  bash "$DIR/probe-pair.sh" "B0-$2" --model $MODEL --context 4096 --max-tokens 16 ;;
    B1)  GUFO_ENV="GUFO_TBSTREAM_TX_PACING_US=0" bash "$DIR/probe-pair.sh" "B1-$2" --model $MODEL --context 4096 --max-tokens 16 ;;
    B2)  GUFO_ENV="GUFO_TBSTREAM_CPU_STAGE=1" bash "$DIR/probe-pair.sh" "B2-$2" --model $MODEL --context 4096 --max-tokens 16 ;;
    B3)  GUFO_ENV="GUFO_TBSTREAM_COALESCE=1" bash "$DIR/probe-pair.sh" "B3-$2" --model $MODEL --context 4096 --max-tokens 16 ;;
    *) echo "unknown arm $1" >&2; return 9 ;;
  esac
}

DIR="$(cd "$(dirname "$0")" && pwd)"
mark "ablate-v2 start arms=$ARMS rounds=$ROUNDS"
mark "loaded: thunderbolt=$(cat /sys/module/thunderbolt/srcversion) stream=$(cat /sys/module/thunderbolt_stream/srcversion)"
identity
IFS=',' read -ra ARM_LIST <<< "$ARMS"
for R in $(seq 1 "$ROUNDS"); do
  for ARM in "${ARM_LIST[@]}"; do
    TAG="c${R}"
    E0=$(errs_local); E20=$(errs_remote)
    OUT=$(run_arm "$ARM" "$TAG" 2>&1)
    E1=$(errs_local); E21=$(errs_remote)
    TOTALS[$ARM]=$(( ${TOTALS[$ARM]:-0} + 1 ))
    R0LOG=$(ls -t "$RUN_DIR"/*${ARM}-${TAG}-r0.log 2>/dev/null | head -1)
    R1LOG=$(ls -t "$RUN_DIR"/*${ARM}-${TAG}-r1.log 2>/dev/null | head -1)
    READ=$(classify "$ARM" "$R" "$OUT" "$R0LOG" "$R1LOG")
    W="${READ%%|*}"; WHY="${READ#*|}"
    EP="clean"
    if [ "${E1:-0}" != "${E0:-X}" ] || [ "${E21:-0}" != "${E20:-X}" ]; then EP="episode"; fi
    [ "$W" = "fail" ] && FAILS[$ARM]=$(( ${FAILS[$ARM]:-0} + 1 ))
    [ "$EP" = "episode" ] && EPISODES[$ARM]=$(( ${EPISODES[$ARM]:-0} + 1 ))
    mark "arm $ARM cycle $R: workload=$W link=$EP ($(echo "$OUT" | grep -o 'R[01]-RC=[0-9]*' | tr '\n' ' ')) [${WHY}] errsA ${E0:-?}->${E1:-?} errsB ${E20:-?}->${E21:-?}"
    if [ "$EP" = "episode" ] || ! ping -c1 -W1 ${TBNET_BASE}.2 >/dev/null 2>&1; then
      heal_and_settle "$ARM" "$R"
    fi
  done
done
verdict
