#!/usr/bin/env bash
# Per-site values: scripts/env.sh (gitignored) overrides these defaults.
_dir=$(dirname "$(readlink -f "$0")")
[ -f "$_dir/env.sh" ] && . "$_dir/env.sh"
: "${HOST_A:=hostA}" "${HOST_B:=hostB}" "${TBNET_BASE:=10.55.0}"
TBNET_A_IP="${TBNET_A_IP:-$TBNET_BASE.1}"
TBNET_B_IP="${TBNET_B_IP:-$TBNET_BASE.2}"
# Post-reboot recovery for the wedge test loop: wait for hostB, bring up
# the link, re-enable dyndbg, re-warm the model page cache on both hosts.
set -u
echo "waiting for hostB ssh..."
for i in $(seq 1 60); do
  timeout 8 ssh -o ConnectTimeout=6 $HOST_B 'echo up' >/dev/null 2>&1 && break
  sleep 10
done
timeout 8 ssh -o ConnectTimeout=6 $HOST_B 'echo up' >/dev/null 2>&1 || { echo "HOSTB-DOWN"; exit 1; }
echo "hostB up (poll $i)"
timeout 90 ssh $HOST_B 'bash /root/strix-dual-exp/scripts/bringup.sh 1' 2>&1 | tail -1
timeout 90 bash $(dirname "$0")/bringup.sh 0 2>&1 | tail -1
sleep 3
if ping -c1 -W2 $TBNET_B_IP >/dev/null 2>&1; then echo "ping=ok"; else echo "ping=DEAD"; exit 1; fi
d0=$(dmesg | grep -cE "timeout reading config|deactivation failed")
s0=$(timeout 10 ssh $HOST_B 'dmesg | grep -cE "timeout reading config|deactivation failed"')
echo "baseline errs: hostA=$d0 hostB=$s0"
echo 'module thunderbolt_stream +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
timeout 10 ssh $HOST_B 'echo "module thunderbolt_stream +p" > /sys/kernel/debug/dynamic_debug/control' 2>/dev/null
nohup bash -c 'cat /models/*.gguf > /dev/null; echo w1' > /tmp/w.log 2>&1 &
timeout 10 ssh $HOST_B 'nohup bash -c "cat /models/*.gguf > /dev/null; echo w2" > /tmp/w.log 2>&1 &'
for t in $(seq 1 30); do [ -s /tmp/w.log ] && break; sleep 5; done
timeout 10 ssh $HOST_B 'for t in $(seq 1 30); do [ -s /tmp/w.log ] && break; sleep 5; done'
echo "recovered $(date +%H:%M:%S)"
