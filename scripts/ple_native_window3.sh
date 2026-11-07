#!/usr/bin/env bash
# Phase-3 window 3/4: serving-level paired quality screen.
# Starts the manual TP2 pair (deployed binary ba355d5) on one arm, runs the
# pinned fixture battery, stops it, then the other arm, same battery.
#
# Usage: ple_native_window3.sh FIRST_ARM SECOND_ARM REPLICATE OUTSUFFIX
#   e.g.: ple_native_window3.sh IQ4 BF16 1 r1     (window 3)
#         ple_native_window3.sh BF16 IQ4 2 r2     (window 4, order reversed)
#
# Failure discipline (fix rounds 1+2): `set -euo pipefail`; teed pipelines
# report their real exit status (pipefail/PIPESTATUS); a failed park, pair
# start, screen client, pair stop or restore all propagate to a non-zero
# exit; EVERY failure path stops the just-started pair before breaking; the
# EXIT trap stays armed for the whole script (it stops both arm tags — with
# the correct per-arm names — and re-verifies the restore, both idempotent),
# so the pair can never be left running behind a green exit; the pair serves
# on PAIR_PORT (not gufo-prod's 15003) and ple-native-pair.sh restore()
# verifies the /ready responder is the gufo-prod unit itself.
set -euo pipefail
FIRST="${1:?IQ4|BF16}"; SECOND="${2:?IQ4|BF16}"; REP="${3:?replicate}"; SUFFIX="${4:?suffix}"
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
SCREEN=/root/strix-dual-exp/scripts/ple_native_screen.py
EV=/root/strix-dual-exp/evidence/ple-native/phase3
WLOG="$EV/03-window-$SUFFIX.log"
PRLOG="$EV/03-window-$SUFFIX-park-restore.log"
PAIR_PORT="${PAIR_PORT:-15005}"
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
  echo "[screen $SUFFIX] ERROR: pair stop FAILED for $tag" | tee -a "$WLOG" >&2
  STATUS=1
  return 1
}

cleanup() {  # EXIT trap: runs on every exit path, never disarmed
  local rc=$?
  local arm tag
  echo "[screen $SUFFIX] trap (rc=$rc): stopping pair (both arm tags), restoring production"
  for arm in "$FIRST" "$SECOND"; do
    tag="scr-$SUFFIX-$arm"
    "$PAIR" stop "$tag" >>"$WLOG" 2>&1 || true
  done
  if restore_prod; then
    exit "$rc"
  fi
  echo "[screen $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
trap cleanup EXIT

echo "[screen $SUFFIX] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[screen $SUFFIX] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

for arm in "$FIRST" "$SECOND"; do
  tag="scr-$SUFFIX-$arm"
  echo "[screen $SUFFIX] ===== arm $arm ($(date '+%F %T%z')) port=$PAIR_PORT" | tee -a "$WLOG"
  if ! "$PAIR" start "$arm" "$tag" 2>&1 | tee -a "$WLOG"; then
    echo "[screen $SUFFIX] ERROR: pair start FAILED for $arm (pre-flight or NEVER-READY); stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  if ! python3 "$SCREEN" --arm "$arm" --replicate "$REP" --port "$PAIR_PORT" \
      --out "$EV/03-screen-$arm-$SUFFIX.jsonl" 2>&1 | tee -a "$WLOG"; then
    echo "[screen $SUFFIX] ERROR: screen client FAILED for $arm; stopping the pair and aborting the window" \
      | tee -a "$WLOG" >&2
    stop_pair "$tag" || true
    STATUS=1
    break
  fi
  curl -s -m 5 "http://127.0.0.1:$PAIR_PORT/metrics" > "$EV/03-metrics-$arm-$SUFFIX.txt" \
    || echo "[screen $SUFFIX] warn: metrics scrape failed on $PAIR_PORT" | tee -a "$WLOG"
  cp "$EV/03-serve-$tag-r0.log" "$EV/03-serve-$arm-$SUFFIX-r0.log" 2>/dev/null \
    || echo "[screen $SUFFIX] warn: rank0 serve log copy failed" | tee -a "$WLOG"
  if ! stop_pair "$tag"; then
    echo "[screen $SUFFIX] ERROR: pair stop FAILED for $arm; aborting the window" \
      | tee -a "$WLOG" >&2
    STATUS=1
    break
  fi
done

# Belt and braces: stop both tags again before restoring (idempotent; catches
# any path that could leave a rank behind).
for arm in "$FIRST" "$SECOND"; do
  stop_pair "scr-$SUFFIX-$arm" || true
done

# Restore production; the EXIT trap stays armed and will stop the pair again
# and re-verify the restore (both idempotent) on the way out.
if ! restore_prod; then
  echo "[screen $SUFFIX] ERROR: production restore FAILED (/ready never 200, or answered by a non-production serve); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[screen $SUFFIX] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
