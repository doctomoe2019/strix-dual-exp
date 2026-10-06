#!/usr/bin/env bash
# Serve warm-up canary: one fixed-shape synthetic prefill through the live
# HTTP endpoint; reports prefill_tokens_per_second with an explicit verdict.
#
# Measurement hygiene (slow-session record,
# evidence/prefill-triage/slow-session/): a fresh process's FIRST real
# request carries lazy first-use costs (GEMM plan setup, MMQ arena, transport
# staging worker, n-gram row cache, checkpoint buffers), so a cold first
# canary must never by itself classify a process as slow. The guardian sends
# an unclassified warmup canary before the measured one.
# Env: SERVE_PORT (8080), SERVE_CANARY_TPS (threshold),
# SERVE_CANARY_TOKENS (approximate token target), SERVE_MODEL_NAME,
# SERVE_CANARY_LABEL (log tag), SERVE_CANARY_WARMUP=1 (warmup request:
# never returns the SLOW verdict).
# Exit: 0 FAST (or warmup success), 1 SLOW (valid measurement below
# threshold), 2 ERROR (request failed, or not an uncached full prefill).
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${SERVE_PORT:=8080}" "${SERVE_CANARY_TPS:=1900}" "${SERVE_CANARY_TOKENS:=8192}"
: "${SERVE_MODEL_NAME:=Qwen3.8 Flash Next}" "${SERVE_CANARY_LABEL:=}"
warmup="${SERVE_CANARY_WARMUP:-0}"

python3 - "$SERVE_PORT" "$SERVE_CANARY_TPS" "$SERVE_CANARY_TOKENS" \
  "$SERVE_MODEL_NAME" "$warmup" "$SERVE_CANARY_LABEL" <<'EOF'
import json, secrets, sys, time, urllib.request

port, threshold, want_tokens, model, warmup, label = sys.argv[1:7]
threshold, want_tokens = float(threshold), int(want_tokens)
tag = f"canary[{label}]" if label else "canary"

# Unique nonce per invocation so the prompt cache can never swallow the
# canary; the counting body lands near one token per character.
nonce = secrets.token_hex(8)
parts, n, chars = [f"canary {nonce}: "], 0, len(f"canary {nonce}: ")
while chars < want_tokens:
    s = f"{n + 1}, "
    parts.append(s)
    chars += len(s)
    n += 1
body = json.dumps({"model": model,
                   "messages": [{"role": "user", "content": "".join(parts)}],
                   "max_tokens": 1, "temperature": 0}).encode()

t0 = time.time()
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                             data=body,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        out = json.load(r)
except Exception as e:
    print(f"{tag}: ERROR request failed: {e}")
    sys.exit(2)

u = out.get("usage", {})
g = u.get("gufo", {})
tps = u.get("prompt_tokens_per_second", 0) or 0
prompt_tokens = u.get("prompt_tokens", 0) or 0
prefill_tokens = g.get("prefill_tokens", 0) or 0
cached = u.get("cached_tokens", 0)
wall = (time.time() - t0) * 1000

# A measurement is only valid if it did real, full, uncached prefill work;
# anything else is a harness error, not a slow process.
if cached != 0 or prefill_tokens != prompt_tokens or \
        prompt_tokens < want_tokens * 0.6:
    print(f"{tag}: ERROR not an uncached full prefill "
          f"(prompt_tokens={prompt_tokens} prefill_tokens={prefill_tokens} "
          f"cached={cached})")
    sys.exit(2)

code = 0
if warmup == "1":
    verdict = "WARMUP"
else:
    verdict = "FAST" if tps >= threshold else "SLOW"
    code = 0 if verdict == "FAST" else 1
print(f"{tag}: {verdict}  prompt_tokens={prompt_tokens} "
      f"prefill_tps={tps:.1f} (threshold {threshold:.0f}) "
      f"prefill_ms={g.get('prefill_ms', 0):.0f} wall_ms={wall:.0f}")
sys.exit(code)
EOF
