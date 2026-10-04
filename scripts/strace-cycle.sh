#!/usr/bin/env bash
# One straced gufo cycle (rank 0 local under strace, rank 1 remote).
. "$(dirname "$0")/env.sh"
BIN_DIR=/root/gufo/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
MODEL=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
OUT=$(dirname "$0")/../evidence/strace-b3.log
cd "$BIN_DIR"
GUFO_TBSTREAM_COALESCE=1 setsid nohup strace -f -tt -yy -e trace=write,read,close \
  -o "$OUT" ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 0 --tp-transport tbstream --tp-tbstream-dev /dev/tbstream0 \
  --model $MODEL --context 4096 --max-tokens 16 \
  > "$(dirname "$0")/../evidence/strace-b3-r0.log" 2>&1 < /dev/null &
sleep 2
timeout 8 ssh $HOST_B "cd $BIN_DIR && GUFO_TBSTREAM_COALESCE=1 setsid nohup \
  ./qwen38_flash_next_tp_batched_probe \
  --tp-rank 1 --tp-bootstrap-host 10.55.0.1 --tp-transport tbstream \
  --tp-tbstream-dev /dev/tbstream0 --model $MODEL \
  --context 4096 --max-tokens 16 \
  > /root/strix-dual-exp/evidence/strace-b3-r1.log 2>&1 < /dev/null &" 2>/dev/null
echo LAUNCHED
