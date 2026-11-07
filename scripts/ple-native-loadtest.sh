#!/usr/bin/env bash
# Phase-2 single-host load test of the PLE-native BF16 candidate pack.
#
# One bounded GPU window on strix1: park gufo-prod (the guardian TERM handler
# tears down BOTH TP2 ranks), run the deployed binary ba355d5 against
# /models-ple-ab (single host, TP1, no MTP), then ALWAYS restore gufo-prod and
# poll /ready. Every step is logged with timestamps; the transcript is kept.
#
# Usage: ple-native-loadtest.sh park|loadtest|restore|sanity|full
set -u
PACK=/models-ple-ab
MODEL=$PACK/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
BIN=/root/newbin/gufo.ba355d5
EV=/root/strix-dual-exp/evidence/ple-native
PORT=15003
HOST_B=10.55.0.2

stamp() { date '+%F %T%z'; }

serve_pids() { pgrep -f 'gufo[^ ]* serve llm' | wc -l; }

park() {
  echo "[$(stamp)] PARK: systemctl stop gufo-prod"
  systemctl stop gufo-prod
  for t in $(seq 1 30); do
    a=$(serve_pids); b=$(ssh root@$HOST_B "pgrep -f 'gufo[^ ]* serve llm' | wc -l")
    [ "$a" = "0" ] && [ "$b" = "0" ] && break
    sleep 2
  done
  echo "[$(stamp)] park: local serve procs=$(serve_pids) remote=$(ssh root@$HOST_B "pgrep -f 'gufo[^ ]* serve llm' | wc -l")"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PORT/ready" || true)
  echo "[$(stamp)] park: /ready http_code=$code (expected 000/failed)"
  systemctl is-active gufo-prod || true
}

loadtest() {
  echo "[$(stamp)] LOADTEST binary=$BIN model=$MODEL (single host, TP1, no MTP)"
  "$BIN" --version 2>&1 | head -2
  sha256sum "$BIN"
  echo "[$(stamp)] ---- prompt 1: arithmetic sanity (greedy)"
  "$BIN" prompt --model "$MODEL" --think off -t 0 -n 64 \
    -p 'What is 17 * 23? Reply with just the number.' 2>&1
  echo
  echo "[$(stamp)] ---- prompt 2: short open completion (greedy)"
  "$BIN" prompt --model "$MODEL" --think off -t 0 -n 64 -v \
    -p 'In one short paragraph, explain what a hash table is.' 2>&1
  echo "[$(stamp)] LOADTEST done rc=$?"
}

restore() {
  echo "[$(stamp)] RESTORE: systemctl start gufo-prod"
  systemctl start gufo-prod
  poll=0
  for t in $(seq 1 100); do
    poll=$((poll + 1))
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PORT/ready" || true)
    body=$(curl -s -m 3 "http://127.0.0.1:$PORT/ready" 2>/dev/null || true)
    echo "[$(stamp)] restore poll $poll: /ready http_code=$code body='$body'"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  echo "[$(stamp)] RESTORE FAILED: /ready never 200"
  return 1
}

sanity() {
  echo "[$(stamp)] live completion sanity against restored prod:"
  curl -s -m 60 http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "model": "Qwen3.8-Flash-Next",
    "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
    "max_tokens": 16, "temperature": 0}' | head -c 1200
  echo
}

full() {
  park || true
  loadtest
  restore
  sanity
}

case "${1:-}" in
  park) park ;;
  loadtest) loadtest ;;
  restore) restore ;;
  sanity) sanity ;;
  full)
    trap 'restore; sanity' EXIT
    park || true
    loadtest
    ;;
  *) echo "usage: $0 park|loadtest|restore|sanity|full" >&2; exit 2 ;;
esac
