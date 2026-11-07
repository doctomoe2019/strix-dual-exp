#!/usr/bin/env bash
# Phase-4 full quality battery window: the phase-3 screen protocol with the
# complete pinned fixture set, both arms, one window per replicate, order
# counterbalanced across replicates. Same failure discipline as the phase-3
# screen driver (pair stopped on every failure path, EXIT trap never
# disarmed, restore responder verified); the pair serves on PAIR_PORT 15005.
#
# Usage: ple_native_window5.sh FIRST_ARM SECOND_ARM REPLICATE SUFFIX
#   e.g.: ple_native_window5.sh IQ4 BF16 3 qual-r3
#         ple_native_window5.sh BF16 IQ4 4 qual-r4   (order counterbalanced)
set -euo pipefail
FIRST="${1:?IQ4|BF16}"; SECOND="${2:?IQ4|BF16}"; REP="${3:?replicate}"; SUFFIX="${4:?suffix}"
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
SCREEN=/root/strix-dual-exp/scripts/ple_native_screen.py
EV=/root/strix-dual-exp/evidence/ple-native/phase4
WLOG="$EV/04-window-$SUFFIX.log"
PRLOG="$EV/04-window-$SUFFIX-park-restore.log"
PAIR_PORT="${PAIR_PORT:-15005}"
export PLE_EV="$EV" PLE_PREFIX=04
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
  echo "[qual $SUFFIX] ERROR: pair stop FAILED for $tag" | tee -a "$WLOG" >&2
  STATUS=1
  return 1
}

cleanup() {  # EXIT trap: runs on every exit path, never disarmed
  local rc=$?
  local arm tag
  echo "[qual $SUFFIX] trap (rc=$rc): stopping pair (both arm tags), restoring production"
  for arm in "$FIRST" "$SECOND"; do
    tag="qual-$SUFFIX-$arm"
    "$PAIR" stop "$tag" >>"$WLOG" 2>&1 || true
  done
  if restore_prod; then
    exit "$rc"
  fi
  echo "[qual $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
trap cleanup EXIT

echo "[qual $SUFFIX] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[qual $SUFFIX] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

for arm in "$FIRST" "$SECOND"; do
  tag="qual-$SUFFIX-$arm"
  echo "[qual $SUFFIX] ===== arm $arm ($(date '+%F %T%z')) port=$PAIR_PORT" | tee -a "$WLOG"
  if ! "$PAIR" start "$arm" "$tag" 2>&1 | tee -a "$WLOG"; then
    echo "[qual $SUFFIX] ERROR: pair start FAILED for $arm (pre-flight or NEVER-READY); stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  if ! python3 "$SCREEN" --arm "$arm" --replicate "$REP" --port "$PAIR_PORT" \
      --out "$EV/04-screen-$arm-$SUFFIX.jsonl" 2>&1 | tee -a "$WLOG"; then
    echo "[qual $SUFFIX] ERROR: screen client FAILED for $arm; stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  curl -s -m 5 "http://127.0.0.1:$PAIR_PORT/metrics" > "$EV/04-metrics-$arm-$SUFFIX.txt" \
    || echo "[qual $SUFFIX] warn: metrics scrape failed on $PAIR_PORT" | tee -a "$WLOG"
  cp "$EV/04-serve-$tag-r0.log" "$EV/04-serve-$arm-$SUFFIX-r0.log" 2>/dev/null \
    || echo "[qual $SUFFIX] warn: rank0 serve log copy failed" | tee -a "$WLOG"
  if ! stop_pair "$tag"; then
    echo "[qual $SUFFIX] ERROR: pair stop FAILED for $arm; aborting the window" \
      | tee -a "$WLOG" >&2
    STATUS=1
    break
  fi
done

# Belt and braces: stop both tags again before restoring (idempotent).
for arm in "$FIRST" "$SECOND"; do
  stop_pair "qual-$SUFFIX-$arm" || true
done

if ! restore_prod; then
  echo "[qual $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[qual $SUFFIX] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
