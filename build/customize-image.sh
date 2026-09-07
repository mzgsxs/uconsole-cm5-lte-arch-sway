#!/usr/bin/env bash
set -Eeuo pipefail

IMG="${1:?usage: customize-image.sh IMAGE}"
MNT=/mnt/uconsole
LOOP=""

cleanup() {
  for mp in "$MNT/run" "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" "$MNT/boot" "$MNT"; do
    mountpoint -q "$mp" && umount -R "$mp" 2>/dev/null || true
  done
  [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "--- attaching $IMG ---"
LOOP="$(losetup -Pf --show "$IMG")"
partprobe "$LOOP" || true
sleep 1
echo "loop: $LOOP"

install -d "$MNT"
mount "${LOOP}p2" "$MNT"
mount "${LOOP}p1" "$MNT/boot"

echo "--- copying overlay ---"
cp -a /work/overlay/. "$MNT/"

# Normalise ownership and modes rather than inheriting whatever the build host
# happened to have. Docker Desktop presents bind-mounted files as root-owned, so
# this is a no-op there -- but on a Linux build host `cp -a` preserves the
# building user's uid, and NetworkManager silently refuses to run dispatcher
# scripts that are not root-owned. Depending on the mount's behaviour would make
# the image correct on one host and quietly broken on another.
chown -R root:root "$MNT/usr/local/bin" "$MNT/etc/systemd" "$MNT/etc/skel" 2>/dev/null || true
[[ -d $MNT/etc/NetworkManager ]] && chown -R root:root "$MNT/etc/NetworkManager"
chmod 755 "$MNT/usr/local/bin"/uconsole-* 2>/dev/null || true
if [[ -d $MNT/etc/NetworkManager/dispatcher.d ]]; then
    chmod 755 "$MNT/etc/NetworkManager/dispatcher.d"/* 2>/dev/null || true
fi

echo "--- chroot configuration ---"
cat > "$MNT/root/uconsole-customize.sh" <<'EOF_C'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[chroot] removing the stock Arch Linux ARM kernel"
# The ALARM rootfs ships linux-aarch64, which the uConsole cannot use. It is dead
# weight (~60MB of /boot plus a full modules tree) and, worse, a later -Syu could
# have it rewrite files in /boot. config.txt already boots the uConsole kernel.
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
    echo "[chroot] reverse dependencies of linux-aarch64:"
    pacman -Qi linux-aarch64 | grep -i 'required by' || true
    pacman -Rdd --noconfirm linux-aarch64
    rm -f /boot/Image /boot/Image.gz
    echo "[chroot] stock kernel removed"
else
    echo "[chroot] stock kernel not present"
fi

echo "[chroot] removing the build-time local package repository"
# build-image.sh writes a [uconsole-arch] stanza pointing at the throwaway HTTP
# server used to serve our source-built kernel during the build. That address is
# dead on the real device and makes every pacman sync fail, so strip it here.
# Matched without brackets on purpose: an unescaped [uconsole-arch] is read as a
# bracket expression whose "e-a" is an invalid range. Only the section header
# line contains this string, so the range removes exactly those three lines.
if grep -q uconsole-arch /etc/pacman.conf; then
    sed -i "/uconsole-arch/,+2d" /etc/pacman.conf
    echo "[chroot] build-time repo removed"
fi

echo "[chroot] locale"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "[chroot] sudo for wheel"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "[chroot] user groups"
usermod -aG wheel,video,audio,input,render,storage,network alarm

echo "[chroot] seeding alarm home from skel"
# Copy everything in /etc/skel, dotfiles included. The previous version copied
# only .config and .bash_profile, so alarm silently missed .bashrc, .vimrc and
# .tmux.conf while a firstboot-created user (via useradd -m) got them all.
cp -a /etc/skel/. /home/alarm/ 2>/dev/null || true
chown -R alarm:alarm /home/alarm

echo "[chroot] enabling services"
systemctl enable uconsole-expand-root.service
systemctl enable bluetooth.service
systemctl enable ModemManager.service
systemctl enable uconsole-firstboot-user.service

# S3.2/S3.3: the vendor 4G script is broken on CM5 (wrong gpiochip, libgpiod v1
# syntax, and it drops the power line when gpioset exits). Replaced by
# uconsole-modem-power, which detects the chip by label and holds the line.
systemctl enable uconsole-modem-power.service
systemctl enable uconsole-modem-connect.service
# S3.5: voltage-based low-battery guard. The fuel gauge reads ~71% shortly
# before an undervoltage cut, so percentage-based logic fires far too late.
systemctl enable uconsole-battery-guard.timer

# Tailscale: the daemon runs but does nothing until someone authenticates with
# `tailscale up`. No auth key, no state and no identity is baked into the image
# -- deliberately, since these images are published. tailscaled needs /dev/net/tun
# (the tun module is present) and drives netfilter through nft/iptables-nft.
systemctl enable tailscaled.service

# S3.4: NetworkManager owns Wi-Fi, but systemd-networkd is also enabled in the
# stock ALARM rootfs. It manages nothing, its wait-online times out after two
# minutes on every boot, and -- the non-obvious part -- systemd-timesyncd
# follows networkd's online signal, so NTP never syncs and the clock stays
# wrong. Disabling it fixes the boot delay and the clock together.
systemctl disable systemd-networkd.service || true
systemctl disable systemd-networkd.socket || true
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true
# Socket/dbus activation covers most cases, but enabling globally makes audio
# work on a bare `exec sway` login with no desktop session manager.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
# Start a tmux server in each user session; tmux-continuum's restore hook fires
# on server start, which is what recovers sessions across a reboot.
systemctl --global enable tmux.service

echo "[chroot] verifying pacman works end to end (the check that was missing before)"
if pacman -Sy >/dev/null 2>&1; then
    echo "[chroot] pacman sync: OK"
    if pacman -Si firefox >/dev/null 2>&1; then
        echo "[chroot] pacman can resolve packages from the real repos: OK"
    else
        echo "[chroot] WARNING: pacman sync worked but package lookup failed"
    fi
else
    echo "[chroot] WARNING: pacman -Sy FAILED inside the image"
fi
# Leave no stale databases behind; the device fetches fresh ones on first -Syu.
rm -rf /var/lib/pacman/sync/*

echo "[chroot] verifying uConsole kernel bits are present"
ls -la /boot/vmlinuz-linux-uconsole-cm5-git
ls -la /boot/initramfs-linux-uconsole-cm5-git.img
ls /boot/overlays/clockworkpi-uconsole-cm5.dtbo
echo "[chroot] installed kernel package:"
pacman -Q | grep -i uconsole || true
echo "[chroot] page size config in installed kernel modules dir:"
ls -d /usr/lib/modules/*/ 
echo "[chroot] done"
EOF_C
chmod +x "$MNT/root/uconsole-customize.sh"
arch-chroot "$MNT" /bin/bash /root/uconsole-customize.sh
rm -f "$MNT/root/uconsole-customize.sh"

sync
echo "--- overlay applied ---"
