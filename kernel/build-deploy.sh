#!/usr/bin/env bash
# Build and deploy the patched thunderbolt + stream modules to the
# local host. Run from kernel/ after any source edit.
set -e
KREL=${KREL:-$(uname -r)}
TREE=$(dirname "$0")/build-tree
MODDIR=/lib/modules/$KREL/kernel/drivers/thunderbolt

make -C /lib/modules/$KREL/build M=$TREE modules
sudo cp $TREE/thunderbolt.ko $TREE/thunderbolt_stream.ko $MODDIR/
sudo depmod -a
sudo update-initramfs -u
echo "deployed: $(modinfo -F srcversion $MODDIR/thunderbolt.ko) — reboot to load"
