#!/usr/bin/env bash
set -Eeuo pipefail

IMG="${1:?usage: customize-image.sh IMAGE [runtime|dev]}"
PROFILE="${2:-runtime}"
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

if [[ $PROFILE == dev ]]; then
    echo "--- copying overlay-dev (dev profile) ---"
    cp -a /work/overlay-dev/. "$MNT/"

    # Wi-Fi credentials come from an UNTRACKED file, never from the repository.
    #
    # This repo is public. A PSK committed here would be published, and would
    # stay in the history after any later removal. secrets/ is gitignored and the
    # build reads it at assembly time; the runtime image never gets a connection
    # profile at all, and verification asserts that.
    WIFI_ENV=/work/secrets/wifi.env
    if [[ -r $WIFI_ENV ]]; then
        # shellcheck source=/dev/null
        . "$WIFI_ENV"
        if [[ -n ${WIFI_SSID:-} && -n ${WIFI_PSK:-} ]]; then
            install -d -m700 "$MNT/etc/NetworkManager/system-connections"
            CONN="$MNT/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
            cat > "$CONN" <<EOF_W
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true
autoconnect-priority=10

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF_W
            # NetworkManager REFUSES to load a connection file that is readable
            # by anyone but root, and says so only in its own log.
            chown root:root "$CONN"
            chmod 600 "$CONN"
            # Deliberately does not echo the SSID or the PSK. Build logs get
            # pasted into issues and chat; there is no reason for either value
            # to leave the file it lives in.
            echo "dev: pre-provisioned Wi-Fi (credentials read from $WIFI_ENV, not logged)"
        else
            echo "dev: $WIFI_ENV present but WIFI_SSID/WIFI_PSK unset; no Wi-Fi provisioned"
        fi
    else
        echo "dev: no $WIFI_ENV; image will have no pre-provisioned Wi-Fi"
        echo "     create it with WIFI_SSID= and WIFI_PSK= to enable this"
    fi
fi

# Normalise ownership and modes rather than inheriting whatever the build host
# happened to have. Docker Desktop presents bind-mounted files as root-owned, so
# this is a no-op there -- but on a Linux build host `cp -a` preserves the
# building user's uid, and NetworkManager silently refuses to run dispatcher
# scripts that are not root-owned. Depending on the mount's behaviour would make
# the image correct on one host and quietly broken on another.
chown -R root:root "$MNT/usr/local/bin" "$MNT/etc/systemd" "$MNT/etc/skel" 2>/dev/null || true
[[ -d $MNT/etc/uconsole ]] && chown -R root:root "$MNT/etc/uconsole"
[[ -d $MNT/etc/firefox ]]  && chown -R root:root "$MNT/etc/firefox"
# sudo silently IGNORES a drop-in that is group- or world-writable, or not owned
# by root -- it warns to syslog and carries on without the rule. That failure is
# invisible until a key binding quietly stops being able to switch the radios
# off, so set both explicitly rather than trusting what cp -a happened to carry.
if [[ -f $MNT/etc/sudoers.d/uconsole-lowpower ]]; then
    chown root:root "$MNT/etc/sudoers.d/uconsole-lowpower"
    chmod 440       "$MNT/etc/sudoers.d/uconsole-lowpower"
fi
[[ -d $MNT/etc/NetworkManager ]] && chown -R root:root "$MNT/etc/NetworkManager"
chmod 755 "$MNT/usr/local/bin"/uconsole-* 2>/dev/null || true
# Re-assert after the chown -R above, which would otherwise leave the connection
# file group-readable and make NetworkManager refuse to load it.
chmod 600 "$MNT"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
if [[ -d $MNT/etc/NetworkManager/dispatcher.d ]]; then
    chmod 755 "$MNT/etc/NetworkManager/dispatcher.d"/* 2>/dev/null || true
fi

echo "--- chroot configuration ---"
cat > "$MNT/root/uconsole-customize.sh" <<EOF_PRE
#!/usr/bin/env bash
PROFILE=$PROFILE
EOF_PRE
cat >> "$MNT/root/uconsole-customize.sh" <<'EOF_C'
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
# Long-press poweroff: shorten the PMIC's press-detect delay so systemd's
# hardcoded 5s timer is the whole wait, and push the hardware force-off to its
# maximum so the clean shutdown always beats the unclean cut.
systemctl enable uconsole-powerkey-tune.service
# Inbound firewall. sshd listens on every interface with password auth, and this
# machine roams onto public Wi-Fi and a carrier LTE address; the ruleset limits
# SSH to private LANs and the tailnet rather than disabling password auth.
systemctl enable nftables.service
# zram needs no unit enabled: zram-generator reads /etc/systemd/zram-generator.conf
# at boot and synthesises systemd-zram-setup@zram0.service itself.

# alsa-utils is installed for its TOOLS (alsamixer, speaker-test) on a board with
# documented audio faults -- not for its daemon. alsa-state.service is "static",
# so it looks disabled, but alsa-utils symlinks it into sound.target.wants and
# udev reaches sound.target as soon as the card appears: it would run as a
# resident alsactl process on a battery device for no benefit, because
# WirePlumber owns mixer state here, not alsactl.
#
# alsa-restore.service is left alone: it is a oneshot that exits.
systemctl mask alsa-state.service || true

# S3.9: make suspend unreachable.
#
# Not a preference -- a hazard. Both sleep states register on this build and
# BOTH hang the machine: `deep` is a PSCI firmware stub (BCM2712 has no DDR
# self-refresh sequences) and `s2idle` wedges the SDIO Wi-Fi chip so hard that
# only a reboot recovers it. Five attempts, five hard hangs, two dirty
# filesystems. Masking is what stops a stray `systemctl suspend`, a desktop menu
# item or a future logind default from reaching it.
#
# The kernel command line carries mem_sleep_default=s2idle as well, for anything
# that writes /sys/power/state directly and bypasses systemd entirely -- which is
# exactly what rtcwake does. mem_sleep resets to `deep` on every boot.
systemctl mask sleep.target suspend.target hibernate.target \
               hybrid-sleep.target suspend-then-hibernate.target

# systemd-rfkill persists rfkill state to /var/lib/systemd/rfkill and restores it
# at boot. The low-power blank can block Wi-Fi and Bluetooth; if the machine dies
# while blanked, that persistence carries the block into the next boot and you
# come up with no radios, no SSH, and nothing on screen saying why. Masked so a
# block can never outlive the boot that set it.
systemctl mask systemd-rfkill.service systemd-rfkill.socket || true
# NetworkManager keeps its own radio flag, which masking above does not touch.
systemctl enable uconsole-radio-restore.service

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

echo "[chroot] adding the OTA recovery check to the initramfs"
# The hook is an INSTALL hook only -- it adds a systemd unit rather than a
# run_hook function, because this initramfs runs systemd in early userspace and
# the two mechanisms are not interchangeable. Position in HOOKS is therefore
# irrelevant to ordering; that comes from the unit's own Before=/After=.
if ! grep -q 'uconsole-ota' /etc/mkinitcpio.conf; then
    sed -i -E 's/^(HOOKS=\(.*)\)$/\1 uconsole-ota)/' /etc/mkinitcpio.conf
fi
grep -n '^HOOKS=' /etc/mkinitcpio.conf
# Regenerate, and let a failure fail the build: an initramfs that did not pick up
# the hook would ship a machine whose recovery path silently does not exist.
mkinitcpio -P
# Assert the unit actually landed. `mkinitcpio -P` exiting 0 does not prove the
# hook ran -- an install hook that is present but not listed in HOOKS is a no-op.
if lsinitcpio /boot/initramfs-linux-uconsole-cm5-git.img | grep -q 'uconsole-ota-recovery'; then
    echo "[chroot] OTA recovery check is in the initramfs"
else
    echo "[chroot] ERROR: OTA recovery check missing from the initramfs" >&2
    exit 1
fi

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
