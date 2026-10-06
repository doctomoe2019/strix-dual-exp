#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# postboot-validate.sh — runs ONCE at hostA boot (postboot-validate.service)
# after the pair is healthy: verifies the new kernel baseline and reruns the
# Stage-0 reference block (A7/A18/A17/B0 x3). Results land in evidence/.
exec > /root/strix-dual-exp/evidence/postboot-$(date +%Y%m%d-%H%M%S).log 2>&1
set -x
date -Is
echo "thunderbolt=$(cat /sys/module/thunderbolt/srcversion 2>/dev/null)"
echo "thunderbolt_stream=$(cat /sys/module/thunderbolt_stream/srcversion 2>/dev/null)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"

for i in $(seq 1 120); do
  if ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1 && \
     timeout 3 bash -c 'exec 9<>/dev/tbstream0' 2>/dev/null; then
    break
  fi
  sleep 5
done
if ! ping -c1 -W1 $TBNET_B_IP >/dev/null 2>&1; then
  echo "PAIR NOT HEALTHY after 10 min — manual attention needed"
  exit 1
fi
echo "pair healthy + stream open at $(date -Is)"
echo "ida warnings: $(dmesg | grep -c 'ida_free called')"
timeout 15 ssh -o ConnectTimeout=10 hostB \
  'echo "r2 thunderbolt=$(cat /sys/module/thunderbolt/srcversion) stream=$(cat /sys/module/thunderbolt_stream/srcversion)"'

# The reference block (same gufo binary; kernel is the only variable).
ARMS=A7,A18,A17,B0 ROUNDS=3 bash /root/strix-dual-exp/scripts/ablate.sh
echo "=== postboot-validate done $(date -Is) ==="
