#!/usr/bin/env bash
# Pair-runner for the batched probe in-vivo bisection.
. "$(dirname "$0")/env.sh"
# usage: probe-pair.sh TAG [EXTRA-ARGS...]
#   EXTRA-ARGS passed to BOTH ranks (e.g. --allreduce-bench 64).
# Rank 1 is launched over ssh on hostB. Logs: $(dirname "$0")/../evidence/probe-{TAG}-r{0,1}.log
set -u
TAG="$1"; shift
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
R0_LOG="$(dirname "$0")/../evidence/probe-$TAG-r0.log"
R1_LOG="$(dirname "$0")/../evidence/probe-$TAG-r1.log"
E0=$(dmesg | grep -cE "timeout reading config|deactivation failed")
# GUFO_ENV (optional): "VAR=val VAR2=val2" applied to BOTH ranks
# (rank 0 locally, rank 1 via ssh env prefix). Used by ablate.sh arms.
R1_ENV_PREFIX="${GUFO_ENV:+env $GUFO_ENV }"

cd "$BIN_DIR"
nohup env ${GUFO_ENV:-} ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 0 --tp-transport tbstream --tp-tbstream-dev /dev/tbstream0 \
  "$@" > "$R0_LOG" 2>&1 &
R0_PID=$!
sleep 2
ssh $HOST_B "cd $BIN_DIR && ${R1_ENV_PREFIX}timeout 240 ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 1 --tp-bootstrap-host 10.55.0.1 --tp-transport tbstream \
  --tp-tbstream-dev /dev/tbstream0 $* > $R1_LOG 2>&1; echo R1-RC=\$?"
wait $R0_PID; echo "R0-RC=$?"
E1=$(dmesg | grep -cE "timeout reading config|deactivation failed")
echo "errs: $E0 -> $E1"
ping -c1 -W1 10.55.0.2 >/dev/null 2>&1 && echo "ping=ok" || echo "ping=DEAD"
if [ "$E1" -gt "$E0" ] || ! ping -c1 -W1 10.55.0.2 >/dev/null 2>&1; then
  echo "*** WEDGE DETECTED — run forensics BEFORE reboot ***"
fi
