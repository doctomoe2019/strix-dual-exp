#!/usr/bin/env bash
# Phase-4 window: second independent paired WikiText-2 perplexity replicate
# via gpu_probe KLD mode on the TP2 pair (the phase-3 protocol, new evidence
# dir and kld files). Arm order IQ4 then BF16:
#   IQ4  reads the zero-padded dummy base and SAVES its own quantized
#        log-probs;
#   BF16 reads the IQ4 save as base -> prints ppl (BF16), ppl_base (IQ4),
#        mean_kld and top1 agreement, and saves its own log-probs.
# Per-chunk paired CI comes from ple_native_kld_analysis.py afterwards.
#
# Status discipline: `set -euo pipefail`; teed pipelines report their real
# exit status via PIPESTATUS; park/restore failures are hard errors; the
# EXIT trap stays armed for the whole script.
set -euo pipefail
PAIR=/root/strix-dual-exp/scripts/ple-native-pair.sh
PROBE=/root/strix-dual-exp/scripts/ple-native-probe.sh
EV=/root/strix-dual-exp/evidence/ple-native/phase4
WLOG="$EV/04-window-kld.log"
PRLOG="$EV/04-window-kld-park-restore.log"
export PLE_EV="$EV" PLE_PREFIX=04
G0=/root/goal-worktrees/2026-10-17-ple-native-bf16/build/gpu-tp2-tbstream/tests/models/qwen38_flash_next/qwen38_flash_next_gpu_probe
IQ4=/models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
BF16=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
FIX=/root/ple-native
KIQ4=$FIX/ple-wt2-iq4-p4.kld
KBF16=$FIX/ple-wt2-bf16-p4.kld
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
  echo "[kld] trap (rc=$rc): stopping pair, restoring production"
  "$PAIR" stop kld >>"$WLOG" 2>&1 || true
  if restore_prod; then
    exit "$rc"
  fi
  echo "[kld] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  exit 1
}
trap cleanup EXIT

step() {
  local desc="$1"; shift
  echo "[kld] step: $desc" | tee -a "$WLOG"
  set +e
  "$@" 2>&1 | tee -a "$WLOG"
  local rc="${PIPESTATUS[0]}"
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "[kld] ERROR: rc=$rc in step: $desc" | tee -a "$WLOG" >&2
    STATUS=1
  fi
  return 0
}

echo "[kld] $(date '+%F %T%z') park"
if ! park_prod; then
  echo "[kld] ERROR: park failed; see $PRLOG" | tee -a "$PRLOG" >&2
  exit 1
fi

step "probe binary digests" "$PROBE" sha

echo "[kld] IQ4 arm (kld-save)"
step "gpu_probe kld IQ4" "$PROBE" pair kld-iq4 "$G0" \
  --model "$IQ4" --kld-base "$FIX/ple-wt2-dummy.kld" \
  --kld-save "$KIQ4" --tp-transport tbstream
sha256sum "$KIQ4" 2>&1 | tee -a "$WLOG"

echo "[kld] copy IQ4 kld save to rank B (rank 1 reads the base file too)"
if scp -q "$KIQ4" root@10.55.0.2:"$KIQ4" 2>>"$WLOG" \
   && ssh root@10.55.0.2 "sha256sum $KIQ4" 2>&1 | tee -a "$WLOG" \
   && sha256sum "$KIQ4"; then
  :
else
  echo "[kld] ERROR: IQ4 kld save did not reach rank B or digest mismatch" \
    | tee -a "$WLOG" >&2
  STATUS=1
fi

echo "[kld] BF16 arm (kld-base = IQ4 save, kld-save = BF16)"
step "gpu_probe kld BF16" "$PROBE" pair kld-bf16 "$G0" \
  --model "$BF16" --kld-base "$KIQ4" \
  --kld-save "$KBF16" --tp-transport tbstream
sha256sum "$KBF16" 2>&1 | tee -a "$WLOG"

step "stop pair" "$PAIR" stop kld

if ! restore_prod; then
  echo "[kld] ERROR: production restore FAILED (/ready never 200); see $PRLOG" \
    | tee -a "$PRLOG" >&2
  STATUS=1
fi
if [ "$STATUS" -ne 0 ]; then
  echo "[kld] completed WITH ERRORS (STATUS=$STATUS); see $WLOG" >&2
fi
exit "$STATUS"
