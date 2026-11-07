#!/usr/bin/env bash
# Phase-3 A/B window driver: verify pack+binary on both ranks, park
# production, launch the manual TP2 pair on either pack (IQ4=/models,
# BF16=/models-ple-ab) with the deployed binary, and restore production with
# recorded /ready polls.
#
# Ports: the A/B pair serves on PAIR_PORT (default 15005), NEVER on
# gufo-prod's 15003, so a leftover pair cannot answer restore's /ready poll.
# restore() additionally verifies that whoever answers 15003 is actually the
# gufo-prod unit (systemctl active + the serve process lives in the
# gufo-prod.service cgroup), and start() kills its half-launched ranks when it
# can never become ready.
#
# Usage: ple-native-pair.sh verify|park|restore|status|start IQ4|BF16 [TAG]|stop [TAG]
#
# Phase-4 overrides (defaults keep the phase-3 behavior byte-identical):
#   PLE_EV       evidence directory (default .../ple-native/phase3)
#   PLE_PREFIX   evidence log-name prefix  (default 03)
#   PLE_EXTRA_ARGS  appended to the serve args, word-split (default empty;
#                phase 4 passes --max-connections 64 so the C32 leg can hold
#                32 clients; inference args stay exactly the guardian's).
set -u
. /root/strix-dual-exp/scripts/env.sh
: "${HOST_A:=strix1}" "${HOST_B:=strix2}" "${TBNET_BASE:=10.55.0}"
EV="${PLE_EV:-/root/strix-dual-exp/evidence/ple-native/phase3}"
PFX="${PLE_PREFIX:-03}"
BIN=/root/newbin/gufo.ba355d5
BIN_SHA=de09ba763bad549455fd3d9fe17bc83008430081f7cf506d865a4a6e215718b2
IQ4=/models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
BF16=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
MTP=/models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
PROD_PORT=15003
PAIR_PORT="${PAIR_PORT:-15005}"
MAN=/root/strix-dual-exp/evidence/ple-native/02-manifest-strix1.sha256
STATE=/tmp/opencode/ple-p3-pair
# Any serve binary must match this (production is /root/newbin/gufo, the A/B
# pair is gufo.ba355d5); a literal 'gufo serve llm' would miss the pair.
SERVE_PAT='gufo[^ ]* serve llm'
# The pair binary's own pattern. The bracket expression keeps the pattern
# from matching the ssh carrier shell that transports it: a remote
# `ssh host "pgrep -f 'LITERAL' | wc -l"` leaves the remote `bash -c` (whose
# argv contains LITERAL) alive for the pipeline, so a plain literal always
# self-matches and the count can never reach 0 (observed live 2026-10-18;
# regex `[.]` matches the real cmdline's dot but not the carrier's "[.]").
PAIR_PAT='gufo[.]ba355d5 serve llm'
mkdir -p "$EV" "$STATE"

stamp() { date '+%F %T%z'; }
log() { echo "[$(stamp)] $*"; }

# The serve process answering for the gufo-prod unit, if any. A leftover A/B
# pair serves from the session's own cgroup and must never satisfy restore().
prod_serve_pid() {
  local p
  for p in $(pgrep -f "$SERVE_PAT" 2>/dev/null); do
    if grep -q 'gufo-prod.service' "/proc/$p/cgroup" 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

verify() {
  log "VERIFY binary+pack on both ranks (hosts hashed in parallel)"
  { sha256sum "$BIN"; ( cd /models-ple-ab && sha256sum ./* ); } > "$EV/$PFX-verify-strix1.txt" &
  local p1=$!
  ssh root@$HOST_B "{ sha256sum $BIN; cd /models-ple-ab && sha256sum ./*; }" \
    > "$EV/$PFX-verify-strix2.txt" &
  local p2=$!
  wait "$p1" "$p2"
  for host in strix1 strix2; do
    grep '\.gguf$' "$EV/$PFX-verify-$host.txt" | sed 's# /models-ple-ab/# ./#; s#  \./#  #' \
      > "$EV/$PFX-verify-pack-$host.sha256"
  done
  log "pack manifest comparison (both ranks vs phase-2 manifest):"
  if diff <(sort "$MAN") <(sort "$EV/$PFX-verify-pack-strix1.sha256") > "$EV/$PFX-verify-pack-diff.txt"; then
    log "rank A pack 8/8 identical to phase-2 manifest"
  else
    log "ERROR rank A pack differs from phase-2 manifest"; cat "$EV/$PFX-verify-pack-diff.txt"; return 1
  fi
  if diff <(sort "$EV/$PFX-verify-pack-strix1.sha256") <(sort "$EV/$PFX-verify-pack-strix2.sha256") > /dev/null; then
    log "rank A and rank B packs byte-identical (8/8)"
  else
    log "ERROR pack differs across ranks"; return 1
  fi
  for host in strix1 strix2; do
    got=$(awk '$2 ~ /gufo.ba355d5$/ {print $1}' "$EV/$PFX-verify-$host.txt")
    [ "$got" = "$BIN_SHA" ] || { log "ERROR binary sha mismatch on $host: got '$got'"; return 1; }
    log "$host binary sha256 OK ($got)"
  done
  log "VERIFY OK"
}

park() {
  log "PARK systemctl stop gufo-prod"
  systemctl stop gufo-prod
  local a=1 b=1
  for t in $(seq 1 30); do
    a=$(pgrep -f "$SERVE_PAT" | wc -l)
    b=$(ssh root@$HOST_B "pgrep -f '$SERVE_PAT' | wc -l")
    [ "$a" = "0" ] && [ "$b" = "0" ] && break
    sleep 2
  done
  log "park: rankA procs=$a rankB procs=$b"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PROD_PORT/ready" || true)
  log "park: /ready http_code=$code (expected 000)"
  if [ "$code" = "200" ]; then
    if prod_serve_pid >/dev/null; then
      log "ERROR park: $PROD_PORT still answered by the gufo-prod unit (stop failed)"
    else
      log "ERROR park: $PROD_PORT answered by a NON-production serve (leftover A/B pair?); run: $0 stop <tag> or pkill -f 'gufo.ba355d5 serve llm' on both ranks"
    fi
    return 1
  fi
  if [ "$a" != "0" ] || [ "$b" != "0" ]; then
    log "ERROR park: serve processes remain (rankA=$a rankB=$b)"
    return 1
  fi
  systemctl is-active gufo-prod || true
}

restore() {
  log "RESTORE systemctl start gufo-prod"
  systemctl start gufo-prod
  local t code body
  for t in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PROD_PORT/ready" || true)
    body=$(curl -s -m 3 "http://127.0.0.1:$PROD_PORT/ready" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      if systemctl is-active --quiet gufo-prod && prod_serve_pid >/dev/null; then
        log "restore poll $t: /ready http_code=200 body='$body' responder=gufo-prod (unit + cgroup verified)"
        return 0
      fi
      log "ERROR restore: $PROD_PORT answers 200 but NOT from the gufo-prod unit (leftover A/B pair is masking production); stopping it is required before production is healthy"
      log "ERROR restore: run: $0 stop <tag>; then re-run: $0 restore"
      return 1
    fi
    log "restore poll $t: /ready http_code=$code body='$body'"
    sleep 3
  done
  log "RESTORE FAILED: /ready never 200"
  return 1
}

args() {
  TOKEN=$(od -An -N16 /dev/urandom | tr -d ' \n')
  echo "serve llm --model $1 --speculative mtp --mtp-model $MTP \
--tp-world-size 2 --tp-transport tbstream \
--tp-bootstrap-port 18515 --tp-control-port 18516 --tp-control-token $TOKEN \
--context 262144 --sessions 2 --served-model-name Qwen3.8-Flash-Next \
--prefill-chunk 2048 --draft-vocab 131072 ${PLE_EXTRA_ARGS:-}"
}

kill_launched() {  # kill_launched TAG: terminate the ranks this start() launched
  local tag="$1"
  for f in "$STATE/rank0-$tag.pid"; do
    [ -s "$f" ] && kill -TERM "$(cat "$f")" 2>/dev/null
  done
  if [ -s "$STATE/rank1-$tag.pid" ]; then
    ssh root@$HOST_B "kill -TERM $(cat "$STATE/rank1-$tag.pid") 2>/dev/null" || true
  fi
  local a=1 b=1 t
  for t in $(seq 1 15); do
    a=$(pgrep -f "$PAIR_PAT" | wc -l)
    b=$(ssh root@$HOST_B "pgrep -f '$PAIR_PAT' | wc -l")
    [ "$a" = "0" ] && [ "$b" = "0" ] && break
    sleep 2
  done
  pkill -9 -f "$PAIR_PAT" 2>/dev/null
  ssh root@$HOST_B "pkill -9 -f '$PAIR_PAT'" 2>/dev/null
  log "start: killed half-launched pair (tag=$tag) rankA=$a rankB=$b"
}

start() {
  local arm="${1:?IQ4|BF16}"; local tag="${2:-$arm}"
  local model=$IQ4; [ "$arm" = "BF16" ] && model=$BF16
  if pgrep -f "$SERVE_PAT" >/dev/null; then
    log "ERROR: a serve is already running (production not parked, or a leftover pair); refusing to double up"
    return 1
  fi
  [ -c /dev/tbstream0 ] || { log "ERROR: /dev/tbstream0 missing"; return 1; }
  for g in /sys/kernel/config/thunderbolt/stream/*/gufo; do
    if [ -d "$g" ] && [ "$(cat "$g/busy_poll" 2>/dev/null)" != "1" ]; then
      log "ERROR: $g busy_poll != 1"; return 1
    fi
  done
  sha256sum "$BIN"
  local r0="$EV/$PFX-serve-$tag-r0.log" r1="/root/ple-native/$PFX-serve-$tag-r1.log"
  local args; args=$(args "$model")
  log "START arm=$arm tag=$tag model=$model port=$PAIR_PORT"
  ssh root@$HOST_B "PORT=$PAIR_PORT nohup $BIN $args --tp-rank 1 \
    --tp-bootstrap-host $TBNET_BASE.1 > $r1 2>&1 & echo \$!" > "$STATE/rank1-$tag.pid"
  sleep 3
  PORT=$PAIR_PORT nohup "$BIN" $args --tp-rank 0 > "$r0" 2>&1 &
  echo $! > "$STATE/rank0-$tag.pid"
  log "rank1 pid $(cat "$STATE/rank1-$tag.pid") on $HOST_B, rank0 pid $(cat "$STATE/rank0-$tag.pid")"
  local t body
  for t in $(seq 1 90); do
    body=$(curl -s -m 5 "http://127.0.0.1:$PAIR_PORT/ready" 2>/dev/null)
    case "$body" in *'"ready"'*) log "READY after ~$((t*3))s (tag=$tag)"; return 0 ;; esac
    sleep 3
  done
  log "NEVER-READY (tag=$tag); killing the half-launched pair before returning failure"
  tail -5 "$r0"
  kill_launched "$tag"
  return 1
}

stop() {
  local tag="${1:-}"
  local f="$STATE/rank0-$tag.pid"
  [ -s "$f" ] && kill -TERM "$(cat "$f")" 2>/dev/null
  if [ -s "$STATE/rank1-$tag.pid" ]; then
    ssh root@$HOST_B "kill -TERM $(cat "$STATE/rank1-$tag.pid") 2>/dev/null" || true
  fi
  local a=1 b=1 t
  for t in $(seq 1 20); do
    a=$(pgrep -f "$PAIR_PAT" | wc -l)
    b=$(ssh root@$HOST_B "pgrep -f '$PAIR_PAT' | wc -l")
    [ "$a" = "0" ] && [ "$b" = "0" ] && break
    sleep 2
  done
  pkill -9 -f "$PAIR_PAT" 2>/dev/null
  ssh root@$HOST_B "pkill -9 -f '$PAIR_PAT'" 2>/dev/null
  # A SIGKILLed rank can take seconds to be reaped (teardown against a dead
  # tbstream peer); polling before declaring failure avoids a false REMAIN.
  for t in $(seq 1 30); do
    a=$(pgrep -f "$PAIR_PAT" | wc -l)
    b=$(ssh root@$HOST_B "pgrep -f '$PAIR_PAT' | wc -l")
    [ "$a" = "0" ] && [ "$b" = "0" ] && break
    sleep 2
  done
  if [ "$a" != "0" ] || [ "$b" != "0" ]; then
    log "ERROR stop (tag=$tag): pair processes REMAIN on a rank (rankA=$a rankB=$b)"
    return 1
  fi
  log "pair stopped (tag=$tag) rankA=$a rankB=$b"
  if [ -n "$tag" ]; then
    # Optional archival only: a probe-only tag (no serve logs) or a missing
    # rank1 log must never fail an otherwise-successful stop.
    if scp -q root@$HOST_B:"/root/ple-native/$PFX-serve-$tag-r1.log" "$EV/$PFX-serve-$tag-r1.log" 2>/dev/null; then
      log "rank1 log archived to $EV/$PFX-serve-$tag-r1.log"
    else
      log "note: no rank1 serve log archived for tag=$tag (probe-only tag or scp failed)"
    fi
  fi
  return 0
}

status() {
  pgrep -af "$SERVE_PAT" || echo "rankA: none"
  ssh root@$HOST_B "pgrep -af '$SERVE_PAT'" || echo "rankB: none"
  curl -s -m 3 "http://127.0.0.1:$PROD_PORT/ready" || true; echo
}

case "${1:-}" in
  verify) verify ;;
  park) park ;;
  restore) restore ;;
  status) status ;;
  start) shift; start "$@" ;;
  stop) shift; stop "${1:-}" ;;
  *) echo "usage: $0 verify|park|restore|status|start IQ4|BF16 [TAG]|stop [TAG]" >&2; exit 2 ;;
esac
