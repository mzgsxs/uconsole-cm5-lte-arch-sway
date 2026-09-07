#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_COMMIT="${KERNEL_COMMIT:?must be set}"
PKGDIR="${PKGDIR:-linux-uconsole-cm5-4k-git}"

echo "=== [1/5] pacman bootstrap ==="
# Landlock sandbox is unavailable in Docker Desktop's VM; disable it globally.
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
grep -q '^DisableDownloadTimeout' /etc/pacman.conf || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm

echo "=== [2/5] installing toolchain ==="
pacman -S --needed --noconfirm \
  base-devel git bc bison flex openssl elfutils pahole cpio perl tar xz \
  kmod mkinitcpio coreutils rsync

echo "=== [3/5] preparing build user ==="
id builder &>/dev/null || useradd -m -s /bin/bash builder
install -d -o builder -g builder /home/builder/build
cp -r "/work/uconsole-arch/pkgs/${PKGDIR}/." /home/builder/build/

# The PKGBUILD uses ${KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-}, which falls back to the
# cross prefix even when the var is set to empty. We build natively on aarch64, where no
# aarch64-linux-gnu-* binaries exist, so switch to ${VAR-default} (unset-only fallback).
sed -i 's/KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-/KERNEL_CROSS_COMPILE-aarch64-linux-gnu-/' /home/builder/build/PKGBUILD
grep -n 'KERNEL_CROSS_COMPILE' /home/builder/build/PKGBUILD

# bcm2712_defconfig leaves Landlock off, but pacman 7 sandboxes its downloader
# with it and hard-fails without it ("landlock is not supported by the kernel").
# Insert the enable before olddefconfig resolves dependencies. Uses awk rather
# than python3, which is not installed in this build container.
awk '/scripts.config --disable LOCALVERSION_AUTO/ && !done {
       print "  # Required by pacman 7'"'"'s download sandbox."
       print "  scripts/config --enable SECURITY_LANDLOCK"
       print "  # S3.9: bcm2712_defconfig ships no sleep states at all, so"
       print "  # /sys/power/state is empty and systemctl suspend has nothing to call."
       print "  scripts/config --enable SUSPEND"
       print "  scripts/config --enable PM_SLEEP"
       print "  scripts/config --enable PM"
       done=1
     } 1' /home/builder/build/PKGBUILD > /tmp/PKGBUILD.new
mv /tmp/PKGBUILD.new /home/builder/build/PKGBUILD
grep -n 'LANDLOCK\|SUSPEND\|PM_SLEEP\|LOCALVERSION' /home/builder/build/PKGBUILD

chown -R builder:builder /home/builder/build

echo "=== [4/5] building kernel package (commit ${KERNEL_COMMIT}) ==="
su builder -c "cd /home/builder/build && \
  KERNEL_CROSS_COMPILE= KERNEL_COMMIT='${KERNEL_COMMIT}' \
  MAKEFLAGS='-j$(nproc)' \
  makepkg -f --noconfirm --skipinteg --nocheck"

echo "=== [5/5] exporting packages ==="
install -d /work/out
cp -v /home/builder/build/*.pkg.tar.* /work/out/
echo "KERNEL BUILD OK"
