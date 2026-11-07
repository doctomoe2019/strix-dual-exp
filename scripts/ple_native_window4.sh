#!/usr/bin/env bash
# Phase-4 performance A/B window: same discipline as the phase-3 screen
# windows (park -> arm A battery -> arm B battery -> restore, pair stopped on
# every failure path, EXIT trap never disarmed, restore responder verified),
# running the pinned performance battery (ple_native_perf.py) against the
# manual TP2 pair on PAIR_PORT.
#
# Usage: ple_native_window4.sh FIRST_ARM SECOND_ARM REPLICATE SUFFIX
#   e.g.: ple_native_window4.sh IQ4 BF16 1 perf-r1
#         ple_native_window4.sh BF16 IQ4 2 perf-r2   (order counterbalanced)
#
# The pair carries HTTP-admission knobs (PLE_EXTRA_ARGS) so the C32 leg can
# actually hold 32 clients: --max-connections 64 plus the per-client pending
# quota (default 4 per peer IP would 429 every client beyond the fourth --
# measured, see 04-perf-IQ4-perf-r1.jsonl c32 rows). Every inference argument
# stays exactly the guardian's ARGS, on both arms identically.
set -euo pipefail
FIRST="${1:?IQ4|BF16}"; SECOND="${2:?IQ4|BF16}"; REP="${3:?replicate}"; SUFFIX="${4:?suffix}"
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
PERF=/root/strix-dual-exp/scripts/ple_native_perf.py
EV=/root/strix-dual-exp/evidence/ple-native/phase4
STATE=/tmp/opencode/ple-p3-pair
WLOG="$EV/04-window-$SUFFIX.log"
PRLOG="$EV/04-window-$SUFFIX-park-restore.log"
PAIR_PORT="${PAIR_PORT:-15005}"
export PLE_EV="$EV" PLE_PREFIX=04
export PLE_EXTRA_ARGS="--max-connections 64 --max-pending 40 --max-pending-per-client 40"
mkdir -p "$EV"

STATUS=0

park_prod() {
  "$PAIR" park 2>&1 | tee "$PRLOG"
  return "${PIPESTATUS[0]}"
}

restore_prod() {
  "$PAIR" restore 2>&1 | tee -a "$PRLOG"
  return "${PIPESTATUS[0]}"
}

stop_pair() {  # stop_pair TAG: idempotent; records failure without aborting
  local tag="$1"
  if "$PAIR" stop "$tag" 2>&1 | tee -a "$WLOG"; then
    return 0
  fi
  echo "[perf $SUFFIX] ERROR: pair stop FAILED for $tag" | tee -a "$WLOG" >&2
  STATUS=1
  return 1
}

cleanup() {  # EXIT trap: runs on every exit path, never disarmed
  local rc=$?
  local arm tag
  echo "[perf $SUFFIX] trap (rc=$rc): stopping pair (both arm tags), restoring production"
  for arm in "$FIRST" "$SECOND"; do
    tag="perf-$SUFFIX-$arm"
    "$PAIR" stop "$tag" >>"$WLOG" 2>&1 || true
  done
  if restore_prod; then
    exit "$rc"
  fi
  echo "[perf $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
trap cleanup EXIT

echo "[perf $SUFFIX] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[perf $SUFFIX] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

for arm in "$FIRST" "$SECOND"; do
  tag="perf-$SUFFIX-$arm"
  echo "[perf $SUFFIX] ===== arm $arm ($(date '+%F %T%z')) port=$PAIR_PORT" | tee -a "$WLOG"
  if ! "$PAIR" start "$arm" "$tag" 2>&1 | tee -a "$WLOG"; then
    echo "[perf $SUFFIX] ERROR: pair start FAILED for $arm (pre-flight or NEVER-READY); stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  if ! python3 "$PERF" --arm "$arm" --replicate "$REP" --port "$PAIR_PORT" \
      --rank0-pid-file "$STATE/rank0-$tag.pid" \
      --rank1-pid-file "$STATE/rank1-$tag.pid" \
      --out "$EV/04-perf-$arm-$SUFFIX.jsonl" 2>&1 | tee -a "$WLOG"; then
    echo "[perf $SUFFIX] ERROR: perf client FAILED for $arm; stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  curl -s -m 5 "http://127.0.0.1:$PAIR_PORT/metrics" > "$EV/04-metrics-$arm-$SUFFIX.txt" \
    || echo "[perf $SUFFIX] warn: metrics scrape failed on $PAIR_PORT" | tee -a "$WLOG"
  cp "$EV/04-serve-$tag-r0.log" "$EV/04-serve-$arm-$SUFFIX-r0.log" 2>/dev/null \
    || echo "[perf $SUFFIX] warn: rank0 serve log copy failed" | tee -a "$WLOG"
  if ! stop_pair "$tag"; then
    echo "[perf $SUFFIX] ERROR: pair stop FAILED for $arm; aborting the window" \
      | tee -a "$WLOG" >&2
    STATUS=1
    break
  fi
done

# Belt and braces: stop both tags again before restoring (idempotent; catches
# any path that could leave a rank behind).
for arm in "$FIRST" "$SECOND"; do
  stop_pair "perf-$SUFFIX-$arm" || true
done

# Restore production; the EXIT trap stays armed and will stop the pair again
# and re-verify the restore (both idempotent) on the way out.
if ! restore_prod; then
  echo "[perf $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[perf $SUFFIX] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
