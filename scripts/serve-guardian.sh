#!/usr/bin/env bash
# Serve guardian: start the TP2 serve pair, warm the inference path with an
# unclassified request, then judge warmed performance — capped. Once a pair
# passes it is supervised; if it ever exits, a fresh cycle starts with a
# reset retry budget.
#
# Phase A of the slow-session record (evidence/prefill-triage/slow-session/):
# a fresh process's first real request carries lazy first-use costs, so the
# cold canary is recorded but never classifies the process; the measured
# canary runs after the warmup. Request/transport/schema failures are ERROR,
# not SLOW. Successful acceptance resets the attempt budget, and teardown
# does not touch system memory state (the earlier drop_caches/compaction
# recovery had no matched evidence and is not part of the default path).
#
# Env: SERVE_BIN, SERVE_MODEL, SERVE_MTP, SERVE_CONTEXT (65536),
# SERVE_SESSIONS (1), SERVE_PORT (8080), SERVE_BOOTSTRAP_PORT (18515),
# SERVE_CONTROL_PORT (18516), SERVE_CANARY_TPS (1900),
# SERVE_CANARY_TOKENS (8192), SERVE_MAX_RETRIES (3), SERVE_CONFIRM (1:
# one confirmation canary before declaring a warmed SLOW).
# Hosts/tbnet from env.sh (neutral defaults below).
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.0.0}"
: "${SERVE_BIN:=/root/newbin/gufo}"
: "${SERVE_MODEL:=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}"
: "${SERVE_MTP:=/models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf}"
: "${SERVE_CONTEXT:=65536}" "${SERVE_SESSIONS:=1}" "${SERVE_PORT:=8080}"
: "${SERVE_BOOTSTRAP_PORT:=18515}" "${SERVE_CONTROL_PORT:=18516}"
# Public API model ID override (--served-model-name); empty = the model's
# own name. The canaries send the same ID.
: "${SERVE_MODEL_NAME:=}"
: "${SERVE_CANARY_TPS:=1900}" "${SERVE_CANARY_TOKENS:=8192}"
: "${SERVE_MAX_RETRIES:=3}" "${SERVE_CONFIRM:=1}"
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_DIR="$_dir/../evidence/serve-guardian/$RUN_ID"
mkdir -p "$LOG_DIR"
LOG="$_dir/../evidence/serve-guardian.log"

log() { echo "[$(date +%F\ %T)] $*" | tee -a "$LOG"; }

bin_pattern() {
  # grep-safe pattern for "<path>/basename serve" cmdlines.
  local base; base=$(basename "$SERVE_BIN")
  printf '[%s]%s serve' "${base:0:1}" "${base:1}"
}
serve_running() {
  ps aux | grep "$(bin_pattern)" | grep -v grep | head -1
}
remote_serve_running() {
  local pat; pat=$(bin_pattern)
  ssh "$HOST_B" "ps aux | grep '$pat' | grep -v grep | head -1"
}

R0_PID=""
R1_PID=""

# TERM both ranks by PID, wait for exit, escalate to -9. Never touches
# system memory state; teardown settling beyond process exit is the next
# diagnostic's job, not a default repair.
teardown() {
  if [ -n "$R0_PID" ]; then
    kill -TERM "$R0_PID" 2>/dev/null
  fi
  if [ -n "$R1_PID" ]; then
    ssh "$HOST_B" "kill -TERM $R1_PID 2>/dev/null" 2>/dev/null
  fi
  for t in $(seq 1 15); do
    [ -z "$(serve_running)" ] && [ -z "$(remote_serve_running)" ] && break
    sleep 2
  done
  if [ -n "$R0_PID" ] && [ -n "$(serve_running)" ]; then
    kill -9 "$R0_PID" 2>/dev/null
    log "WARNING: rank0 needed SIGKILL"
  fi
  if [ -n "$R1_PID" ] && [ -n "$(remote_serve_running)" ]; then
    ssh "$HOST_B" "kill -9 $R1_PID" 2>/dev/null
    log "WARNING: rank1 needed SIGKILL"
  fi
  R0_PID=""
  R1_PID=""
}
trap 'log "guardian stopping"; teardown; exit 0' TERM INT

if [ -n "$(serve_running)" ] || [ -n "$(remote_serve_running)" ]; then
  log "ERROR: a serve is already running on this pair; refusing to double up"
  exit 1
fi
if [ ! -c /dev/tbstream0 ]; then
  log "ERROR: /dev/tbstream0 missing — run scripts/bringup.sh first"
  exit 1
fi
for g in /sys/kernel/config/thunderbolt/stream/*/gufo; do
  if [ -d "$g" ] && [ "$(cat "$g/busy_poll" 2>/dev/null)" != "1" ]; then
    log "ERROR: $g busy_poll=$(cat "$g/busy_poll" 2>/dev/null) (need 1); the heal-watch daemon should repair this — check systemctl status tbstream-heal@0"
    exit 1
  fi
done

canary() { # $1 log label, $2 warmup flag (1 = unclassified warmup request)
  SERVE_PORT=$SERVE_PORT SERVE_CANARY_TPS=$SERVE_CANARY_TPS \
    SERVE_CANARY_TOKENS=$SERVE_CANARY_TOKENS SERVE_CANARY_LABEL="$1" \
    SERVE_CANARY_WARMUP="$2" SERVE_MODEL_NAME="$SERVE_MODEL_NAME" \
    bash "$_dir/serve-canary.sh"
}

wait_ready() {
  for t in $(seq 1 90); do
    body=$(curl -s -m 5 "http://127.0.0.1:$SERVE_PORT/ready" 2>/dev/null)
    case "$body" in *'"ready"'*) return 0 ;; esac
    sleep 3
  done
  return 1
}

cycle=0
while :; do
  cycle=$((cycle + 1))
  # Fresh shared control token per cycle; never written to disk.
  TOKEN=$(od -An -N16 /dev/urandom | tr -d ' \n')
  ARGS="serve llm --model $SERVE_MODEL --speculative mtp --mtp-model $SERVE_MTP \
    --tp-world-size 2 --tp-transport tbstream \
    --tp-bootstrap-port $SERVE_BOOTSTRAP_PORT --tp-control-port $SERVE_CONTROL_PORT \
    --tp-control-token $TOKEN --context $SERVE_CONTEXT --sessions $SERVE_SESSIONS"
  [ -n "$SERVE_MODEL_NAME" ] && ARGS="$ARGS --served-model-name $SERVE_MODEL_NAME"
  [ -n "$SERVE_PREFILL_CHUNK" ] && ARGS="$ARGS --prefill-chunk $SERVE_PREFILL_CHUNK"

  # Rank 1 first (hostB), then rank 0 here; PORT env carries the port.
  # The log directory must exist on both hosts (rank1's redirect happens
  # remotely).
  ssh "$HOST_B" "mkdir -p $LOG_DIR"
  R1_PID=$(ssh "$HOST_B" "PORT=$SERVE_PORT nohup $SERVE_BIN $ARGS --tp-rank 1 \
    --tp-bootstrap-host $TBNET_BASE.1 > $LOG_DIR/r1-c$cycle.log 2>&1 & echo \$!")
  sleep 3
  PORT=$SERVE_PORT nohup $SERVE_BIN $ARGS --tp-rank 0 \
    > "$LOG_DIR/r0-c$cycle.log" 2>&1 &
  R0_PID=$!

  verdict="ERROR"
  if ! wait_ready; then
    log "cycle $cycle: ERROR server never became ready (logs: $LOG_DIR)"
  else
    if canary warmup 1 >> "$LOG" 2>&1; then
      rc=0
      canary c1 0 >> "$LOG" 2>&1 || rc=$?
      if [ "$rc" -eq 0 ]; then
        verdict="FAST"
      elif [ "$rc" -eq 1 ]; then
        if [ "$SERVE_CONFIRM" = "1" ] && canary c2 0 >> "$LOG" 2>&1; then
          log "cycle $cycle: c1 measured SLOW but confirmation c2 passed — accepting"
          verdict="FAST"
        else
          verdict="SLOW"
        fi
      else
        log "cycle $cycle: canary ERROR (rc=$rc)"
      fi
    else
      log "cycle $cycle: warmup canary ERROR"
    fi
  fi

  if [ "$verdict" = "FAST" ]; then
    log "cycle $cycle: accepted (rank0 pid $R0_PID, rank1 pid $R1_PID, logs: $LOG_DIR); supervising"
    wait "$R0_PID"
    log "rank0 exited; restarting with a fresh retry budget"
    cycle=0
    teardown
    sleep 5
  elif [ "$verdict" = "SLOW" ]; then
    log "cycle $cycle: SLOW after warmup — warmed process below threshold; restarting"
    teardown
  else
    log "cycle $cycle: ERROR path — restarting"
    teardown
  fi

  sleep 3
  if [ "$cycle" -ge "$SERVE_MAX_RETRIES" ]; then
    log "giving up after $cycle cycles (raise SERVE_MAX_RETRIES or investigate; logs: $LOG_DIR)"
    exit 1
  fi
done
