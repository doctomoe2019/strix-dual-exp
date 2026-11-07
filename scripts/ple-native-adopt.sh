#!/usr/bin/env bash
# ple-native-adopt.sh — switch production (gufo-prod, TP2 pair) between the
# production IQ4_NL PLE pack (/models) and the native-BF16 candidate pack
# (/models-ple-ab) by editing the unit's SERVE_MODEL, restarting the unit,
# and verifying the result end to end.
#
# Phase 5 of goal/2026-10-17-ple-native-bf16 (decision phase). Both ranks
# read the same path (the guardian launches rank 1 on strix2 via ssh with
# the identical --model argument), so the only edit is strix1's unit env.
#
# Usage:
#   ple-native-adopt.sh adopt            # /models -> /models-ple-ab
#   ple-native-adopt.sh rollback         # /models-ple-ab -> /models
#
# Safety:
# - refuses to edit the unit unless SERVE_MODEL is exactly the expected
#   source value for that direction (no double edits, no surprise paths);
# - keeps a copy of the pre-edit unit file beside the evidence log as
#   gufo-prod.service.<direction>.before (and refuses to continue if the
#   edit does not take effect, restoring the copy);
# - polls /ready with the phase-3 responder discipline (systemctl active
#   AND the answering serve process must live in the gufo-prod.service
#   cgroup) so a leftover pair can never count as a healthy restore;
# - verifies BOTH ranks serve the target pack: rank 0 by cmdline + cgroup
#   locally, rank 1 on HOST_B by a stdin-transported probe whose pgrep
#   pattern is self-excluding (a plain literal self-matches the ssh
#   carrier — phase-4 lesson) and whose candidates must carry the
#   expected --model AND '--tp-rank 1', exactly one such process;
# - waits for the guardian's own canary ACCEPTANCE line (a fresh
#   "cycle N: accepted" after the restart) — not merely /ready;
# - gates on the live sanity request: a transport/parse failure fails the
#   whole run (rc=1, RESULT INCOMPLETE — never COMPLETE/0);
# - AUTO-ROLLBACK SCOPE (adopt direction only, AUTO_RB=0 disables; not
#   recommended unattended): engages on NEVER-READY, failed rank
#   verification, or guardian non-acceptance — the failure modes that
#   mean production is down, mis-served or unaccepted. It does NOT engage
#   on a failed post-acceptance sanity request: readiness, rank identity
#   and the canary acceptance have all passed by then, so that failure is
#   an investigation signal, not a proven bad switch; the run still
#   exits 1 with RESULT INCOMPLETE.
#
# Env: PROD_PORT (15003), GUARDIAN_LOG, TIMEOUT_READY (120 polls x 3 s),
# TIMEOUT_ACCEPT (100 polls x 3 s), AUTO_RB (1).
set -u

UNIT=/etc/systemd/system/gufo-prod.service
PROD_MODEL=/models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
CAND_MODEL=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
PROD_PORT="${PROD_PORT:-15003}"
GUARDIAN_LOG="${GUARDIAN_LOG:-/root/strix-dual-exp/evidence/serve-guardian.log}"
TIMEOUT_READY="${TIMEOUT_READY:-120}"
TIMEOUT_ACCEPT="${TIMEOUT_ACCEPT:-100}"
AUTO_RB="${AUTO_RB:-1}"
HOST_B="${HOST_B:-strix2}"
# Self-excluding serve pattern: matches the real "<bin> serve llm" cmdline
# but never the argv of a shell carrying the pattern as a literal. A plain
# literal ('gufo serve llm') self-matches the remote bash -c carrier that
# transports it, so a remote `pgrep -f '<literal>'` can never reach 0/1
# candidates on merit (observed live 2026-10-18 in the phase-4 pair driver
# and in this script's first revision — see notes/ple-native/04-perf-ab.md
# §6 and 05-final.md fix round 1). 'gufo[^ ]* serve llm' cannot match its
# own bracketed literal: the literal's bracket run contains a space, which
# the [^ ]* matcher cannot bridge. Locally, prod_serve_pid additionally
# filters by the gufo-prod.service cgroup; remotely, verify_serving_model
# ships the pattern on stdin (no remote argv carries it at all) and
# filters every candidate by cmdline identity.
SERVE_PAT='gufo[^ ]* serve llm'

EV="${PLE_ADOPT_EV:-/tmp/opencode/ple-native-adopt}"
mkdir -p "$EV"

stamp() { date '+%F %T%z'; }
log() { echo "[$(stamp)] $*"; }

current_serve_model() {
  grep '^Environment=SERVE_MODEL=' "$UNIT" | head -1 | cut -d= -f3
}

assert_model_on_both_hosts() {
  local m="$1" h
  for h in "$(hostname)" "$HOST_B"; do
    if [ "$h" = "$(hostname)" ]; then
      [ -f "$m" ] || { log "ERROR $m missing on $h"; return 1; }
      log "model file present on $h: $m ($(stat -c '%s bytes' "$m"))"
    else
      local sz
      sz=$(ssh "root@$h" "stat -c '%s' '$m'" 2>/dev/null) || { log "ERROR cannot stat $m on $h"; return 1; }
      log "model file present on $h: $m ($sz bytes)"
    fi
  done
}

# The serve process answering for the gufo-prod unit, if any (phase-3
# discipline: the process must live in the gufo-prod.service cgroup).
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

wait_ready() {
  local t code body
  for t in $(seq 1 "$TIMEOUT_READY"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PROD_PORT/ready" || true)
    body=$(curl -s -m 3 "http://127.0.0.1:$PROD_PORT/ready" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      if systemctl is-active --quiet gufo-prod && prod_serve_pid >/dev/null; then
        log "ready poll $t: /ready http_code=200 body='$body' responder=gufo-prod (unit + cgroup verified)"
        return 0
      fi
      log "ERROR ready poll $t: port answers 200 but NOT from the gufo-prod unit"
      return 1
    fi
    log "ready poll $t: /ready http_code=$code body='$body'"
    sleep 3
  done
  log "READY FAILED: /ready never 200"
  return 1
}

# Wait for a guardian acceptance line strictly newer than line count $1.
wait_accept() {
  local base_lines="$1" t newacc
  for t in $(seq 1 "$TIMEOUT_ACCEPT"); do
    newacc=$(tail -n +"$((base_lines + 1))" "$GUARDIAN_LOG" 2>/dev/null | grep 'cycle [0-9]*: accepted' | tail -1)
    if [ -n "$newacc" ]; then
      log "guardian acceptance after restart:"
      tail -n +"$((base_lines + 1))" "$GUARDIAN_LOG" | grep -E 'canary\[|cycle [0-9]+:' | sed 's/^/  | /'
      log "ACCEPTED: $newacc"
      return 0
    fi
    sleep 3
  done
  log "ACCEPT FAILED: no guardian 'cycle N: accepted' line within $((TIMEOUT_ACCEPT * 3)) s of the restart"
  tail -n +"$((base_lines + 1))" "$GUARDIAN_LOG" 2>/dev/null | tail -8 | sed 's/^/  | /'
  return 1
}

sanity_request() {
  log "SANITY one live chat completion through the prod port ($PROD_PORT)"
  local body out
  body='{"model":"Qwen3.8-Flash-Next","messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}],"max_tokens":256,"temperature":0}'
  out=$(curl -s -m 120 -H 'Content-Type: application/json' -d "$body" \
        "http://127.0.0.1:$PROD_PORT/v1/chat/completions")
  echo "$out" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception as e:
    print("SANITY PARSE ERROR:", e); sys.exit(1)
c = o.get("choices", [{}])[0].get("message", {})
u = o.get("usage", {})
print("  content         :", repr(c.get("content")))
print("  reasoning_content:", repr(c.get("reasoning_content"))[:200])
print("  usage           :", {k: u.get(k) for k in ("prompt_tokens","completion_tokens","total_tokens")})
g = u.get("gufo", {})
print("  gufo            :", {k: g.get(k) for k in ("draft_acceptance","prefill_ms") if k in g})
' || { log "ERROR sanity request failed"; return 1; }
  log "SANITY done"
}

verify_serving_model() {
  local want="$1" pid cmd
  pid=$(prod_serve_pid | head -1)
  [ -n "$pid" ] || { log "ERROR no gufo-prod serve process found"; return 1; }
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  case "$cmd" in
    *"--model $want"*) log "rank0 (pid $pid, gufo-prod.service cgroup) serves --model $want" ;;
    *) log "ERROR rank0 (pid $pid) does not serve $want; cmdline: $cmd"; return 1 ;;
  esac

  # Rank 1 runs on HOST_B inside an ssh session scope (the guardian
  # launches it over ssh), so the gufo-prod.service cgroup discipline of
  # prod_serve_pid cannot apply remotely. Never `pgrep | head -1`: the
  # ssh carrier self-matches a plain-literal pattern (see SERVE_PAT's
  # comment), and an unfiltered first hit is not identity. The probe
  # script travels on STDIN — no remote process carries the pattern in
  # argv — and it accepts a candidate only if its full cmdline carries
  # BOTH the expected --model AND the rank-1 role ('--tp-rank 1').
  # Exactly one match is required: zero (rank 1 absent/mismatched) or
  # many (e.g. a leftover A/B-pair rank 1, which matches the same
  # pattern) is a loud error, never a silently accepted guess.
  local probe out n line
  probe=$(cat <<'EOS'
pat='gufo[^ ]* serve llm'
want="$1"
n=0
for p in $(pgrep -f "$pat" 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
  case "$c" in
    *"--model $want"*"--tp-rank 1"*) echo "MATCH pid=$p"; n=$((n + 1)) ;;
    *) echo "CAND pid=$p :: $c" ;;
  esac
done
echo "COUNT=$n"
EOS
)
  out=$(printf '%s\n' "$probe" | ssh "root@$HOST_B" "bash -s" -- "$want" 2>/dev/null)
  n=$(printf '%s\n' "$out" | sed -n 's/^COUNT=//p' | tail -1)
  printf '%s\n' "$out" | grep '^CAND ' | sed 's/^/  (unmatched candidate) /' || true
  if [ "${n:-0}" -eq 1 ] && [ -n "$(printf '%s\n' "$out" | grep '^MATCH ')" ]; then
    for line in $(printf '%s\n' "$out" | grep '^MATCH ' | cut -d' ' -f2); do
      log "rank1 on $HOST_B: $line serves --model $want (cmdline carries --tp-rank 1)"
    done
    return 0
  fi
  log "ERROR rank1 on $HOST_B: expected exactly 1 serve with --model $want and --tp-rank 1, found ${n:-0}"
  printf '%s\n' "$out" | sed 's/^/  | /'
  return 1
}

switch() { # $1 = direction (adopt|rollback)
  local direction="$1" from to before
  if [ "$direction" = "adopt" ]; then
    from="$PROD_MODEL"; to="$CAND_MODEL"
  else
    from="$CAND_MODEL"; to="$PROD_MODEL"
  fi

  log "SWITCH direction=$direction"
  log "unit: $UNIT"
  log "from SERVE_MODEL: $(current_serve_model)"
  log "to   SERVE_MODEL: $to"

  local cur
  cur=$(current_serve_model)
  if [ "$cur" != "$from" ]; then
    log "REFUSE: unit SERVE_MODEL is '$cur', expected exactly '$from' for $direction"
    exit 1
  fi
  assert_model_on_both_hosts "$to" || exit 1

  before="$EV/gufo-prod.service.$direction.before"
  cp -a "$UNIT" "$before"
  log "unit snapshot before edit: $before (sha256 $(sha256sum "$before" | cut -c1-16)…) "

  local base_lines
  base_lines=$(wc -l < "$GUARDIAN_LOG")

  sed -i "s|^Environment=SERVE_MODEL=$from\$|Environment=SERVE_MODEL=$to|" "$UNIT"
  if [ "$(current_serve_model)" != "$to" ]; then
    log "ERROR edit did not take effect; restoring snapshot"
    cp -a "$before" "$UNIT"
    systemctl daemon-reload
    exit 1
  fi
  log "unit edited; SERVE_MODEL=$to"
  systemctl daemon-reload
  log "daemon-reload done"

  log "RESTART gufo-prod (stop tears down both TP2 ranks; start launches a fresh guardian cycle on $to)"
  systemctl restart gufo-prod

  if ! wait_ready; then
    log "ADOPT/ROLLBACK PATH FAILED at /ready"
    [ "$direction" = "adopt" ] && [ "$AUTO_RB" = "1" ] && { log "AUTO-ROLLBACK engaged"; rollback; exit 1; }
    exit 1
  fi
  if ! verify_serving_model "$to"; then
    log "FAILED: serving model verification"
    [ "$direction" = "adopt" ] && [ "$AUTO_RB" = "1" ] && { log "AUTO-ROLLBACK engaged"; rollback; exit 1; }
    exit 1
  fi
  if ! wait_accept "$base_lines"; then
    log "FAILED: guardian never accepted a canary cycle"
    [ "$direction" = "adopt" ] && [ "$AUTO_RB" = "1" ] && { log "AUTO-ROLLBACK engaged"; rollback; exit 1; }
    exit 1
  fi
  if ! sanity_request; then
    # Deliberately NOT auto-rollback: by this point /ready answered 200
    # from the cgroup-verified gufo-prod unit, both ranks were confirmed
    # on the target pack, and the guardian ACCEPTED a full uncached
    # canary cycle at the production gate — three independent live
    # checks. A failed sanity is most plausibly a client-side failure
    # (timeout under load, transient connection) and is an investigation
    # signal, not proof of a bad switch; auto-rollback here would add a
    # needless ~30 s outage + canary cycle on weak evidence. The run
    # still FAILS (rc=1) and is reported INCOMPLETE so no automation can
    # read it as success. (Header documents this scope.)
    log "FAILED: sanity request after $direction (production is up and guardian-accepted on $to; investigate before relying on it)"
    log "RESULT: $direction INCOMPLETE — readiness, rank identity and the guardian canary all verified, but the live sanity request FAILED; not reported COMPLETE, no auto-rollback"
    log "ROLLBACK (if ever needed): $0 rollback  # SERVE_MODEL back to $from + restart"
    return 1
  fi
  log "RESULT: $direction COMPLETE — production serves $to, guardian-accepted, sanity answered"
  log "ROLLBACK (if ever needed): $0 rollback  # SERVE_MODEL back to $from + restart"
}

adopt() { switch adopt; }
rollback() { switch rollback; }

rc=0
case "${1:-}" in
  adopt) adopt; rc=$? ;;
  rollback) rollback; rc=$? ;;
  *) echo "usage: $0 adopt|rollback" >&2; exit 2 ;;
esac
exit "$rc"
