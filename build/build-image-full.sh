#!/usr/bin/env bash
set -Eeuo pipefail

IMG="/work/out/uconsole-arch-cm5-sway.img"
SIZE="${IMAGE_SIZE:-8G}"
REPO_PORT=8089
HTTP_PID=""

cleanup() { [[ -n $HTTP_PID ]] && kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Remove any previous image from *inside* the container: Docker Desktop's file
# sharing lags a host-side rm, and build-image.sh aborts if the target exists.
rm -f "$IMG"

echo "=== [1/6] host tooling ==="
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
grep -q '^DisableDownloadTimeout' /etc/pacman.conf || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
  parted util-linux dosfstools e2fsprogs libarchive curl \
  arch-install-scripts psmisc systemd coreutils gawk sed grep python

echo "=== [2/6] building local pacman repo from source-built packages ==="
rm -rf /work/repo/aarch64
install -d /work/repo/aarch64
# Only kernel/wifi packages -- never the .img files that also live in out/.
cp -v /work/out/*.pkg.tar.* /work/repo/aarch64/
cd /work/repo/aarch64
repo-add uconsole-arch.db.tar.zst ./*.pkg.tar.*
ls -la /work/repo/aarch64
cd /work

echo "=== [3/6] serving local repo on 127.0.0.1:${REPO_PORT} ==="
# arch-chroot does not create a network namespace, so the chroot reaches this too.
python -m http.server "$REPO_PORT" --bind 127.0.0.1 --directory /work/repo &>/work/build/repo-http.log &
HTTP_PID=$!
sleep 2
curl -sfI "http://127.0.0.1:${REPO_PORT}/aarch64/uconsole-arch.db" >/dev/null && echo "local repo reachable"

echo "=== [4/6] selecting the 4K-page CM5 kernel and uconsole labels ==="
cd /work/uconsole-arch

# Label the card "uconsole". The FAT partition label is what a host OS shows when
# the card is inserted, so it carries the user-visible name; the ext4 label is
# renamed in lockstep across mkfs, fstab and cmdline.txt so root= still resolves.
sed -i 's/mkfs\.vfat -F 32 -n BOOT/mkfs.vfat -F 32 -n UCONSOLE/' scripts/build-image.sh
sed -i 's/-L alarm-root/-L uconsole-root/' scripts/build-image.sh
sed -i 's/LABEL=alarm-root/LABEL=uconsole-root/' scripts/build-image.sh
sed -i 's/root label: alarm-root/root label: uconsole-root/' scripts/build-image.sh
sed -i 's/root=LABEL=alarm-root/root=LABEL=uconsole-root/' profiles/cmdline.txt

# Replace the upstream boot profiles with ours: adds ignore_lcd=1 and
# max_framebuffers=2 (absent upstream, and the panel stays dark without them)
# plus fbcon=rotate:1 for the console orientation.
cp /work/profiles/config.txt  profiles/config.txt
cp /work/profiles/cmdline.txt profiles/cmdline.txt
echo "--- installed our config.txt/cmdline.txt ---" 
echo "--- label wiring ---"
grep -n 'mkfs.vfat\|mkfs.ext4\|LABEL=' scripts/build-image.sh | grep -v '^.*#' | head
cat profiles/cmdline.txt
# Upstream hardcodes the 16K-page kernel for cm5. The 4K package installs into the
# same boot slot (vmlinuz-linux-uconsole-cm5-git), so only the package name changes;
# mkinitcpio_preset and profiles/config.txt stay as they are.
sed -i 's/kernel_pkg="linux-uconsole-cm5-git"/kernel_pkg="linux-uconsole-cm5-4k-git"/' scripts/build-image.sh
grep -n 'kernel_pkg=\|mkinitcpio_preset=' scripts/build-image.sh | head

bash /work/build/install-partprobe-shim.sh

echo "=== [5/6] building image ==="
PKGS=(
  sway swaybg swayidle swaylock foot fuzzel waybar xorg-xwayland
  polkit ttf-dejavu mesa
  pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils
  brightnessctl wl-clipboard grim slurp
  bluez bluez-utils parted git htop
  # 4G/LTE: ModemManager stack plus libgpiod, which the CM5 power-on
  # script uses (gpioset) instead of CM4's pinctrl approach.
  modemmanager libgpiod libqmi usb_modeswitch net-tools
  # From the on-device defect report:
  cloud-guest-utils   # growpart, so the root filesystem actually expands (S3.1)
  wireless-regdb iw   # regulatory.db, or brcmfmac floods the log (S3.7)
  usbutils            # lsusb, for modem triage (S3.11)
  zram-generator      # compressed swap; there is none and only 4GB RAM (S3.11)
  python              # the waybar modem module is a python3 script
  tmux                # TPM + resurrect + continuum are pre-installed in /etc/skel
  tailscale           # daemon enabled but unauthenticated; no key is baked in
  evtest              # inspect raw input events (power key, keyboard, trackball)
)
EXTRA_ARGS=()
for p in "${PKGS[@]}"; do EXTRA_ARGS+=(--extra-package "$p"); done

./scripts/build-image.sh \
  --model cm5 \
  --image "$IMG" \
  --size "$SIZE" \
  --rootfs /work/cache/ArchLinuxARM-aarch64-latest.tar.gz \
  --repo-url "http://127.0.0.1:${REPO_PORT}/\$arch" \
  --hostname uconsole \
  "${EXTRA_ARGS[@]}"

echo "=== [6/6] applying uConsole overlay ==="
bash /work/build/customize-image.sh "$IMG"

echo "IMAGE BUILD OK: $IMG"
