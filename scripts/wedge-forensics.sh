#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Phase-0 forensic capture — run ON A WEDGED HOST BEFORE REBOOTING.
# Captures the hardware-vs-driver discriminator (NHI PCI config space
# responsiveness) plus full driver/device state into a tarball.
set -u
TAG="${1:?usage: wedge-forensics.sh TAG}"
OUT="$(dirname "$0")/../evidence/forensics-$TAG-$(hostname)-$(date +%H%M%S)"
mkdir -p "$OUT"

{
  echo "== date =="; date
  echo "== uptime =="; uptime
  echo "== NHI PCI config-space responsiveness (KEY DISCRIMINATOR) =="
  echo "-- setpci vendor/product (instant = chip alive, hang/ff = chip dead) --"
  timeout -k 2 3 setpci -s 67:00.0 VENDOR_ID.w
  echo "setpci-rc=$?"
  timeout -k 2 3 setpci -s 67:00.0 DEVICE_ID.w
  echo "setpci-rc=$?"
  echo "-- setpci COMMAND/STATUS/LAT --"
  timeout -k 2 3 setpci -s 67:00.0 COMMAND
  timeout -k 2 3 setpci -s 67:00.0 STATUS
  echo "-- BAR0 --"
  timeout -k 2 3 setpci -s 67:00.0 BASE_ADDRESS_0
  echo "-- lspci -vvv (5s timeout; hangs mean config dead) --"
  timeout -k 2 5 lspci -vvv -s 67:00.0
  echo "lspci-rc=$?"
  echo "== AMD NHI 0:5.0/0:6.0 for contrast =="
  timeout -k 2 3 setpci -s bf:00.5 VENDOR_ID.w
  timeout -k 2 3 setpci -s bf:00.6 VENDOR_ID.w
} > "$OUT/nhi-pci.txt" 2>&1

dmesg > "$OUT/dmesg.txt" 2>&1
dmesg | grep -cE "timeout reading config|deactivation failed" \
  > "$OUT/wedge-error-count.txt" 2>&1
journalctl -k -b --no-pager > "$OUT/journal-kernel.txt" 2>&1

# Device topology + state files
TB=/sys/bus/thunderbolt/devices
{
  echo "== topology =="
  find $TB -maxdepth 2 -type l -o -maxdepth 2 -type d 2>/dev/null | sort
  echo "== all attribute files =="
  for d in $TB/*/; do
    echo "-- $d"
    for f in "$d"*[A-Za-z_]; do
      [ -f "$f" ] || continue
      printf '%s: ' "$(basename "$f")"
      timeout -k 1 2 cat "$f" 2>&1 | head -c 200
      echo
    done
  done
} > "$OUT/tb-sysfs.txt" 2>&1

# configfs stream tree
find /sys/kernel/config/usb4 -maxdepth 4 -exec sh -c \
  'for f in "$1"/*; do [ -f "$f" ] && { printf "%s: " "$f"; timeout -k 1 2 cat "$f" 2>&1 | head -c 100; echo; }; done' _ {} \; \
  > "$OUT/configfs.txt" 2>&1

# debugfs thunderbolt domain state if present
for d in /sys/kernel/debug/thunderbolt/*/; do
  [ -d "$d" ] && ls -la "$d" > "$OUT/debugfs-ls.txt" 2>&1
done
[ -f /sys/kernel/debug/thunderbolt/0/domain ] && \
  cat /sys/kernel/debug/thunderbolt/0/domain > "$OUT/domain0.txt" 2>&1
grep -r . /sys/kernel/debug/thunderbolt/ 2>/dev/null \
  | head -100 > "$OUT/debugfs-dump.txt" 2>&1

# netdev state
ip -d link > "$OUT/links.txt" 2>&1
ip addr >> "$OUT/links.txt" 2>&1

# Any hung tasks / D-state stacks
for t in /proc/[0-9]*/stack; do
  if grep -q "tb_" "$t" 2>/dev/null; then
    echo "== $t ==" >> "$OUT/hung-tasks.txt"
    cat "$t" >> "$OUT/hung-tasks.txt" 2>&1
  fi
done
[ -f "$OUT/hung-tasks.txt" ] || echo none > "$OUT/hung-tasks.txt"

echo "tarball:"
TARBALL="$OUT.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
echo "$TARBALL ($(du -h "$TARBALL" | cut -f1))"
