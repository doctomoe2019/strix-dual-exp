#!/usr/bin/env bash
# Phase-3 window 2: paired WikiText-2 perplexity via gpu_probe KLD mode on
# the TP2 pair. Arm order IQ4 then BF16:
#   IQ4  reads a zero-padded dummy base (its derived base numbers are
#        meaningless) and SAVES its own quantized log-probs;
#   BF16 reads the IQ4 save as base -> prints ppl (BF16), ppl_base (IQ4),
#        mean_kld and top1 agreement, and saves its own log-probs.
# The per-chunk paired CI is computed afterwards by ple_native_kld_analysis.py.
#
# Status discipline: `set -euo pipefail`; teed pipelines report their real
# exit status via PIPESTATUS, park/restore failures are hard errors and the
# script exits non-zero if any step, the park or the restore failed.
set -euo pipefail
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
PROBE=/root/strix-dual-exp/scripts/ple-native-probe.sh
EV=/root/strix-dual-exp/evidence/ple-native/phase3
WLOG="$EV/03-window2.log"
PRLOG="$EV/03-window2-park-restore.log"
G0=/root/goal-worktrees/2026-10-17-ple-native-bf16/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next/qwen38_flash_next_gpu_probe
IQ4=/models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
BF16=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
FIX=/root/ple-native
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

cleanup() {
  local rc=$?
  echo "[window2] trap (rc=$rc): stopping pair, restoring production"
  "$PAIR" stop w2 >>"$WLOG" 2>&1 || true
  if restore_prod; then
    exit "$rc"
  fi
  echo "[window2] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
# The trap stays armed for the whole script: it stops the pair again and
# re-verifies the restore on the way out (both idempotent), so a failed stop
# or restore can never be masked by an early disarm.
trap cleanup EXIT

step() {
  local desc="$1"; shift
  echo "[window2] step: $desc" | tee -a "$WLOG"
  set +e
  "$@" 2>&1 | tee -a "$WLOG"
  local rc="${PIPESTATUS[0]}"
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "[window2] ERROR: rc=$rc in step: $desc" | tee -a "$WLOG" >&2
    STATUS=1
  fi
  return 0
}

echo "[window2] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[window2] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

step "probe binary digests" "$PROBE" sha

echo "[window2] IQ4 arm (kld-save)"
step "gpu_probe kld IQ4" "$PROBE" pair w2-iq4-kld "$G0" \
  --model "$IQ4" --kld-base "$FIX/ple-wt2-dummy.kld" \
  --kld-save "$FIX/ple-wt2-iq4.kld" --tp-transport tbstream
sha256sum "$FIX/ple-wt2-iq4.kld" 2>&1 | tee -a "$WLOG"

echo "[window2] copy IQ4 kld save to rank B (rank 1 reads the base file too)"
if scp -q "$FIX/ple-wt2-iq4.kld" root@10.55.0.2:"$FIX/ple-wt2-iq4.kld" 2>>"$WLOG" \
   && ssh root@10.55.0.2 "sha256sum $FIX/ple-wt2-iq4.kld" 2>&1 | tee -a "$WLOG" \
   && sha256sum "$FIX/ple-wt2-iq4.kld"; then
  :
else
  echo "[window2] ERROR: IQ4 kld save did not reach rank B or digest mismatch" \
    | tee -a "$WLOG" >&2
  STATUS=1
fi

echo "[window2] BF16 arm (kld-base = IQ4 save, kld-save = BF16)"
step "gpu_probe kld BF16" "$PROBE" pair w2-bf16-kld "$G0" \
  --model "$BF16" --kld-base "$FIX/ple-wt2-iq4.kld" \
  --kld-save "$FIX/ple-wt2-bf16.kld" --tp-transport tbstream
sha256sum "$FIX/ple-wt2-bf16.kld" 2>&1 | tee -a "$WLOG"

step "stop pair" "$PAIR" stop w2

# Restore production; the EXIT trap stays armed and re-verifies (idempotent).
if ! restore_prod; then
  echo "[window2] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[window2] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
