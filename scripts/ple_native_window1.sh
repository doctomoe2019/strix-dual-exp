#!/usr/bin/env bash
# Phase-3 window 1: probe-level correctness gates + IQ4-vs-BF16 output
# characterization, both arms, same binary, TP2 tbstream pair (plus one
# single-host reference run per arm for the TP2 tolerance regime).
#
# Parks production first, restores at the end (trap-guarded). Everything is
# logged under evidence/ple-native/phase3/.
#
# Status discipline: `set -euo pipefail`; every teed pipeline's real exit
# status is taken from PIPESTATUS, park/restore failures are hard errors and
# the script exits non-zero if any probe run, the park or the restore failed
# (a failed restore is reported loudly and never masked by tee).
set -euo pipefail
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
PROBE=/root/strix-dual-exp/scripts/ple-native-probe.sh
EV=/root/strix-dual-exp/evidence/ple-native/phase3
WLOG="$EV/03-window1.log"
PRLOG="$EV/03-window1-park-restore.log"
TPA=/root/goal-worktrees/2026-10-17-ple-native-bf16/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next
R0=$TPA/qwen38_flash_next_tp_probe
G0=$TPA/qwen38_flash_next_gpu_probe
IQ4=/models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
BF16=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
FIX=/root/ple-native              # same fixture paths exist on both ranks
DUMPS=/root/ple-native/dumps
mkdir -p "$DUMPS" "$EV"
SPLIT_PROMPT=$(cat /tmp/opencode/char-prompt.txt)
TEXT_PROMPT='The per-layer embedding table maps each hashed n-gram to a short dense vector. Explain in two sentences what this buys a hybrid attention model, then name the capital of Australia.'

STATUS=0

park_prod() {
  "$PAIR" park 2>&1 | tee "$PRLOG"
  return "${PIPESTATUS[0]}"
}

restore_prod() {
  "$PAIR" restore 2>&1 | tee -a "$PRLOG"
  return "${PIPESTATUS[0]}"
}

cleanup() {
  local rc=$?
  echo "[window1] trap (rc=$rc): stopping pair, restoring production"
  "$PAIR" stop w1 >>"$WLOG" 2>&1 || true
  if restore_prod; then
    exit "$rc"
  fi
  echo "[window1] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
# The trap stays armed for the whole script: it stops the pair again and
# re-verifies the restore on the way out (both idempotent), so a failed stop
# or restore can never be masked by an early disarm.
trap cleanup EXIT

# Run one step, keep its real exit status, never abort the window mid-flight
# (set -e is suspended around the pipeline so a failed probe step is recorded
# instead of killing the window; the trap + final restore still guarantee
# production comes back).
step() {
  local desc="$1"; shift
  echo "[window1] step: $desc" | tee -a "$WLOG"
  set +e
  "$@" 2>&1 | tee -a "$WLOG"
  local rc="${PIPESTATUS[0]}"
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "[window1] ERROR: rc=$rc in step: $desc" | tee -a "$WLOG" >&2
    STATUS=1
  fi
  return 0
}

echo "[window1] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[window1] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

step "probe binary digests" "$PROBE" sha

for arm in BF16 IQ4; do
  case $arm in
    BF16) M=$BF16 ;;
    IQ4)  M=$IQ4 ;;
  esac
  echo "[window1] ===== arm $arm model=$M" | tee -a "$WLOG"

  # (1) greedy decode on both ranks, twice (rank agreement + run determinism)
  for run in 1 2; do
    step "tp_probe text ${arm} run ${run}" "$PROBE" pair "w1-${arm}-text${run}" "$R0" \
      --model "$M" --prompt "$TEXT_PROMPT" --tokens 96 --temperature 0 \
      --context 4096 --tp-transport tbstream
  done

  # (2) prefill-step invariance: --split on a 238-token prompt, both ranks
  step "tp_probe split ${arm}" "$PROBE" pair "w1-${arm}-split" "$R0" \
    --model "$M" --prompt "$SPLIT_PROMPT" --split 40 --tokens 1 \
    --context 4096 --tp-transport tbstream

  # (3) matched-token decode logits, TP2 pair (dump written on both ranks)
  step "gpu_probe TP2 dump ${arm}" "$PROBE" pair "w1-${arm}-dump" "$G0" \
    --model "$M" --prompt-file "$FIX/char-prompt.txt" \
    --decode-file "$FIX/char-cont.txt" \
    --dump "$DUMPS/${arm}-tp2.bin" --context 4096 \
    --tp-transport tbstream
  if scp -q root@10.55.0.2:"$DUMPS/${arm}-tp2.bin" "$EV/03-${arm}-tp2-rank1.bin" \
      2>>"$WLOG" \
     && sha256sum "$DUMPS/${arm}-tp2.bin" "$EV/03-${arm}-tp2-rank1.bin" 2>&1 | tee -a "$WLOG"; then
    :
  else
    echo "[window1] ERROR: rank-1 dump copy or digest failed for $arm" | tee -a "$WLOG" >&2
    STATUS=1
  fi

  # (4) single-host reference for the TP2 tolerance regime
  step "gpu_probe single-host ${arm}" "$PROBE" single "w1-${arm}-w1" "$G0" \
    --model "$M" --prompt-file "$FIX/char-prompt.txt" \
    --decode-file "$FIX/char-cont.txt" \
    --dump "$DUMPS/${arm}-w1.bin" --context 4096
done

step "stop pair" "$PAIR" stop w1

# Restore production; the EXIT trap stays armed and re-verifies (idempotent).
if ! restore_prod; then
  echo "[window1] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[window1] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
