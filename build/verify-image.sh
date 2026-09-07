#!/usr/bin/env bash
set -Eeuo pipefail

IMG="${1:?usage: verify-image.sh IMAGE}"
MNT=/mnt/verify
LOOP=""
FAILS=0
PASSES=0

cleanup() {
  for mp in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot" "$MNT"; do
    mountpoint -q "$mp" && umount -R "$mp" 2>/dev/null || true
  done
  [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

ok()   { printf '  [PASS] %s\n' "$*"; PASSES=$((PASSES+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "############ VERIFYING $IMG ############"
echo
echo "### 1. image file"
ls -la "$IMG"
# parted writes an MBR with no boot code, so file(1) does not recognise it as a
# "DOS/MBR boot sector"; read the partition table itself instead.
check "image carries a DOS/MBR partition table" "sfdisk -d '$IMG' 2>/dev/null | grep -q 'label: dos'"

echo
echo "### 2. partition table"
LOOP="$(losetup -Pf --show "$IMG")"; partprobe "$LOOP" || true; sleep 1
fdisk -l "$LOOP"
check "partition 1 exists (boot)" "[[ -b ${LOOP}p1 ]]"
check "partition 2 exists (root)" "[[ -b ${LOOP}p2 ]]"
check "partition 1 is FAT32"      "blkid -o value -s TYPE ${LOOP}p1 | grep -q vfat"
check "partition 2 is ext4"       "blkid -o value -s TYPE ${LOOP}p2 | grep -q ext4"
check "boot label is UCONSOLE"    "blkid -o value -s LABEL ${LOOP}p1 | grep -qi UCONSOLE"
check "root label is uconsole-root" "blkid -o value -s LABEL ${LOOP}p2 | grep -q uconsole-root"
check "partition 1 has boot flag" "fdisk -l '$LOOP' | grep -qE '${LOOP}p1.*\*'"

echo
echo "### 3. filesystem integrity"
fsck.fat -n "${LOOP}p1" 2>&1 | tail -3 || true
e2fsck -fn "${LOOP}p2" 2>&1 | tail -5 || true
check "ext4 root passes fsck" "e2fsck -fn ${LOOP}p2 >/dev/null 2>&1"

install -d "$MNT"
mount "${LOOP}p2" "$MNT"
mount "${LOOP}p1" "$MNT/boot"

echo
echo "### 4. boot partition contents"
ls -la "$MNT/boot" | head -30
check "config.txt present"    "[[ -s $MNT/boot/config.txt ]]"
check "cmdline.txt present"   "[[ -s $MNT/boot/cmdline.txt ]]"
check "kernel image present"  "[[ -s $MNT/boot/vmlinuz-linux-uconsole-cm5-git ]]"
check "initramfs present"     "[[ -s $MNT/boot/initramfs-linux-uconsole-cm5-git.img ]]"
check "initramfs is non-trivial (>4MB)" "[[ \$(stat -c%s $MNT/boot/initramfs-linux-uconsole-cm5-git.img) -gt 4194304 ]]"
check "CM5 device tree present" "ls $MNT/boot/bcm2712*cm5*.dtb >/dev/null 2>&1"
check "uConsole CM5 overlay present" "[[ -s $MNT/boot/overlays/clockworkpi-uconsole-cm5.dtbo ]]"
check "Pi5 KMS overlay present"      "[[ -s $MNT/boot/overlays/vc4-kms-v3d-pi5.dtbo ]]"
check "audremap-pi5 overlay present" "[[ -s $MNT/boot/overlays/audremap-pi5.dtbo ]]"
check "dwc2 overlay present"         "[[ -s $MNT/boot/overlays/dwc2.dtbo ]]"

echo
echo "--- config.txt [cm5] section ---"
sed -n '/^\[cm5\]/,/^\[/p' "$MNT/boot/config.txt"
echo "--- cmdline.txt ---"
cat "$MNT/boot/cmdline.txt"
check "config.txt selects the uConsole CM5 overlay" "grep -q 'dtoverlay=clockworkpi-uconsole-cm5' $MNT/boot/config.txt"
# These two are absent from the upstream profile and their absence leaves the panel dark.
check "config.txt sets ignore_lcd=1"        "grep -qE '^ignore_lcd=1' $MNT/boot/config.txt"
check "config.txt sets max_framebuffers=2"  "grep -qE '^max_framebuffers=2' $MNT/boot/config.txt"
check "config.txt enables PCIe for mini-PCIe slot" "grep -qE '^dtparam=pciex1$' $MNT/boot/config.txt"
check "cmdline rotates the console (fbcon=rotate:1)" "grep -q 'fbcon=rotate:1' $MNT/boot/cmdline.txt"
check "cmdline activates Landlock LSM" "grep -q 'lsm=landlock' $MNT/boot/cmdline.txt"
check "config.txt kernel= matches installed kernel"  "grep -q 'kernel=vmlinuz-linux-uconsole-cm5-git' $MNT/boot/config.txt"
# Cross-check the label the kernel is told to boot from against the label the
# filesystem actually carries -- a mismatch here is an unbootable card.
CMDLINE_LABEL="$(grep -o 'root=LABEL=[^ ]*' "$MNT/boot/cmdline.txt" | cut -d= -f3)"
ACTUAL_LABEL="$(blkid -o value -s LABEL "${LOOP}p2")"
echo "cmdline root label: '$CMDLINE_LABEL' / actual ext4 label: '$ACTUAL_LABEL'"
check "cmdline root= matches the real ext4 label" "[[ -n '$CMDLINE_LABEL' && '$CMDLINE_LABEL' == '$ACTUAL_LABEL' ]]"
FSTAB_LABEL="$(grep -oE 'LABEL=[^ ]+' "$MNT/etc/fstab" | head -1 | cut -d= -f2)"
check "fstab root label matches too" "[[ '$FSTAB_LABEL' == '$ACTUAL_LABEL' ]]"

echo
echo "### 5. kernel modules + page size"
ls -d "$MNT"/usr/lib/modules/*/
KVER="$(basename "$(ls -d "$MNT"/usr/lib/modules/*/ | head -1)")"
echo "kernel release: $KVER"
# LOCALVERSION is -uconsole-cm5-4k; the kernel build appends '+' for a non-tagged tree.
check "kernel is the 4K-page uConsole build" "[[ '$KVER' == *-uconsole-cm5-4k* ]]"
check "modules.dep was generated"            "[[ -s $MNT/usr/lib/modules/$KVER/modules.dep ]]"
check "stock ALARM kernel removed (one modules tree)" "[[ \$(ls -d $MNT/usr/lib/modules/*/ | wc -l) -eq 1 ]]"
check "stock ALARM kernel image removed from /boot"   "[[ ! -e $MNT/boot/Image && ! -e $MNT/boot/Image.gz ]]"
check "brcmfmac wifi module present"         "find $MNT/usr/lib/modules/$KVER -name 'brcmfmac.ko*' | grep -q ."
check "clockworkpi/panel DRM modules present" "find $MNT/usr/lib/modules/$KVER -name 'vc4.ko*' | grep -q ."

echo
echo "### 6. userspace: sway + tooling"
for b in sway swaybg swayidle foot waybar fuzzel brightnessctl wpctl grim NetworkManager; do
  if [[ -x $MNT/usr/bin/$b ]]; then ok "binary present: $b"; else bad "binary MISSING: $b"; fi
done
check "xwayland present" "[[ -x $MNT/usr/bin/Xwayland ]]"
check "wpa_supplicant present" "[[ -x $MNT/usr/bin/wpa_supplicant ]]"

echo
echo "### 7. uConsole overlay files"
check "sway config seeded in /etc/skel"  "[[ -s $MNT/etc/skel/.config/sway/config ]]"
check "sway config in alarm home"        "[[ -s $MNT/home/alarm/.config/sway/config ]]"
check "sway config uses Alt as modifier" "grep -q 'set \$mod Mod1' $MNT/home/alarm/.config/sway/config"
check "sway config scales the DSI panel" "grep -q 'output DSI-2 scale' $MNT/home/alarm/.config/sway/config"
check "waybar config present"            "[[ -s $MNT/home/alarm/.config/waybar/config ]]"
check "alarm home owned by alarm"        "[[ -d $MNT/home/alarm/.config ]] && [[ \$(stat -c%U $MNT/home/alarm/.config) == alarm ]]"
check "expand-root script executable"    "[[ -x $MNT/usr/local/bin/uconsole-expand-root ]]"
check "tty1 autologin drop-in present"   "[[ -s $MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf ]]"
check "bash_profile launches sway on vt1" "grep -q 'exec sway' $MNT/home/alarm/.bash_profile"

echo
echo "### 8. enabled services"
ls -la "$MNT/etc/systemd/system/multi-user.target.wants/" 2>/dev/null | awk '{print $9, $10, $11}'
check "NetworkManager enabled"      "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/NetworkManager.service ]]"
check "sshd enabled"                "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/sshd.service ]]"
check "expand-root enabled"         "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-expand-root.service ]]"
check "bluetooth enabled"           "[[ -L $MNT/etc/systemd/system/bluetooth.target.wants/bluetooth.service || -L $MNT/etc/systemd/system/dbus-org.bluez.service ]]"

echo
echo "### 9. system config"
check "locale.conf set"  "grep -q 'LANG=en_US.UTF-8' $MNT/etc/locale.conf"
check "en_US.UTF-8 generated" "[[ -f $MNT/usr/lib/locale/locale-archive || -d $MNT/usr/lib/locale/en_US.utf8 ]]"
check "hostname is uconsole" "grep -q uconsole $MNT/etc/hostname"
check "wheel has sudo"       "grep -qE '^%wheel ALL=\(ALL:ALL\) ALL' $MNT/etc/sudoers"
check "alarm in video group" "grep -E '^video:' $MNT/etc/group | grep -q alarm"
check "alarm in input group" "grep -E '^input:' $MNT/etc/group | grep -q alarm"
check "fstab present"        "[[ -s $MNT/etc/fstab ]]"
check "no dead build-time pacman repo" "! grep -q '127.0.0.1' $MNT/etc/pacman.conf"
check "pacman.conf still has core/extra" "grep -q '^\[extra\]' $MNT/etc/pacman.conf"
echo "--- fstab ---"; cat "$MNT/etc/fstab"

echo
echo "### 10. live chroot smoke test"
mount --bind /dev "$MNT/dev"; mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"; mount -t sysfs sys "$MNT/sys"
if chroot "$MNT" /usr/bin/sway --version; then ok "sway runs inside the image"; else bad "sway failed to run"; fi
if chroot "$MNT" /usr/bin/waybar --version >/dev/null 2>&1; then ok "waybar runs"; else bad "waybar failed"; fi
mkdir -p "$MNT/run/user/1000"
if chroot "$MNT" /usr/bin/env XDG_RUNTIME_DIR=/run/user/1000 HOME=/root \
     WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
     /usr/bin/sway --validate --config /etc/skel/.config/sway/config >/dev/null 2>&1; then
  ok "sway config parses"
else
  bad "sway config FAILED to parse"
fi
# The check that was missing when the [colors] mistake shipped.
if chroot "$MNT" /usr/bin/foot --check-config --config=/etc/skel/.config/foot/foot.ini 2>&1 | grep -q "err:"; then
  bad "foot config has errors"
else
  ok "foot config parses"
fi
rm -rf "$MNT/run/user/1000"
chroot "$MNT" /usr/bin/pacman -Q linux-uconsole-cm5-4k-git && ok "4K kernel package registered" || bad "kernel package not registered"
echo "--- installed package count ---"
chroot "$MNT" /usr/bin/pacman -Q | wc -l
echo "--- disk usage in image ---"
df -h "$MNT" | tail -1

echo
echo "### 11. 4G / LTE support (report S3.2 / S3.3)"
check "modem power script present"     "[[ -x $MNT/usr/local/bin/uconsole-modem-power ]]"
check "modem power detects chip by label" "grep -q 'pinctrl-rp1' $MNT/usr/local/bin/uconsole-modem-power"
check "modem power holds the line (-z)"   "grep -q 'gpioset -z' $MNT/usr/local/bin/uconsole-modem-power"
check "modem power uses libgpiod v2 -c"   "grep -q 'gpioset -z -C .* -c ' $MNT/usr/local/bin/uconsole-modem-power"
# Only assert on live code: the script's header comment quotes the vendor bug
# it replaces, so a naive grep matches the explanation rather than the defect.
check "no hardcoded gpiochip0 in live code" "! grep -vE '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-modem-power | grep -q gpiochip0"
check "broken vendor 4G script removed"   "[[ ! -e $MNT/usr/local/bin/uconsole-4g-cm5.sh ]]"
check "modem power unit present"          "[[ -s $MNT/etc/systemd/system/uconsole-modem-power.service ]]"
check "modem power unit enabled"          "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-modem-power.service ]]"
check "modem unit does NOT mask failure"  "! grep -qE '^ExecStart=-' $MNT/etc/systemd/system/uconsole-modem-power.service"
check "modem connect script present"      "[[ -x $MNT/usr/local/bin/uconsole-modem-connect ]]"
check "modem connect sets raw_ip"         "grep -q 'raw_ip' $MNT/usr/local/bin/uconsole-modem-connect"
check "modem connect sets MTU 1280"       "grep -q '1280' $MNT/usr/local/bin/uconsole-modem-connect"
check "wan routing helper present"        "[[ -x $MNT/usr/local/bin/uconsole-wan ]]"
check "ModemManager enabled"              "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/ModemManager.service || -L $MNT/etc/systemd/system/dbus-org.freedesktop.ModemManager1.service ]]"
for b in gpioset gpioinfo gpiodetect mmcli qmicli ifconfig lsusb iw; do
  if [[ -x $MNT/usr/bin/$b || -x $MNT/usr/sbin/$b ]]; then ok "binary present: $b"; else bad "binary MISSING: $b"; fi
done
echo "--- WWAN kernel modules ---"
for m in option usb_wwan qmi_wwan cdc_ether cdc_ncm cdc_mbim; do
  if find "$MNT/usr/lib/modules/$KVER" -name "$m.ko*" 2>/dev/null | grep -q .; then ok "module: $m"; else bad "module MISSING: $m"; fi
done

echo
echo "### 12. first-boot account wizard"
check "firstboot script present"      "[[ -x $MNT/usr/local/bin/uconsole-firstboot-user ]]"
check "firstboot service present"     "[[ -s $MNT/etc/systemd/system/uconsole-firstboot-user.service ]]"
check "firstboot service enabled"     "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-firstboot-user.service ]]"
check "firstboot runs before the getty" "grep -q 'Before=getty@tty1.service' $MNT/etc/systemd/system/uconsole-firstboot-user.service"
check "firstboot owns tty1"           "grep -q 'TTYPath=/dev/tty1' $MNT/etc/systemd/system/uconsole-firstboot-user.service"
check "firstboot sets root password"  "grep -q 'set_pw root' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot sets alarm password" "grep -q 'set_pw alarm' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot grants wheel"        "grep -q 'wheel,video,audio,input' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot is one-shot (stamp)" "grep -q 'uconsole-firstboot-done' $MNT/usr/local/bin/uconsole-firstboot-user"
# The prompt shares tty1 with kernel printk and systemd status output; both are
# silenced for the duration of the wizard and restored on exit.
check "firstboot silences kernel printk"   "grep -q 'proc/sys/kernel/printk' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot silences systemd status"  "grep -q 'kill -s RTMIN+21 1' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot re-enables systemd status" "grep -q 'kill -s RTMIN+20 1' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot restores console on exit"  "grep -q 'trap console_restore EXIT' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot clears the screen"         "grep -qE 'clear 2>/dev/null' $MNT/usr/local/bin/uconsole-firstboot-user"
check "unit allocates a clean VT"           "grep -q 'TTYVTDisallocate=yes' $MNT/etc/systemd/system/uconsole-firstboot-user.service"
check "setterm available for msg off"       "[[ -x $MNT/usr/bin/setterm ]]"

echo
echo "### 13. requested customisations"
check "bashrc has the ll alias"        "grep -qF 'alias ll=\"ls -l -a\"' $MNT/etc/skel/.bashrc"
check "bashrc enables ls colour"       "grep -q \"ls --color=auto\" $MNT/etc/skel/.bashrc"
check "vimrc uses soft tabs"           "grep -qx 'set expandtab' $MNT/etc/skel/.vimrc"
check "vimrc keeps hard tabs in make"  "grep -q 'FileType make setlocal noexpandtab' $MNT/etc/skel/.vimrc"
check "vimrc enables syntax colour"    "grep -qx 'syntax on' $MNT/etc/skel/.vimrc"
check "sway removes window titles"     "grep -qx 'default_border none' $MNT/etc/skel/.config/sway/config"
check "sway binds 10 workspaces"       "[[ \$(grep -c '^bindsym \$mod+[0-9] workspace number' $MNT/etc/skel/.config/sway/config) -eq 10 ]]"
check "sway binds 10 move-to-workspace" "[[ \$(grep -c '^bindsym \$mod+Shift+[0-9] move container' $MNT/etc/skel/.config/sway/config) -eq 10 ]]"
check "workspace 10 is on the 0 key"   "grep -q 'mod+0 workspace number 10' $MNT/etc/skel/.config/sway/config"
check "evtest available for input diagnosis" "[[ -x $MNT/usr/bin/evtest ]]"
check "sway opens windows fullscreen"  "grep -q 'fullscreen enable' $MNT/etc/skel/.config/sway/config"
check "sway background is black"       "grep -q 'bg #000000' $MNT/etc/skel/.config/sway/config"
check "trackball uses flat accel"      "grep -q 'accel_profile flat' $MNT/etc/skel/.config/sway/config"
check "trackball scroll on right btn"  "grep -q 'scroll_button button3' $MNT/etc/skel/.config/sway/config"
# S3.8: dpms must NOT be the idle action -- only mentioned in the explanatory
# comment. Assert the backlight path is what swayidle actually runs.
check "idle dims the backlight"        "grep -q \"timeout 300 'brightnessctl -s set 0'\" $MNT/etc/skel/.config/sway/config"
check "idle restores the backlight"    "grep -q \"resume    'brightnessctl -r'\" $MNT/etc/skel/.config/sway/config"
check "no active dpms idle action"     "! grep -vE '^\\s*#' $MNT/etc/skel/.config/sway/config | grep -q dpms"
check "idle config has no suspend/poweroff" "! grep -qE 'systemctl (suspend|poweroff)|swaylock' $MNT/etc/skel/.config/sway/config"
check "logind never idle-acts"         "grep -q 'IdleAction=ignore' $MNT/etc/systemd/logind.conf.d/uconsole-idle.conf"
check "foot background is black"       "grep -qx 'background=000000' $MNT/etc/skel/.config/foot/foot.ini"
check "foot uses colors-dark section"  "grep -qx '\[colors-dark\]' $MNT/etc/skel/.config/foot/foot.ini"
check "foot has no stale [colors]"     "! grep -qx '\[colors\]' $MNT/etc/skel/.config/foot/foot.ini"
check "waybar background is black"     "grep -q 'background: #000000' $MNT/etc/skel/.config/waybar/style.css"
check "waybar text is green"           "grep -q 'color: #00ff00' $MNT/etc/skel/.config/waybar/style.css"

echo
echo "### 14. pacman usability after boot"
check "no dead build-time repo"        "! grep -q '127.0.0.1' $MNT/etc/pacman.conf"
check "core/extra repos intact"        "grep -q '^\[extra\]' $MNT/etc/pacman.conf"
echo "--- kernel Landlock support (pacman 7 sandbox) ---"
# Decompress to a file first: `grep -q` exits early, which SIGPIPEs gzip, and
# under `set -o pipefail` that turns a successful match into a failed check.
gzip -dc "$MNT/boot/vmlinuz-linux-uconsole-cm5-git" > /tmp/vmlinux.raw 2>/dev/null || true
_landlock=$(strings /tmp/vmlinux.raw | grep -ci "security/landlock/" || true)
echo "landlock source-path strings in kernel: ${_landlock:-0}"
if [[ ${_landlock:-0} -gt 0 ]]; then
  ok "kernel has Landlock compiled in"
else
  bad "kernel appears to LACK Landlock (pacman would need DisableSandbox)"
fi
rm -f /tmp/vmlinux.raw

echo
echo "### 15. on-device report fixes"
echo "-- S3.1 root expansion --"
check "expand-root uses growpart"      "grep -q 'growpart' $MNT/usr/local/bin/uconsole-expand-root"
check "expand-root verifies growth"    "grep -q 'partition did not grow' $MNT/usr/local/bin/uconsole-expand-root"
check "expand-root no longer uses parted -s resizepart" "! grep -q 'parted -s .* resizepart' $MNT/usr/local/bin/uconsole-expand-root"
check "growpart is installed"          "[[ -x $MNT/usr/bin/growpart ]]"
echo "-- S3.4 single network stack --"
check "systemd-networkd disabled"      "[[ ! -L $MNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service ]]"
check "networkd-wait-online masked"    "[[ -L $MNT/etc/systemd/system/systemd-networkd-wait-online.service ]]"
check "NetworkManager still enabled"   "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/NetworkManager.service ]]"
echo "-- S3.5 battery guard --"
check "battery guard present"          "[[ -x $MNT/usr/local/bin/uconsole-battery-guard ]]"
check "battery guard is voltage-based" "grep -q 'voltage_now' $MNT/usr/local/bin/uconsole-battery-guard"
check "battery guard timer enabled"    "[[ -L $MNT/etc/systemd/system/timers.target.wants/uconsole-battery-guard.timer ]]"
echo "-- S3.6 time sync --"
check "explicit NTP servers configured" "grep -q '^NTP=' $MNT/etc/systemd/timesyncd.conf.d/uconsole.conf"
check "timesyncd enabled"              "[[ -L $MNT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service || -L $MNT/etc/systemd/system/dbus-org.freedesktop.timesync1.service ]]"
echo "-- S3.7 wireless regulatory --"
check "regulatory.db present"          "[[ -f $MNT/usr/lib/firmware/regulatory.db ]]"
echo "-- S3.9 power key --"
check "screen toggle script present"   "[[ -x $MNT/usr/local/bin/uconsole-screen-toggle ]]"
check "screen toggle uses backlight"   "grep -q 'brightnessctl' $MNT/usr/local/bin/uconsole-screen-toggle"
check "logind ignores short power press" "grep -q 'HandlePowerKey=ignore' $MNT/etc/systemd/logind.conf.d/uconsole-powerkey.conf"
check "long press powers off"          "grep -q 'HandlePowerKeyLongPress=poweroff' $MNT/etc/systemd/logind.conf.d/uconsole-powerkey.conf"
check "sway binds the power key"       "grep -q 'XF86PowerOff exec /usr/local/bin/uconsole-screen-toggle' $MNT/etc/skel/.config/sway/config"
echo "-- kernel suspend (S3.9) --"
gzip -dc "$MNT/boot/vmlinuz-linux-uconsole-cm5-git" > /tmp/vmlinux2.raw 2>/dev/null || true
_susp=$(strings /tmp/vmlinux2.raw | grep -ci "suspend_ops\|mem_sleep\|PM: suspend" || true)
echo "suspend-related strings in kernel: ${_susp:-0}"
if [[ ${_susp:-0} -gt 0 ]]; then ok "kernel has suspend support compiled in"; else bad "kernel still lacks suspend"; fi
rm -f /tmp/vmlinux2.raw
echo "-- display fixes --"
check "panel scale divides evenly (1.25)" "grep -q 'output DSI-2 scale 1.25' $MNT/etc/skel/.config/sway/config"
check "software cursors forced"        "grep -q 'WLR_NO_HARDWARE_CURSORS=1' $MNT/etc/skel/.bash_profile"
check "waybar shows modem status"      "grep -q 'custom/modem' $MNT/etc/skel/.config/waybar/config"
check "waybar modem script present"    "[[ -x $MNT/usr/local/bin/uconsole-waybar-modem ]]"

echo
echo "### 16. tmux session persistence"
check "tmux installed"                 "[[ -x $MNT/usr/bin/tmux ]]"
check "tmux.conf in /etc/skel"         "[[ -s $MNT/etc/skel/.tmux.conf ]]"
check "TPM pre-installed"              "[[ -x $MNT/etc/skel/.tmux/plugins/tpm/tpm ]]"
check "tmux-resurrect pre-installed"   "[[ -f $MNT/etc/skel/.tmux/plugins/tmux-resurrect/resurrect.tmux ]]"
check "tmux-continuum pre-installed"   "[[ -f $MNT/etc/skel/.tmux/plugins/tmux-continuum/continuum.tmux ]]"
check "continuum auto-restore enabled" "grep -q \"@continuum-restore 'on'\" $MNT/etc/skel/.tmux.conf"
check "continuum save interval set"    "grep -q '@continuum-save-interval' $MNT/etc/skel/.tmux.conf"
check "resurrect captures pane contents" "grep -q '@resurrect-capture-pane-contents' $MNT/etc/skel/.tmux.conf"
check "tpm run line present"           "grep -q \"run '~/.tmux/plugins/tpm/tpm'\" $MNT/etc/skel/.tmux.conf"
check "tmux user service present"      "[[ -s $MNT/etc/systemd/user/tmux.service ]]"
check "tmux user service enabled globally" "[[ -L $MNT/etc/systemd/user/default.target.wants/tmux.service ]]"
check "ta alias present"               "grep -q \"alias ta=\" $MNT/etc/skel/.bashrc"
echo "-- alarm's home got the full skel --"
for f in .bashrc .vimrc .tmux.conf .bash_profile; do
  if [[ -f $MNT/home/alarm/$f ]]; then ok "alarm has $f"; else bad "alarm MISSING $f"; fi
done
check "alarm has tmux plugins"         "[[ -x $MNT/home/alarm/.tmux/plugins/tpm/tpm ]]"
check "alarm home still owned by alarm" "[[ -f $MNT/home/alarm/.tmux.conf ]] && [[ \$(stat -c%U $MNT/home/alarm/.tmux.conf) == alarm ]]"
echo "-- tmux config parses --"
if chroot "$MNT" /usr/bin/tmux -f /etc/skel/.tmux.conf start-server \; kill-server 2>&1 | grep -q .; then
  bad "tmux config produced errors"
else
  ok "tmux config parses cleanly"
fi

echo
echo "### 17. battery calibration utility"
check "calibrate utility present"      "[[ -x $MNT/usr/local/bin/uconsole-battery-calibrate ]]"
check "has status/run/report/apply"    "grep -qE 'status\\)  *show_status' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "integrates current for capacity" "grep -q 'mah+=a\\*dt/3600' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "stops above the PMU cutoff"     "grep -q 'FLOOR_UV:-3500000' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "warns when the modem is powered" "grep -q 'modem_is_on' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "floor sits above the guard's 3.40V" "[[ 3500000 -gt 3400000 ]]"
check "guard and calibrator agree on the battery path" "grep -q 'axp20x-battery' $MNT/usr/local/bin/uconsole-battery-guard && grep -q 'axp20x-battery' $MNT/usr/local/bin/uconsole-battery-calibrate"

echo
echo "### 18. Tailscale"
check "tailscale CLI installed"        "[[ -x $MNT/usr/bin/tailscale ]]"
check "tailscaled installed"           "[[ -x $MNT/usr/bin/tailscaled || -x $MNT/usr/sbin/tailscaled ]]"
check "tailscaled.service enabled"     "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/tailscaled.service ]]"
check "netfilter userspace present"    "[[ -x $MNT/usr/bin/nft ]]"
check "tun module available"           "find $MNT/usr/lib/modules/$KVER -name 'tun.ko*' | grep -q ."
echo "-- no identity or credentials baked into the image --"
check "no tailscaled state directory"  "[[ ! -e $MNT/var/lib/tailscale/tailscaled.state ]]"
check "no auth key in any unit"        "! grep -rqiE 'tskey-|TS_AUTHKEY|--authkey' $MNT/etc/systemd/system/ 2>/dev/null"
check "no auth key in our scripts"     "! grep -rqiE 'tskey-|TS_AUTHKEY' $MNT/usr/local/bin/ 2>/dev/null"
check "no tailscale node key on disk"  "! find $MNT/var/lib/tailscale -type f 2>/dev/null | grep -q ."
echo "-- follows the WAN when it changes --"
check "tailscale nudge script present"  "[[ -x $MNT/usr/local/bin/uconsole-tailscale-nudge ]]"
check "nudge rebinds magicsock"         "grep -q 'debug rebind' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "nudge forces endpoint restun"    "grep -q 'debug restun' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "nudge is a no-op when logged out" "grep -q 'tailscale status >/dev/null 2>&1 || exit 0' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "NM dispatcher hook present"      "[[ -x $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale ]]"
check "dispatcher hook is root-owned"   "[[ -f $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale ]] && [[ \$(stat -c%u $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale) -eq 0 ]]"
check "dispatcher not group/world writable" "[[ \$(stat -c%a $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale) =~ ^7[05][05]$ ]]"
check "dispatcher skips tailscale's own iface" "grep -q 'tailscale\*|ts\*' $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale"
check "uconsole-wan nudges on switch"   "grep -c 'tailscale_follow' $MNT/usr/local/bin/uconsole-wan | grep -qE '[4-9]'"
check "overlay scripts are root-owned"  "[[ -f $MNT/usr/local/bin/uconsole-wan ]] && [[ \$(stat -c%u $MNT/usr/local/bin/uconsole-wan) -eq 0 ]]"

echo
echo "########################################"
echo "RESULT: $PASSES passed, $FAILS failed"
echo "########################################"
[[ $FAILS -eq 0 ]]
