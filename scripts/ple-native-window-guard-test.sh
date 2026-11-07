#!/usr/bin/env bash
# Guard test for the phase-3 window drivers and pair driver
# (fix rounds 1 and 2).
#
# Fix round 1: teed failure checks masked real exit statuses (no pipefail).
# Fix round 2: failure paths left the A/B pair running, `trap - EXIT` disarmed
#   the only mechanism that could still stop it, cleanup() used the wrong stop
#   tag (scr-$SUFFIX vs scr-$SUFFIX-$arm), the pair served on gufo-prod's own
#   port 15003 so a leftover pair could answer restore's /ready poll with 200,
#   and start() never killed its half-launched ranks on NEVER-READY.
#
# Everything runs against STUB drivers in a sandbox under /tmp/opencode --
# production, /models, /dev/tbstream0 and the GPUs are never touched
# (systemctl, pgrep, curl, ssh, scp and pkill are shadowed by stubs on PATH,
# and the A/B port is a dead sandbox port so no live HTTP request is made).
#
# Window-driver cases (stub pair/screen drivers):
#  T1  start fails                -> exit 1, battery NOT run, stop+restore issued
#  T2  restore fails              -> exit 1 with unmasked ERROR
#  T3  happy path                 -> exit 0, battery ran, stop+restore issued
#  T4  park fails                 -> exit 1, battery NOT run, restore attempted
#  T5  window1 probe step fails   -> exit 1, window completes, restore attempted
#  T6  window2 kld step fails     -> exit 1, restore attempted
#  T7  start OK, screen client FAILS -> exit 1 AND a stop is issued for the
#      just-started pair before restore (fix-round-2 regression case)
#  T8  hermeticity: the metrics scrape goes to the sandbox pair port only
#      (no live production /metrics content in any artifact)
#  C1  control: pre-fix (970445f) window3 masks a failed start -> exit 0
#  C2  control: fix-round-1 (33dcbfd) window3 with start OK / screen failing
#      -> NO stop issued before restore (the round-2 hole, reproduced)
#
# Pair-driver cases (sed'd copy with stubbed systemctl/pgrep/curl/ssh):
#  T9  restore: 200 answered by a NON-production serve -> restore FAILS loudly
#  T10 restore: 200 answered by the gufo-prod unit      -> restore succeeds
#  T11 start NEVER-READY: half-launched local rank is killed, remote kill sent
#  T12 park: port still answered by a non-production serve -> park FAILS
set -u
SRC=/root/strix-dual-exp/scripts
REPO=${1:-/root/goal-worktrees/2026-10-17-ple-native-bf16}
T=/tmp/opencode/ple-p3-guard
rm -rf "$T"
mkdir -p "$T/ev" "$T/fix" "$T/dumps" "$T/bin" "$T/fakecgroup" "$T/pairstate" "$T/pairlogs"
PASS=0; FAIL=0

say() { echo "[guard] $*"; }
ok()  { echo "[guard] PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "[guard] FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------- stubs ----
cat > "$T/pair-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Stub ple-native-pair.sh: rc per subcommand from $T/rc/<cmd>; calls logged.
set -u
T=/tmp/opencode/ple-p3-guard
echo "$1" >> "$T/pair-calls.log"
rc=0
[ -f "$T/rc/$1" ] && rc=$(cat "$T/rc/$1")
echo "[$1] stub rc=$rc"
exit "$rc"
EOF
cat > "$T/probe-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Stub ple-native-probe.sh: fails when $T/rc/probe-<tag> exists.
set -u
T=/tmp/opencode/ple-p3-guard
tag="${2:-sha}"
echo "probe $*" >> "$T/probe-calls.log"
rc=0
[ -f "$T/rc/probe-$tag" ] && rc=$(cat "$T/rc/probe-$tag")
echo "[probe] stub tag=$tag rc=$rc"
exit "$rc"
EOF
cat > "$T/screen-stub.py" <<'EOF'
import os, sys
open('/tmp/opencode/ple-p3-guard/screen-calls.log', 'a').write(' '.join(sys.argv) + '\n')
print('screen stub ran')
raise SystemExit(int(open('/tmp/opencode/ple-p3-guard/rc/screen').read())
                 if os.path.exists('/tmp/opencode/ple-p3-guard/rc/screen') else 0)
EOF
# systemctl stub: active/inactive and rc controlled by marker files.
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
T=/tmp/opencode/ple-p3-guard
echo "systemctl $*" >> "$T/systemctl-calls.log"
case "$1" in
  is-active)
    [ $# -ge 3 ] && [ "$2" = "--quiet" ] && shift
    if [ -f "$T/rc/systemctl-active" ]; then echo active; exit 0; fi
    echo inactive; exit 3 ;;
  start|stop) exit 0 ;;
  *) exit 0 ;;
esac
EOF
# pgrep stub: the production-serve pattern reports the fake pid only when the
# marker exists; anything else (our fake pair binary) reports nothing. Like
# real pgrep, exit 1 when nothing matched.
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
T=/tmp/opencode/ple-p3-guard
for a in "$@"; do
  case "$a" in
    *'gufo[^ ]* serve llm'*)
      if [ -f "$T/rc/prod-serve-present" ]; then echo 4242; exit 0; fi
      exit 1 ;;
  esac
done
exit 1
EOF
# curl stub: ready polls answer from markers; every other URL is dead
# (connection refused, like a closed port).
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
T=/tmp/opencode/ple-p3-guard
url="${@: -1}"
case "$url" in
  */ready) ;;
  *) exit 7 ;;
esac
w=false
for a in "$@"; do
  [ "$a" = "-w" ] && w=true
done
if $w; then
  [ -f "$T/rc/ready-code" ] && cat "$T/rc/ready-code" || echo 000
  exit 0
fi
if [ -f "$T/rc/ready-code" ] && [ "$(cat "$T/rc/ready-code")" = "200" ]; then
  echo '{"status":"ready","model":"Qwen3.8-Flash-Next"}'
fi
exit 0
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
T=/tmp/opencode/ple-p3-guard
echo "ssh: $*" >> "$T/ssh-calls.log"
case "$*" in
  *"echo \$!"*) echo 5555 ;;
  *"pgrep -f"*) echo 0 ;;
  *) : ;;
esac
exit 0
EOF
cat > "$T/bin/scp" <<'EOF'
#!/usr/bin/env bash
echo "scp: $*" >> /tmp/opencode/ple-p3-guard/ssh-calls.log
dest="${@: -1}"
: > "$dest" 2>/dev/null || true
exit 0
EOF
cat > "$T/bin/pkill" <<'EOF'
#!/usr/bin/env bash
echo "pkill: $*" >> /tmp/opencode/ple-p3-guard/pkill-calls.log
exit 0
EOF
printf '#!/bin/sh\nsleep 300\n' > "$T/fakebin"
chmod +x "$T/fakebin" "$T/pair-stub.sh" "$T/probe-stub.sh" "$T/screen-stub.py" \
  "$T/bin/systemctl" "$T/bin/pgrep" "$T/bin/curl" "$T/bin/ssh" "$T/bin/scp" \
  "$T/bin/pkill"
export PATH="$T/bin:$PATH"
# The A/B pair port is a dead sandbox port: any metrics/ready scrape the
# window makes hits nothing live.
export PAIR_PORT=15099
echo "sandbox pair port: $PAIR_PORT (must not be 15003)"

# ------------------------------------------------------------- helpers ----
prep() {  # prep WINDOW_SCRIPT -> sed'd copy in $T (sandbox paths + port)
  local src="$1" out="$2"
  sed -e "s#^PAIR=.*#PAIR=$T/pair-stub.sh#" \
      -e "s#^PROBE=.*#PROBE=$T/probe-stub.sh#" \
      -e "s#^SCREEN=.*#SCREEN=$T/screen-stub.py#" \
      -e "s#^EV=.*#EV=$T/ev#" \
      -e "s#^FIX=.*#FIX=$T/fix#" \
      -e "s#^DUMPS=.*#DUMPS=$T/dumps#" \
      -e "s#/tmp/opencode/char-prompt.txt#$T/fix/char-prompt.txt#" \
      "$src" > "$out"
  chmod +x "$out"
}
# Sandbox copy of the pair driver: fake binary, fake cgroup dir, sandbox
# state/logs, fast loops. systemctl/pgrep/curl/ssh/scp/pkill come from PATH.
prep_pair() {
  local out="$1"
  sed -e "s#^BIN=.*#BIN=$T/fakebin#" \
      -e "s#^BIN_SHA=.*#BIN_SHA=$(sha256sum "$T/fakebin" | cut -d' ' -f1)#" \
      -e "s#^EV=.*#EV=$T/pairlogs#" \
      -e "s#^STATE=.*#STATE=$T/pairstate#" \
      -e "s#/proc/\$p/cgroup#$T/fakecgroup/\$p#" \
      -e "s#\[ -c /dev/tbstream0 \]#[ -x \"$T/fakebin\" ]#" \
      -e "s#/sys/kernel/config/thunderbolt/stream/\*/gufo#\"$T\"/no-streams/*/gufo#" \
      -e "s#seq 1 90#seq 1 1#" \
      -e "s#seq 1 120#seq 1 1#" \
      -e "s#seq 1 30#seq 1 2#" \
      -e "s#seq 1 20#seq 1 2#" \
      -e "s#seq 1 15#seq 1 2#" \
      -e "s#sleep 3#sleep 0.2#g" \
      -e "s#sleep 2#sleep 0.1#g" \
      "$SRC/ple-native-pair.sh" > "$out"
  chmod +x "$out"
}
reset_state() {
  rm -f "$T"/pair-calls.log "$T"/probe-calls.log "$T"/screen-calls.log \
        "$T"/ssh-calls.log "$T"/systemctl-calls.log "$T"/pkill-calls.log
  rm -rf "$T/rc"; mkdir -p "$T/rc"
  rm -f "$T"/ev/03-window-*.log "$T"/ev/03-window-*-park-restore.log \
        "$T"/ev/03-metrics-* "$T"/pairlogs/* "$T"/pairstate/*
  rm -f "$T/fakecgroup"/*
}
restore_count() { [ -f "$T/pair-calls.log" ] && grep -c '^restore$' "$T/pair-calls.log" || echo 0; }
stop_count() { [ -f "$T/pair-calls.log" ] && grep -c '^stop$' "$T/pair-calls.log" || echo 0; }
screen_ran() { [ -f "$T/screen-calls.log" ]; }
restore_failed_line() { grep -l "restore FAILED" "$T"/ev/03-window-*-park-restore.log 2>/dev/null | head -1; }

prep "$SRC/ple_native_window3.sh" "$T/w3.sh"
prep "$SRC/ple_native_window1.sh" "$T/w1.sh"
prep "$SRC/ple_native_window2.sh" "$T/w2.sh"
prep_pair "$T/pair-sandbox.sh"

# ------------------------------------------------------------------ T1 ----
reset_state
echo 1 > "$T/rc/start"
out=$(bash "$T/w3.sh" IQ4 BF16 9 t1 2>&1); rc=$?
echo "$out" > "$T/out-t1.txt"
if [ "$rc" -eq 1 ] && ! screen_ran && [ "$(restore_count)" -ge 1 ] \
   && echo "$out" | grep -q "pair start FAILED"; then
  ok "T1 window3 start failure: exit 1, battery not run, stop+restore issued, loud ERROR"
else
  bad "T1: rc=$rc screen_ran=$(screen_ran && echo yes || echo no) restores=$(restore_count)"
fi

# ------------------------------------------------------------------ T2 ----
reset_state
echo 1 > "$T/rc/restore"
out=$(bash "$T/w3.sh" IQ4 BF16 9 t2 2>&1); rc=$?
echo "$out" > "$T/out-t2.txt"
if [ "$rc" -eq 1 ] && screen_ran && [ -n "$(restore_failed_line)" ] \
   && echo "$out" | grep -q "restore FAILED"; then
  ok "T2 window3 restore failure: exit 1 with unmasked ERROR"
else
  bad "T2: rc=$rc screen_ran=$(screen_ran && echo yes || echo no) errline='$(restore_failed_line)'"
fi

# ------------------------------------------------------------------ T3 ----
reset_state
out=$(bash "$T/w3.sh" IQ4 BF16 9 t3 2>&1); rc=$?
echo "$out" > "$T/out-t3.txt"
if [ "$rc" -eq 0 ] && screen_ran && [ "$(restore_count)" -ge 1 ] \
   && [ "$(stop_count)" -ge 2 ] && ! echo "$out" | grep -q "ERROR"; then
  ok "T3 window3 happy path: exit 0, battery ran, pair stopped (per-arm + trap), restore issued"
else
  bad "T3: rc=$rc restores=$(restore_count) stops=$(stop_count)"
fi

# ------------------------------------------------------------------ T4 ----
reset_state
echo 1 > "$T/rc/park"
out=$(bash "$T/w3.sh" IQ4 BF16 9 t4 2>&1); rc=$?
echo "$out" > "$T/out-t4.txt"
if [ "$rc" -eq 1 ] && ! screen_ran && [ "$(restore_count)" -ge 1 ] \
   && echo "$out" | grep -q "park failed"; then
  ok "T4 window3 park failure: exit 1, battery not run, restore still attempted"
else
  bad "T4: rc=$rc screen_ran=$(screen_ran && echo yes || echo no) restores=$(restore_count)"
fi

# ------------------------------------------------------------------ T5 ----
reset_state
echo "phase3 fixture sandbox" > "$T/fix/char-prompt.txt"
echo 1 > "$T/rc/probe-w1-BF16-text1"
out=$(bash "$T/w1.sh" 2>&1); rc=$?
echo "$out" > "$T/out-t5.txt"
probe_calls=$( [ -f "$T/probe-calls.log" ] && wc -l < "$T/probe-calls.log" || echo 0 )
if [ "$rc" -eq 1 ] && [ "$probe_calls" -ge 8 ] && [ "$(restore_count)" -ge 1 ] \
   && echo "$out" | grep -q "rc=1 in step"; then
  ok "T5 window1 probe failure: window completes (8+ probe steps), exit 1, restore attempted"
else
  bad "T5: rc=$rc probe_calls=$probe_calls restores=$(restore_count)"
fi

# ------------------------------------------------------------------ T6 ----
reset_state
echo 1 > "$T/rc/probe-w2-iq4-kld"
out=$(bash "$T/w2.sh" 2>&1); rc=$?
echo "$out" > "$T/out-t6.txt"
if [ "$rc" -eq 1 ] && [ "$(restore_count)" -ge 1 ] && echo "$out" | grep -q "rc=1 in step"; then
  ok "T6 window2 kld failure: exit 1, restore attempted"
else
  bad "T6: rc=$rc restores=$(restore_count)"
fi

# ------------------------------------------------------------------ T7 ----
# Fix-round-2 regression: start succeeds, the screen client crashes -> the
# just-started pair MUST be stopped before restore (not left answering 15003).
reset_state
echo 1 > "$T/rc/screen"
out=$(bash "$T/w3.sh" IQ4 BF16 9 t7 2>&1); rc=$?
echo "$out" > "$T/out-t7.txt"
stops_before_restore=$(if [ -f "$T/pair-calls.log" ]; then
  awk '/^restore$/{exit} /^stop$/{n++} END{print n+0}' "$T/pair-calls.log"; else echo 0; fi)
if [ "$rc" -eq 1 ] && screen_ran && [ "$stops_before_restore" -ge 1 ] \
   && echo "$out" | grep -q "screen client FAILED"; then
  ok "T7 start-OK/screen-fails: exit 1, pair stopped BEFORE restore ($stops_before_restore stop call(s)), loud ERROR"
else
  bad "T7: rc=$rc screen_ran=$(screen_ran && echo yes || echo no) stops_before_restore=$stops_before_restore"
fi

# ------------------------------------------------------------------ T8 ----
# Hermeticity: the metrics scrape must target the sandbox pair port only, so
# no live production /metrics content can land in the artifacts (asserted on
# the happy path, where the scrape actually runs).
if [ ! -s "$T/ev/03-metrics-IQ4-t3.txt" ] 2>/dev/null \
   && grep -q "metrics scrape failed on $PAIR_PORT" "$T/out-t3.txt"; then
  ok "T8 hermeticity: metrics scrape hit only the dead sandbox port $PAIR_PORT (no live production content)"
else
  bad "T8: metrics artifact non-empty or no sandbox-port warn line in T3"
fi

# ------------------------------------------------------------------ C1 ----
reset_state
echo 1 > "$T/rc/start"
mkdir -p "$T/old"
git -C "$REPO" show 970445f:notes/ple-native/scripts/ple_native_window3.sh \
  | sed -e "s#^PAIR=.*#PAIR=$T/pair-stub.sh#" \
        -e "s#^SCREEN=.*#SCREEN=$T/screen-stub.py#" \
        -e "s#^EV=.*#EV=$T/ev#" > "$T/old/w3-old.sh"
out=$(bash "$T/old/w3-old.sh" IQ4 BF16 9 c1 2>&1); rc=$?
echo "$out" > "$T/out-c1.txt"
if [ "$rc" -eq 0 ]; then
  ok "C1 control: pre-fix script masks a failed start (exit 0) -- reproduced"
else
  bad "C1: pre-fix script unexpectedly returned $rc"
fi

# ------------------------------------------------------------------ C2 ----
# Fix-round-1 script: start OK + screen failing left the pair running and
# disarmed the trap -> NO stop before restore (the round-2 hole).
reset_state
echo 1 > "$T/rc/screen"
git -C "$REPO" show 33dcbfd:notes/ple-native/scripts/ple_native_window3.sh \
  | sed -e "s#^PAIR=.*#PAIR=$T/pair-stub.sh#" \
        -e "s#^SCREEN=.*#SCREEN=$T/screen-stub.py#" \
        -e "s#^EV=.*#EV=$T/ev#" > "$T/old/w3-r1.sh"
out=$(bash "$T/old/w3-r1.sh" IQ4 BF16 9 c2 2>&1); rc=$?
echo "$out" > "$T/out-c2.txt"
stops_before_restore=$(awk '/^restore$/{exit} /^stop$/{n++} END{print n+0}' "$T/pair-calls.log")
if [ "$rc" -eq 1 ] && [ "$stops_before_restore" -eq 0 ]; then
  ok "C2 control: fix-round-1 script issues NO stop before restore (round-2 hole reproduced; fix is load-bearing)"
else
  bad "C2: rc=$rc stops_before_restore=$stops_before_restore (expected 0)"
fi

# ------------------------------------------------------------ pair T9 -----
# restore(): a 200 answered by a NON-production serve must FAIL, not pass.
reset_state
echo 200 > "$T/rc/ready-code"
touch "$T/rc/systemctl-active" "$T/rc/prod-serve-present"
echo "0::/user.slice/user-1000.slice/session-123.scope" > "$T/fakecgroup/4242"
out=$(bash "$T/pair-sandbox.sh" restore 2>&1); rc=$?
echo "$out" > "$T/out-t9.txt"
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "NOT from the gufo-prod unit"; then
  ok "T9 pair restore: leftover-pair 200 is REFUSED (unit+cgroup verified), exit $rc"
else
  bad "T9: rc=$rc out='$(echo "$out" | tail -2 | tr '\n' ' ')'"
fi

# ------------------------------------------------------------ pair T10 ----
# restore(): a 200 answered by the gufo-prod unit must succeed.
reset_state
echo 200 > "$T/rc/ready-code"
touch "$T/rc/systemctl-active" "$T/rc/prod-serve-present"
echo "0::/system.slice/gufo-prod.service" > "$T/fakecgroup/4242"
out=$(bash "$T/pair-sandbox.sh" restore 2>&1); rc=$?
echo "$out" > "$T/out-t10.txt"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "responder=gufo-prod"; then
  ok "T10 pair restore: genuine production 200 verified (unit + cgroup), exit 0"
else
  bad "T10: rc=$rc out='$(echo "$out" | tail -2 | tr '\n' ' ')'"
fi

# ------------------------------------------------------------ pair T11 ----
# start() NEVER-READY: the half-launched local rank must be killed and a
# remote kill sent, before returning failure.
reset_state
rm -f "$T/rc/prod-serve-present" "$T/rc/systemctl-active"
"$T/fakebin" serve-args-placeholder &
fakepid=$!
out=$(bash "$T/pair-sandbox.sh" start BF16 t11 2>&1); rc=$?
echo "$out" > "$T/out-t11.txt"
local_killed=0
rank0pid=$(cat "$T/pairstate/rank0-t11.pid" 2>/dev/null || echo "")
if [ -n "$rank0pid" ] && ! kill -0 "$rank0pid" 2>/dev/null; then local_killed=1; fi
remote_kill_sent=$(grep -cE "kill -TERM|pkill" "$T/ssh-calls.log" 2>/dev/null || echo 0)
kill -9 $fakepid 2>/dev/null || true
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "killed half-launched pair" \
   && [ "$local_killed" -eq 1 ] && [ "$remote_kill_sent" -ge 1 ]; then
  ok "T11 pair start NEVER-READY: exit $rc, half-launched pair killed (local rank gone, remote kill sent)"
else
  bad "T11: rc=$rc local_killed=$local_killed remote_kill_sent=$remote_kill_sent"
fi

# ------------------------------------------------------------ pair T12 ----
# park(): if the production port is still answered by a non-production serve,
# park must FAIL instead of reporting a clean park.
reset_state
echo 200 > "$T/rc/ready-code"
touch "$T/rc/prod-serve-present"
rm -f "$T/rc/systemctl-active"
echo "0::/user.slice/session-9.scope" > "$T/fakecgroup/4242"
out=$(bash "$T/pair-sandbox.sh" park 2>&1); rc=$?
echo "$out" > "$T/out-t12.txt"
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "NON-production serve"; then
  ok "T12 pair park: port still held by a non-production serve -> FAIL, exit $rc"
else
  bad "T12: rc=$rc out='$(echo "$out" | tail -2 | tr '\n' ' ')'"
fi

echo "[guard] ----"
echo "[guard] window/pair driver guard test: PASS=$PASS FAIL=$FAIL"
echo "[guard] transcripts in $T/out-*.txt"
[ "$FAIL" -eq 0 ]
