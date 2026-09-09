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

# Source patches applied to the kernel tree itself, as opposed to the config
# edits below. makepkg fetches the kernel during prepare(), so the patches have
# to be applied from inside prepare() -- there is no earlier point at which the
# source exists.
if compgen -G "/work/build/patches/*.patch" >/dev/null; then
    install -d /home/builder/build/patches
    cp -v /work/build/patches/*.patch /home/builder/build/patches/
fi

# The PKGBUILD uses ${KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-}, which falls back to the
# cross prefix even when the var is set to empty. We build natively on aarch64, where no
# aarch64-linux-gnu-* binaries exist, so switch to ${VAR-default} (unset-only fallback).
sed -i 's/KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-/KERNEL_CROSS_COMPILE-aarch64-linux-gnu-/' /home/builder/build/PKGBUILD
grep -n 'KERNEL_CROSS_COMPILE' /home/builder/build/PKGBUILD

# Apply source patches at the top of prepare(), immediately after it enters the
# kernel tree.
#
# Anchored on `prepare()` first, NOT simply on the first `cd "${srcdir}/kernel"`:
# that same line opens pkgver(), prepare(), build() and package(), and pkgver()
# comes first. Matching the bare cd put the patch loop inside pkgver(), where
# makepkg runs it during version detection and a `return 1` would break version
# detection rather than the build. Verified by inspecting the emitted PKGBUILD.
#
# --forward makes a re-run a no-op rather than an error, but a genuine failure
# to apply is fatal: silently building an unpatched kernel would mean testing the
# wrong thing and drawing the wrong conclusion from it.
awk '
  /^prepare\(\)/ { inprep = 1 }
  inprep && !done && index($0, "cd \"${srcdir}/kernel\"") {
       print
       print "  for _patch in \"${startdir}\"/patches/*.patch; do"
       print "    [ -e \"$_patch\" ] || continue"
       print "    echo \"applying $(basename \"$_patch\")\""
       print "    patch -p1 --forward < \"$_patch\" || { echo \"PATCH FAILED: $_patch\"; return 1; }"
       print "  done"
       done = 1; next
     } 1' /home/builder/build/PKGBUILD > /tmp/PKGBUILD.patched
mv /tmp/PKGBUILD.patched /home/builder/build/PKGBUILD
echo "--- prepare() after patch injection ---"
sed -n '/^prepare()/,/^}/p' /home/builder/build/PKGBUILD
# Fail loudly here rather than silently building an unpatched kernel.
if compgen -G "/home/builder/build/patches/*.patch" >/dev/null; then
    sed -n '/^prepare()/,/^}/p' /home/builder/build/PKGBUILD | grep -q 'patch -p1 --forward' \
      || { echo "ERROR: patches present but the injection did not land in prepare()"; exit 1; }
fi

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
