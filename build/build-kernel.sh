#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_COMMIT="${KERNEL_COMMIT:?must be set}"
PKGDIR="${PKGDIR:-linux-uconsole-cm5-4k-git}"

# Total pack capacity in mAh, for the device-tree battery node.
#
# The uConsole CM5 overlay describes ClockworkPi's stock 6700mAh pack. That is a
# property of the DTS, not of the machine, and it is what the AXP223 driver
# reports as charge_full_design -- so on any other cells it describes hardware
# that is not present. Parametrised so a cell swap is one variable, not a patch.
#
# 2x 3500mAh 18650 in parallel = 7000. For the 2x2000 pair, pass 4000.
BATTERY_MAH="${BATTERY_MAH:-7000}"

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

# Correct the device-tree battery node to describe the cells actually fitted.
#
# This does NOT fix the fuel gauge -- that reads high because it is uncalibrated
# (`calibrate` returns 0), and the stock 6700mAh figure is within a few percent
# of a 2x3500 pack anyway. It is here so the DT describes real hardware, which
# matters if anyone ever does calibrate it.
#
# The patch is asserted, not assumed: if the property moves or the upstream value
# changes, the build FAILS rather than silently shipping the stock figure.
_uah=$(( BATTERY_MAH * 1000 ))
_uwh=$(( BATTERY_MAH * 37 * 100 ))     # mAh * 3.7V, in microwatt-hours
awk -v uah="$_uah" -v uwh="$_uwh" '
  /^prepare\(\) \{/ && !done {
    print
    print "  # Battery node: describe the cells actually fitted (see build-kernel.sh)."
    print "  # cd first: this block is injected at the top of prepare(), before the"
    print "  # existing cd, so without this the grep searches srcdir and finds nothing."
    print "  cd \"${srcdir}/kernel\""
    print "  _dts=$(grep -rl charge-full-design-microamp-hours arch/arm64/boot/dts/overlays/ 2>/dev/null | grep -i uconsole | grep -i cm5 | head -1)"
    print "  [[ -n $_dts ]] || { echo \"ERROR: no uConsole CM5 overlay DTS carries a battery node\" >&2; exit 1; }"
    print "  echo \"patching battery node in $_dts\""
    print "  sed -i -E \"s/(charge-full-design-microamp-hours[[:space:]]*=[[:space:]]*<)[^>]+(>)/\\1" uah "\\2/\" \"$_dts\""
    print "  sed -i -E \"s/(energy-full-design-microwatt-hours[[:space:]]*=[[:space:]]*<)[^>]+(>)/\\1" uwh "\\2/\" \"$_dts\""
    print "  grep -q \"charge-full-design-microamp-hours = <" uah ">\" \"$_dts\" || { echo \"ERROR: battery capacity patch did not apply\" >&2; exit 1; }"
    print "  grep -q \"energy-full-design-microwatt-hours = <" uwh ">\" \"$_dts\" || { echo \"ERROR: battery energy patch did not apply\" >&2; exit 1; }"
    done=1; next
  } 1' /home/builder/build/PKGBUILD > /tmp/PKGBUILD.bat
mv /tmp/PKGBUILD.bat /home/builder/build/PKGBUILD
echo "--- battery patch injected into prepare() (${BATTERY_MAH}mAh = ${_uah}uAh / ${_uwh}uWh) ---"
grep -n 'battery node\|charge-full-design' /home/builder/build/PKGBUILD

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
