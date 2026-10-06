#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# ROLE-SWAP probe pair: rank 0 (bootstrap LISTENER) runs on hostB,
. "$(dirname "$0")/env.sh"
# rank 1 (connector) runs locally on hostA. Bootstrap host = $TBNET_B_IP.
# Both ranks run foreground under timeout, driven through a local ssh
# wrapper for rank 0 (same pattern as the proven probe-pair.sh).
# usage: probe-pair-swap.sh TAG [EXTRA-ARGS...]
set -u
TAG="$1"; shift
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
R0_LOG="$(dirname "$0")/../evidence/probe-$TAG-r0.log"   # rank0 (hostB) log, captured locally
R1_LOG="$(dirname "$0")/../evidence/probe-$TAG-r1.log"   # rank1 (hostA) log
E0=$(dmesg | grep -cE "timeout reading config|deactivation failed")

# Rank 0 on hostB, foreground there, wrapped locally in background.
nohup ssh -n $HOST_B "cd $BIN_DIR && timeout 240 ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 0 --tp-transport tbstream --tp-tbstream-dev /dev/tbstream0 \
  --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --context 4096 --max-tokens 16 $*; echo R0-RC=\$?" > "$R0_LOG" 2>&1 < /dev/null &
SSH_PID=$!

# Rank 1 locally, foreground under the same bound.
cd "$BIN_DIR"
timeout 240 ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 1 --tp-bootstrap-host $TBNET_B_IP --tp-transport tbstream \
  --tp-tbstream-dev /dev/tbstream0 \
  --model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --context 4096 --max-tokens 16 "$@" > "$R1_LOG" 2>&1 < /dev/null
echo "R1-RC=$?"
timeout -k 5 60 tail --pid=$SSH_PID -f /dev/null; echo "ssh-r0-done"
E1=$(dmesg | grep -cE "timeout reading config|deactivation failed")
echo "hostA errs: $E0 -> $E1"
if ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1; then echo "ping=ok"; else echo "ping=DEAD"; fi
if [ "$E1" -gt "$E0" ]; then echo "*** WEDGE on HOSTA (was connector) — HOST-tied ***"; fi
