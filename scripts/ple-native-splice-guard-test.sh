#!/usr/bin/env bash
# Guard verification for ple-native-splice.py (phase-2 fix round).
#
# Reproduces the reviewer's destructive-demo scenario against DISPOSABLE copies
# in /tmp/opencode (never /models), with the source fixture and the outputs in
# SEPARATE directories so each guard fires in isolation:
#   T1 --out == --shard3                      -> REFUSED (same file), input intact
#   T2 --out inside --shard3's directory      -> REFUSED, nothing created
#   T3 pre-existing wrong-size --out, no force -> REFUSED (was: os.unlink), file untouched
#   T4 T3 + --force with an empty staging      -> aborts later at chunk mapping;
#        crucially the pre-existing --out still exists with its original inode
#        (replacement only ever happens via tmp + os.replace AFTER a full write)
#   T5 the real candidate run (verify-only)    -> full battery, RESULT: PASS
set -u
EV=/root/strix-dual-exp/evidence/ple-native
S=notes/ple-native/scripts/ple-native-splice.py
WORK=/tmp/opencode/ple-guard-test
rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/out" "$WORK/fake-staging"
rc_all=0

check() { if [ "$2" = "$3" ]; then echo "PASS $1 (rc=$3, $4)"; else echo "FAIL $1 (rc=$3 want $2, $4)"; rc_all=1; fi; }

python3 - "$WORK/src" <<'EOF'
import os, struct, sys
w = sys.argv[1]
hdr = bytearray(192)
struct.pack_into("<4s", hdr, 0, b"GGUF")
struct.pack_into("<I", hdr, 4, 3)                    # version
struct.pack_into("<Q", hdr, 8, 1)                    # n_tensors
struct.pack_into("<Q", hdr, 16, 3)                   # n_kv
pos = 24
for key, tag, val in [(b"split.no", 2, 2), (b"split.tensors.count", 4, 5), (b"split.count", 2, 2)]:
    struct.pack_into("<Q", hdr, pos, len(key)); pos += 8
    hdr[pos:pos+len(key)] = key; pos += len(key)
    struct.pack_into("<I", hdr, pos, tag); pos += 4
    struct.pack_into("<" + {2: "H", 4: "I"}[tag], hdr, pos, val); pos += {2: 2, 4: 4}[tag]
assert pos == 106, pos
name = b"per_layer_token_embd.weight"
struct.pack_into("<Q", hdr, pos, len(name)); pos += 8
hdr[pos:pos+len(name)] = name; pos += len(name)
struct.pack_into("<I", hdr, pos, 2); pos += 4
struct.pack_into("<Q", hdr, pos, 160); pos += 8
struct.pack_into("<Q", hdr, pos, 320001536); pos += 8
assert pos == 161, pos
struct.pack_into("<I", hdr, pos, 20); pos += 4        # IQ4_NL
struct.pack_into("<Q", hdr, pos, 0); pos += 8
assert pos == 173, pos
f = open(os.path.join(w, "orig-shard3.gguf"), "wb")
f.write(hdr)
f.truncate(192 + 28800138240)                          # sparse payload
f.close()
print("fixture: shard-3-shaped GGUF, real 192-byte header (type 20 at 161), sparse payload")
EOF
ORIG=$WORK/src/orig-shard3.gguf
ORIG_ID=$(stat -c '%i %s' "$ORIG")
STAGE=/root/staging-ple-native

echo "== T1: --out aliases --shard3 (the reviewer's destructive case)"
python3 "$S" --staging $STAGE --shard3 "$ORIG" --out "$ORIG" > "$WORK/t1.log" 2>&1
rc=$?; cat "$WORK/t1.log"; check T1 1 "$rc" "refused before any write"
[ "$(stat -c '%i %s' "$ORIG")" = "$ORIG_ID" ] && echo "PASS T1 input intact" || { echo "FAIL T1 input damaged"; rc_all=1; }

echo; echo "== T2: --out inside the directory of --shard3"
python3 "$S" --staging $STAGE --shard3 "$ORIG" --out "$WORK/src/other.gguf" > "$WORK/t2.log" 2>&1
rc=$?; cat "$WORK/t2.log"; check T2 1 "$rc" "refused, nothing created"
[ ! -e "$WORK/src/other.gguf" ] && echo "PASS T2 no output created" || { echo "FAIL T2 output created"; rc_all=1; }

echo; echo "== T3: pre-existing wrong-size --out in a DIFFERENT dir, no --force (the old code unlinked it)"
head -c 4096 /dev/urandom > "$WORK/out/wrong.gguf"
BEFORE=$(stat -c '%i %s' "$WORK/out/wrong.gguf")
python3 "$S" --staging $STAGE --shard3 "$ORIG" --out "$WORK/out/wrong.gguf" > "$WORK/t3.log" 2>&1
rc=$?; cat "$WORK/t3.log"; check T3 1 "$rc" "refused instead of unlinking"
[ "$(stat -c '%i %s' "$WORK/out/wrong.gguf")" = "$BEFORE" ] && echo "PASS T3 pre-existing file untouched" \
  || { echo "FAIL T3 pre-existing file damaged"; rc_all=1; }
[ "$(stat -c '%i %s' "$ORIG")" = "$ORIG_ID" ] && echo "PASS T3 input intact" || { echo "FAIL T3 input damaged"; rc_all=1; }

echo; echo "== T4: T3 with --force (empty staging -> aborts at chunk mapping; no unlink may precede it)"
python3 "$S" --staging "$WORK/fake-staging" --shard3 "$ORIG" --out "$WORK/out/wrong.gguf" --force > "$WORK/t4.log" 2>&1
rc=$?; tail -2 "$WORK/t4.log"; check T4 1 "$rc" "aborted at missing-chunks after --force"
[ "$(stat -c '%i %s' "$WORK/out/wrong.gguf")" = "$BEFORE" ] \
  && echo "PASS T4 pre-existing --out still present, same inode (no unlink-before-write)" \
  || { echo "FAIL T4 pre-existing --out was deleted"; rc_all=1; }
[ "$(stat -c '%i %s' "$ORIG")" = "$ORIG_ID" ] && echo "PASS T4 input intact" || { echo "FAIL T4 input damaged"; rc_all=1; }

echo; echo "== T5: the real candidate run (idempotent verify-only path)"
python3 "$S" --staging $STAGE \
  --shard3 /models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00003-of-00006.gguf \
  --out /models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00003-of-00006.gguf > "$WORK/t5.log" 2>&1
rc=$?; tail -5 "$WORK/t5.log"; check T5 0 "$rc" "skip + full verification battery passes"
grep -q 'RESULT: PASS' "$WORK/t5.log" && echo "PASS T5 RESULT: PASS present" || { echo "FAIL T5"; rc_all=1; }

echo
if [ $rc_all = 0 ]; then echo "GUARD VERIFICATION: ALL PASS"; else echo "GUARD VERIFICATION: FAILURES PRESENT"; fi
mkdir -p "$EV"; cp "$WORK"/t*.log "$EV"/
rm -rf "$WORK"
exit $rc_all
