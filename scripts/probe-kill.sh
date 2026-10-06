#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Kill-choreography probe: launch full probe pair, SIGTERM rank 1 at T
. "$(dirname "$0")/env.sh"
# seconds, watch rank 0's dead-peer teardown, then wedge-check.
# usage: probe-kill.sh TAG KILL_AT_SECONDS
set -u
TAG="$1"; KILL_AT="${2:?kill-at-seconds}"
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
R0_LOG="$(dirname "$0")/../evidence/probe-$TAG-r0.log"
R1_LOG="$(dirname "$0")/../evidence/probe-$TAG-r1.log"
E0=$(dmesg | grep -cE "timeout reading config|deactivation failed")

cd "$BIN_DIR"
nohup ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 0 --tp-transport tbstream --tp-tbstream-dev /dev/tbstream0 \
  --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --context 4096 --max-tokens 16 > "$R0_LOG" 2>&1 &
R0_PID=$!
ssh $HOST_B "cd $BIN_DIR && nohup ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 1 --tp-bootstrap-host $TBNET_A_IP --tp-transport tbstream \
  --tp-tbstream-dev /dev/tbstream0 \
  --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --context 4096 --max-tokens 16 > $R1_LOG 2>&1 & echo launched"
echo "killing rank1 with SIGTERM at t=${KILL_AT}s..."
sleep "$KILL_AT"
ssh $HOST_B 'pkill -TERM -f "[t]p_batched_probe" && echo r1-killed'
timeout -k 5 180 tail --pid=$R0_PID -f /dev/null; echo "R0-RC=$?"
E1=$(dmesg | grep -cE "timeout reading config|deactivation failed")
echo "errs: $E0 -> $E1"
if ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1; then echo "ping=ok"; else echo "ping=DEAD"; fi
if [ "$E1" -gt "$E0" ]; then echo "*** WEDGE — forensics BEFORE reboot ***"; fi
