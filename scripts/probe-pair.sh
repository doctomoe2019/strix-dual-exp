#!/usr/bin/env bash
# Pair-runner for the batched probe in-vivo bisection. Honors RUN_DIR
# (unique per-block evidence dir; rank-1 log fetched back from the peer).
. "$(dirname "$0")/env.sh"
# usage: probe-pair.sh TAG [EXTRA-ARGS...]
#   EXTRA-ARGS passed to BOTH ranks (e.g. --allreduce-bench 64).
set -u
TAG="$1"; shift
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
BASE="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${RUN_DIR:-$BASE/evidence}"
mkdir -p "$RUN_DIR"
R0_LOG="$RUN_DIR/probe-$TAG-r0.log"
R1_LOG="$RUN_DIR/probe-$TAG-r1.log"
R1_REMOTE="/tmp/probe-$TAG-r1.log"
# GUFO_ENV (optional): "VAR=val VAR2=val2" applied to BOTH ranks.
R1_ENV_PREFIX="${GUFO_ENV:+env $GUFO_ENV }"

cd "$BIN_DIR"
nohup env ${GUFO_ENV:-} ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 0 --tp-transport tbstream --tp-tbstream-dev /dev/tbstream0 \
  "$@" > "$R0_LOG" 2>&1 &
R0_PID=$!
sleep 2
ssh $HOST_B "cd $BIN_DIR && ${R1_ENV_PREFIX}timeout 240 ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 1 --tp-bootstrap-host 10.55.0.1 --tp-transport tbstream \
  --tp-tbstream-dev /dev/tbstream0 $* > $R1_REMOTE 2>&1; echo R1-RC=\$?"
timeout 15 scp -q $HOST_B:"$R1_REMOTE" "$R1_LOG" 2>/dev/null || echo "(r1 log fetch failed)"
wait $R0_PID; echo "R0-RC=$?"
