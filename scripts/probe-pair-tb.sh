#!/usr/bin/env bash
# tbstream_probe pair-runner (host-only tool, no GPU): launches rank 0
# locally and rank 1 over ssh, pairing over tbnet like gufo's bootstrap,
# then lets both processes exit. Wedge accounting is left to the caller.
. "$(dirname "$0")/env.sh"
# usage: probe-pair-tb.sh TAG -- <probe args, e.g. --mode bw --bytes ... --frames ...>
set -u
TAG="$1"; shift
[ "${1:-}" = "--" ] && shift
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream
R0_LOG="$(dirname "$0")/../evidence/tbprobe-$TAG-r0.log"
R1_LOG="$(dirname "$0")/../evidence/tbprobe-$TAG-r1.log"
PORT=18540

cd "$BIN_DIR"
nohup ./tbstream_probe --rank 0 --port $PORT "$@" > "$R0_LOG" 2>&1 &
R0_PID=$!
sleep 1
timeout 300 ssh $HOST_B "cd $BIN_DIR && timeout 240 ./tbstream_probe \
  --rank 1 --peer ${TBNET_BASE}.1 --port $PORT $* > $R1_LOG 2>&1; echo R1-RC=\$?"
wait $R0_PID; echo "R0-RC=$?"
