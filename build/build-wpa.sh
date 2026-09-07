#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== pacman bootstrap ==="
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
grep -q '^DisableDownloadTimeout' /etc/pacman.conf || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git openssl libnl dbus pcsclite

id builder &>/dev/null || useradd -m -s /bin/bash builder
install -d -o builder -g builder /home/builder/build
cp -r /work/uconsole-arch/pkgs/wpa_supplicant-raspberrypi/. /home/builder/build/

P=/home/builder/build/PKGBUILD
# docbook-sgml/docbook-utils/perl-sgmls are AUR-only and are used solely to render
# man pages. Drop the man page build so this compiles against the official repos;
# the resulting binaries and the Broadcom WPA2 revert are unaffected.
sed -i -e '/^  docbook-sgml$/d' -e '/^  docbook-utils$/d' -e '/^  perl-sgmls$/d' "$P"
sed -i -e '/_make -C doc\/docbook man/d' \
       -e '/doc\/docbook\/\*\.5/d' \
       -e '/doc\/docbook\/\*\.8/d' \
       -e '/share\/man\/man8\/wpa_/d' "$P"
echo "--- patched makedepends ---"; sed -n '/^makedepends=(/,/^)/p' "$P"
echo "remaining docbook references: $(grep -c 'docbook' "$P" || true)"

chown -R builder:builder /home/builder/build

echo "=== importing upstream signing key ==="
su builder -c "gpg --batch --import /home/builder/build/keys/pgp/*.asc"

echo "=== building ==="
su builder -c "cd /home/builder/build && MAKEFLAGS='-j4' makepkg -f --noconfirm --nocheck"

install -d /work/out
cp -v /home/builder/build/*.pkg.tar.* /work/out/
echo "WPA BUILD OK"
