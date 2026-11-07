#!/usr/bin/env bash
# PLE-native BF16 A/B — candidate pack assembly on one host.
#
# Builds /models-ple-ab/ as a sibling of /models (same filesystem, so the
# unchanged shards are HARDLINKS, not copies: zero extra disk, and any accidental
# write through them would be visible in the original's link count). Shard 3 is
# deliberately NOT linked: it is rebuilt by ple-native-splice.py as a new file
# carrying the native BF16 PLE table. /models is never written.
#
# Usage:
#   ple-native-pack.sh prep                 # hardlink unchanged shards + sidecars
#   ple-native-pack.sh verify-links         # inode identity + link counts + sizes
#   ple-native-pack.sh manifest [OUT]       # sha256 of every pack file (for cross-host compare)
#   ple-native-pack.sh models-untouched    # prove /models mtimes/link counts unchanged
set -u
PACK=/models-ple-ab
SRC=/models
BASE=Qwen3.8-Flash-Next-UD-Q5_K_XL
SHARDS="1 2 4 5 6"
SIDE_CARS="mmproj-BF16.gguf mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"

prep() {
  mkdir -p "$PACK"
  for n in $SHARDS; do
    src="$SRC/$BASE-0000$n-of-00006.gguf"
    dst="$PACK/$BASE-0000$n-of-00006.gguf"
    [ -e "$dst" ] && { echo "SKIP exists: $dst"; continue; }
    ln "$src" "$dst" || { echo "FAIL ln $src"; exit 1; }
  done
  for s in $SIDE_CARS; do
    [ -e "$PACK/$s" ] && { echo "SKIP exists: $PACK/$s"; continue; }
    ln "$SRC/$s" "$PACK/$s" || { echo "FAIL ln $s"; exit 1; }
  done
  echo "prep done"
}

verify_links() {
  rc=0
  for n in $SHARDS; do
    f="$BASE-0000$n-of-00006.gguf"
    a=$(stat -c '%i %h %s' "$SRC/$f"); b=$(stat -c '%i %h %s' "$PACK/$f")
    if [ "$a" != "$b" ]; then echo "MISMATCH $f: src=[$a] pack=[$b]"; rc=1;
    else echo "OK $f inode=$(echo $a | cut -d' ' -f1) nlink=$(echo $a | cut -d' ' -f2) size=$(echo $a | cut -d' ' -f3)"; fi
  done
  for s in $SIDE_CARS; do
    a=$(stat -c '%i %h %s' "$SRC/$s"); b=$(stat -c '%i %h %s' "$PACK/$s")
    if [ "$a" != "$b" ]; then echo "MISMATCH $s: src=[$a] pack=[$b]"; rc=1;
    else echo "OK $s inode=$(echo $a | cut -d' ' -f1) nlink=$(echo $a | cut -d' ' -f2) size=$(echo $a | cut -d' ' -f3)"; fi
  done
  # shard 3 must NOT be a hardlink to the original
  if [ -e "$PACK/$BASE-00003-of-00006.gguf" ]; then
    i3=$(stat -c '%i' "$PACK/$BASE-00003-of-00006.gguf")
    j3=$(stat -c '%i' "$SRC/$BASE-00003-of-00006.gguf")
    if [ "$i3" = "$j3" ]; then echo "ERROR shard3 is the ORIGINAL inode"; rc=1;
    else echo "OK shard3 distinct inode $i3 (original $j3)"; fi
  else
    echo "note: shard3 not built yet"
  fi
  echo "pack listing:"; ls -la "$PACK"
  exit $rc
}

manifest() {
  out="${1:-/dev/stdout}"
  ( cd "$PACK" && sha256sum -- * ) > "$out"
  echo "manifest written: $out"
  wc -l "$out"
}

models_untouched() {
  echo "== /models entries (mtime, nlink, size, name):"
  ( cd "$SRC" && stat -c '%y %h %s %n' -- * )
  echo "== entries under /models newer than pack creation (expect none):"
  find "$SRC" -newermt "$(stat -c %y "$PACK")" -printf '%TY-%Tm-%Td %TT %p\n' || true
}

case "${1:-}" in
  prep) prep ;;
  verify-links) verify_links ;;
  manifest) shift; manifest "$@" ;;
  models-untouched) models_untouched ;;
  *) echo "usage: $0 prep|verify-links|manifest [OUT]|models-untouched" >&2; exit 2 ;;
esac
