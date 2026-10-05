#!/usr/bin/env bash
# tbstream_probe pair-runner (host-only tool, no GPU): launches rank 0
# locally and rank 1 over ssh, pairing over tbnet like gufo's bootstrap,
# then lets both processes exit. Honors RUN_DIR (unique per-block evidence
# dir; rank-1 log is fetched back from the peer). Wedge accounting is left
# to the caller (ablate.sh).
. "$(dirname "$0")/env.sh"
# usage: probe-pair-tb.sh TAG -- <probe args, e.g. --mode bw --bytes ... --frames ...>
set -u
TAG="$1"; shift
[ "${1:-}" = "--" ] && shift
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream
BASE="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${RUN_DIR:-$BASE/evidence}"
mkdir -p "$RUN_DIR"
R0_LOG="$RUN_DIR/tbprobe-$TAG-r0.log"
R1_LOG="$RUN_DIR/tbprobe-$TAG-r1.log"
R1_REMOTE="/tmp/tbprobe-$TAG-r1.log"
PORT=18540

cd "$BIN_DIR"
nohup ./tbstream_probe --rank 0 --port $PORT "$@" > "$R0_LOG" 2>&1 &
R0_PID=$!
sleep 1
# 30 s remote cap: probe traffic completes in seconds; anything longer
# is a wedged or truncated stream (ablate.sh classifies the cycle).
timeout 60 ssh $HOST_B "cd $BIN_DIR && timeout 30 stdbuf -oL -eL ./tbstream_probe \
  --rank 1 --peer ${TBNET_BASE}.1 --port $PORT $* > $R1_REMOTE 2>&1; echo R1-RC=\$?"
timeout 15 scp -q $HOST_B:"$R1_REMOTE" "$R1_LOG" 2>/dev/null || echo "(r1 log fetch failed)"
wait $R0_PID; echo "R0-RC=$?"
