#!/usr/bin/env bash
set -Eeuo pipefail

IMG="${1:?usage: verify-image.sh IMAGE [runtime|dev]}"
PROFILE="${2:-runtime}"
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

# Search a binary for an exact string WITHOUT `grep -q`. `grep -q` exits on the
# first match, SIGPIPEs the upstream process, and `set -o pipefail` then reports
# the whole pipeline as failed -- a false negative that has bitten this suite
# three times now. `grep -c` drains its input, so nothing gets SIGPIPEd.
has_string() { [[ $(strings "$1" 2>/dev/null | grep -cx -- "$2" || true) -gt 0 ]]; }

# Create the /dev/loopNpM nodes that Docker Desktop never will.
#
# Its /dev is a plain tmpfs with no udev, so `losetup -P` registers the
# partitions with the kernel -- they appear in sysfs and fdisk lists them -- but
# no device nodes are created. Every partition check then fails with "Can't
# lookup blockdev" on an image that is perfectly fine, which is the worst kind of
# verification failure: alarming, and wrong.
#
# The image build solves this by wrapping partprobe. Verification cannot reuse
# that: it runs in its own fresh container, and the base image does not even ship
# parted -- the build pacman-installs it as its first step. So do the same work
# directly from sysfs, which needs nothing but coreutils.
#
# Nodes are always recreated, never skipped when present. Partition minors are
# allocated dynamically, so a node left over from an earlier losetup can point at
# the wrong device -- that surfaces much later as a confusing mount failure.
materialise_parts() {
    local dev="$1" base pdir pn devspec
    base="$(basename "$dev")"
    for pdir in /sys/block/"$base"/"$base"p*; do
        [[ -d $pdir && -r $pdir/dev ]] || continue
        pn="$(basename "$pdir")"
        devspec="$(cat "$pdir/dev")"
        rm -f "/dev/$pn"
        mknod "/dev/$pn" b "${devspec%%:*}" "${devspec##*:}" 2>/dev/null \
            && echo "  (created /dev/$pn -> $devspec)"
    done
}

echo "############ VERIFYING $IMG ############"
echo
echo "### 1. image file"
ls -la "$IMG"
# parted writes an MBR with no boot code, so file(1) does not recognise it as a
# "DOS/MBR boot sector"; read the partition table itself instead.
check "image carries a DOS/MBR partition table" "sfdisk -d '$IMG' 2>/dev/null | grep -q 'label: dos'"

echo
echo "### 2. partition table"
LOOP="$(losetup -Pf --show "$IMG")"; sleep 1; materialise_parts "$LOOP"
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
# `find | grep -q` is the documented SIGPIPE trap under `set -o pipefail`: grep
# exits on the first match, find dies writing to a closed pipe, and pipefail
# reports the whole pipeline as failed. It passes here only because these
# searches happen to return before grep exits -- i.e. by luck of output size.
# -quit makes find stop by itself, so nothing is ever SIGPIPEd.
check "brcmfmac wifi module present"         "[[ -n \$(find $MNT/usr/lib/modules/$KVER -name 'brcmfmac.ko*' -print -quit) ]]"
check "clockworkpi/panel DRM modules present" "[[ -n \$(find $MNT/usr/lib/modules/$KVER -name 'vc4.ko*' -print -quit) ]]"

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
# Autologin removed deliberately: the machine must require a login at boot.
# Runtime only. The dev image autologs in ON PURPOSE, and asserts that itself in
# the profile section -- so this cannot be an unconditional check without one
# profile or the other always failing.
if [[ $PROFILE == runtime ]]; then
    check "no tty1 autologin drop-in"   "[[ ! -e $MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf ]]"
fi
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
  if [[ -n $(find "$MNT/usr/lib/modules/$KVER" -name "$m.ko*" -print -quit 2>/dev/null) ]]; then ok "module: $m"; else bad "module MISSING: $m"; fi
done

echo
echo "### 12. first-boot account wizard"
check "firstboot script present"      "[[ -x $MNT/usr/local/bin/uconsole-firstboot-user ]]"
check "firstboot service present"     "[[ -s $MNT/etc/systemd/system/uconsole-firstboot-user.service ]]"
# Runtime only: the dev image pre-creates its account, so the wizard would prompt
# for one that already exists and is deliberately disabled there.
if [[ $PROFILE == runtime ]]; then
    check "firstboot service enabled" "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-firstboot-user.service ]]"
fi
check "firstboot runs before the getty" "grep -q 'Before=getty@tty1.service' $MNT/etc/systemd/system/uconsole-firstboot-user.service"
check "firstboot does not enable autologin" "! grep -q 'agetty --autologin' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot clears a stale autologin"  "grep -q 'rm -f \"\$DROPIN\"' $MNT/usr/local/bin/uconsole-firstboot-user"
# The wizard runs on its own VT: cmdline.txt sets console=tty1, so tty1 gets
# every printk no matter how quiet we ask the kernel to be.
check "firstboot runs on its own VT"   "grep -q 'TTYPath=/dev/tty7' $MNT/etc/systemd/system/uconsole-firstboot-user.service"
check "firstboot switches to that VT"  "grep -q 'chvt \"\$WIZARD_VT\"' $MNT/usr/local/bin/uconsole-firstboot-user"
check "firstboot switches back on exit" "grep -q 'chvt \"\${SAVED_VT:-1}\"' $MNT/usr/local/bin/uconsole-firstboot-user"
check "chvt available"                 "[[ -x $MNT/usr/bin/chvt ]]"
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
# Comment lines are excluded: the config now *explains* swaylock in a comment,
# and an earlier version of this check matched that prose rather than a setting.
# grep -c (not -q) so a large file cannot SIGPIPE the upstream grep under pipefail.
check "idle itself does not lock or power off" "[[ \$(grep -vE '^[[:space:]]*#' $MNT/etc/skel/.config/sway/config | grep -cE 'systemctl (suspend|poweroff)|swaylock' || true) -eq 0 ]]"
check "logind never idle-acts"         "grep -q 'IdleAction=ignore' $MNT/etc/systemd/logind.conf.d/uconsole-idle.conf"
check "foot background is black"       "grep -qx 'background=000000' $MNT/etc/skel/.config/foot/foot.ini"
check "foot uses colors-dark section"  "grep -qx '\[colors-dark\]' $MNT/etc/skel/.config/foot/foot.ini"
check "foot has no stale [colors]"     "! grep -qx '\[colors\]' $MNT/etc/skel/.config/foot/foot.ini"
check "waybar background is black"     "grep -q 'background: #000000' $MNT/etc/skel/.config/waybar/style.css"
check "waybar text is green"           "grep -q 'color: #00ff00' $MNT/etc/skel/.config/waybar/style.css"
echo "-- waybar system monitors --"
# The CM5 is BCM2712, but its device tree declares brcm,bcm2711-thermal for the
# AVS block, so bcm2711_thermal binds and cpu-thermal is the only zone (0).
check "waybar shows CPU temperature"   "grep -q '\"temperature\"' $MNT/etc/skel/.config/waybar/config"
check "temperature reads thermal zone 0" "grep -q '\"thermal-zone\": 0' $MNT/etc/skel/.config/waybar/config"
check "temperature has a critical threshold" "grep -q 'critical-threshold' $MNT/etc/skel/.config/waybar/config"
check "waybar shows RAM usage"         "grep -q '\"memory\"' $MNT/etc/skel/.config/waybar/config"
check "memory has warning states"      "grep -q '\"warning\": 80' $MNT/etc/skel/.config/waybar/config"
check "both are in modules-right"      "grep -q '\"temperature\",' $MNT/etc/skel/.config/waybar/config && grep -q '\"memory\",' $MNT/etc/skel/.config/waybar/config"
check "waybar has temperature compiled in" "has_string $MNT/usr/bin/waybar temperature"
check "waybar has memory compiled in"  "has_string $MNT/usr/bin/waybar memory"
check "thermal driver present in kernel" "grep -q 'bcm2711_thermal' $MNT/usr/lib/modules/$KVER/modules.builtin"
# Parsed with the IMAGE's python3, not the host's. The base container ships no
# python at all, so a host-side `python3 -c ...` here does not report "invalid
# JSON" -- it reports "command not found" as a failed check, which reads as a
# broken image when the image is fine.
check "waybar config is valid JSON"    "chroot $MNT /usr/bin/python3 -c \"import json;json.load(open('/etc/skel/.config/waybar/config'))\""
check "temperature styled in css"      "grep -q '#temperature' $MNT/etc/skel/.config/waybar/style.css"

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
check "sway binds the power key"       "grep -q 'XF86PowerOff exec /usr/local/bin/uconsole-powerkey-hold' $MNT/etc/skel/.config/sway/config"
# Two bindings, press and release, so the hold can be timed. logind's long-press
# is a hardcoded 5s with no setting in any systemd version (systemd#28100), and
# the AXP223 offers only 4/6/8/10s and is parked at 10s so it never beats a clean
# shutdown -- so measuring here is the only way to get a shorter one.
check "power key press binding"        "grep -q 'XF86PowerOff exec /usr/local/bin/uconsole-powerkey-hold press' $MNT/etc/skel/.config/sway/config"
check "power key release binding"      "grep -q 'XF86PowerOff exec /usr/local/bin/uconsole-powerkey-hold release' $MNT/etc/skel/.config/sway/config"
check "powerkey hold script present"   "[[ -x $MNT/usr/local/bin/uconsole-powerkey-hold ]]"
check "powerkey hold script parses"    "bash -n $MNT/usr/local/bin/uconsole-powerkey-hold"
# THE safety property. The timer must not trust the release event: when it fires
# it asks the kernel whether the key is still physically held, so a tap cannot
# power the machine off even if the release binding is missed entirely.
check "hold timer re-checks the key"   "grep -q 'evtest --query' $MNT/usr/local/bin/uconsole-powerkey-hold"
check "hold fires only when still down" "grep -q 'eq 10 \]\] || exit 0' $MNT/usr/local/bin/uconsole-powerkey-hold"
# The INPUT device is axp20x-pek while the platform device is axp221-pek, so a
# pattern like axp[0-9]*-pek matches nothing -- and an empty result makes press()
# a no-op that looks exactly like a safety pass. It did, until testing caught it.
check "power key found by name"        "grep -q 'name ~ /-pek\"/' $MNT/usr/local/bin/uconsole-powerkey-hold"
check "hold threshold is configurable" "grep -qE '^POWERKEY_HOLD_MS=[0-9]+$' $MNT/etc/uconsole/lowpower.conf"
# evtest is what makes the timer safe; without it the guard cannot run at all.
check "evtest installed for the guard" "[[ -x $MNT/usr/bin/evtest ]]"
# Without --locked sway refuses to run a binding while a locker is active, so the
# power key would stop working the instant swaylock started -- no way back from
# a blanked screen.
check "power key works while locked"   "grep -q 'bindsym --no-repeat --release --locked XF86PowerOff' $MNT/etc/skel/.config/sway/config"
check "brightness keys work while locked" "[[ \$(grep -c 'bindsym --locked XF86' $MNT/etc/skel/.config/sway/config) -ge 5 ]]"
# Without --no-repeat the binding fires at the 30/s repeat rate while held, which
# strobes the backlight for the whole length of a long press.
# Match the flags independently of their order, so adding another one later does
# not silently break the check.
check "power key binding does not repeat" "grep -qE '^bindsym .*--no-repeat.*XF86PowerOff' $MNT/etc/skel/.config/sway/config"
check "power key fires on release"        "grep -qE '^bindsym .*--release.*XF86PowerOff' $MNT/etc/skel/.config/sway/config"
check "powerkey tuner present"         "[[ -x $MNT/usr/local/bin/uconsole-powerkey-tune ]]"
check "powerkey tuner enabled"         "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-powerkey-tune.service ]]"
check "tuner shortens press detection" "grep -q 'set_first_accepted \"\$f\" 128' $MNT/usr/local/bin/uconsole-powerkey-tune"
check "tuner defers the hardware cut"  "grep -q 'set_first_accepted \"\$f\" 10000' $MNT/usr/local/bin/uconsole-powerkey-tune"
echo "-- suspend is a hazard, not a feature (S3.9) --"
# The kernel still has suspend compiled in, and that is fine -- what matters is
# that nothing can REACH it. Both registered states hang this machine: `deep` is
# a PSCI firmware stub and `s2idle` wedges the SDIO Wi-Fi chip beyond what a
# module reload can recover. So these checks assert the locks, not the feature.
for t in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
    check "${t}.target masked" "[[ \$(readlink $MNT/etc/systemd/system/${t}.target) == /dev/null ]]"
done
# Defence in depth for anything writing /sys/power/state directly and bypassing
# systemd -- exactly what rtcwake does. mem_sleep resets to `deep` every boot,
# so without this a bare `echo mem` always takes the firmware-stub path.
check "mem_sleep pinned to s2idle"     "grep -q 'mem_sleep_default=s2idle' $MNT/boot/cmdline.txt"
# systemd-rfkill would carry a low-power radio block across a reboot, so a crash
# while blanked would come up with no radios and no SSH to fix it.
check "systemd-rfkill masked"          "[[ \$(readlink $MNT/etc/systemd/system/systemd-rfkill.service) == /dev/null ]]"
check "rfkill socket masked"           "[[ \$(readlink $MNT/etc/systemd/system/systemd-rfkill.socket) == /dev/null ]]"
check "radio restore present"          "[[ -x $MNT/usr/local/bin/uconsole-radio-restore ]]"
check "radio restore enabled"          "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-radio-restore.service ]]"
# The stale "kernel registers no sleep states" comment is what invited five
# suspend attempts: a reader checks sysfs, sees two states, and concludes the
# warning is obsolete. Assert it is gone everywhere it was written down.
for f in "$MNT/etc/skel/.config/sway/config" "$MNT/etc/systemd/logind.conf.d/uconsole-powerkey.conf"; do
    # Match on 'no sleep states' alone, not the full sentence: the original
    # wording line-wrapped between 'sleep' and 'states', so a stricter pattern
    # passes by luck rather than because the claim is gone.
    check "no stale 'no sleep states' claim in $(basename "$f")" \
          "[[ \$(tr '\n' ' ' < $f | tr -s ' ' | grep -c 'no sleep states' || true) -eq 0 ]]"
done
# Recovery from a blank must not depend on the network, because the low-power
# blank is what switches the network off.
check "VT recovery tool present"       "[[ -x $MNT/usr/local/bin/uconsole-unstick ]]"

echo "-- OTA reflash: initramfs hook, arming tool, cleanup --"
# This code runs on EVERY boot, before the real root is used. A fault here does
# not break an update, it breaks the machine -- on a device whose panel already
# fails silently on cold boot, so a black screen will not say which fault it is.
# These checks exist to keep the hook incapable of doing harm.
check "recovery script present"        "[[ -x $MNT/usr/local/bin/uconsole-ota-recovery ]]"
check "recovery script parses"         "sh -n $MNT/usr/local/bin/uconsole-ota-recovery"
# `set -e` would turn any unexpected failure into an early exit mid-way through,
# which is the one thing this script must never do -- it has to reach its exit 0.
check "recovery script does not set -e" "[[ \$(grep -cE '^set .*-[a-z]*e' $MNT/usr/local/bin/uconsole-ota-recovery) -eq 0 ]]"
check "recovery script always exits 0" "[[ \$(grep -c 'exit 0' $MNT/usr/local/bin/uconsole-ota-recovery) -ge 3 ]]"
# The write is gated on the marker saying MODE=write, and every other value --
# including a marker written before the field existed -- takes the identical path
# with the output going to /dev/null. These three checks are that gate: that the
# safe destination is the default, that the card is only ever the target inside
# the gate, and that the image is never repartitioned (it carries its own table).
check "dry run is the default"         "grep -q 'TARGET=/dev/null' $MNT/usr/local/bin/uconsole-ota-recovery"
check "write is gated on MODE=write"   "grep -qE '^if \\[ \"\\\$OTA_MODE\" = \"write\" \\]' $MNT/usr/local/bin/uconsole-ota-recovery"
check "hook repartitions nothing"      "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-ota-recovery | grep -cE '\\b(mkfs|sfdisk|parted)\\b') -eq 0 ]]"
# Writing an unverified image is worse than not updating: it replaces a working
# system with an unbootable one and the only recovery is physical.
check "write refuses without a hash"   "grep -q 'MODE=write but carries no SHA256' $MNT/usr/local/bin/uconsole-ota-recovery"
check "write refuses on low battery"   "grep -q 'battery_ok' $MNT/usr/local/bin/uconsole-ota-recovery"
# On this PMIC the battery supply reports online=1 whenever a battery is fitted,
# and the first version of both guards read that as "on AC" -- so the charge was
# never checked. AC must be found by supply type. Code lines only (grep -c, not
# -q, so pipefail cannot turn an early exit into a false failure): the comments
# explaining the rule must not be what satisfies it.
for f in uconsole-ota uconsole-ota-recovery; do
    check "$f finds AC by supply type"  "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/$f | grep -c 'Mains') -ge 1 ]]"
    # Voltage, never the gauge -- the rule uconsole-battery-guard already follows.
    check "$f gates on voltage"         "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/$f | grep -c 'MIN_BATTERY_UV') -ge 2 ]]"
done
# gzip failing mid-stream while dd reports success would write a truncated image.
# /bin/sh in an initramfs has no pipefail, hence the flag file.
check "hook detects a gzip failure"    "grep -q 'gz.failed' $MNT/usr/local/bin/uconsole-ota-recovery"
# dd can report success with gigabytes still in the page cache, and the reboot
# straight afterwards would cut them off.
check "write is flushed before reboot" "grep -q 'DD_CONV=conv=fsync' $MNT/usr/local/bin/uconsole-ota-recovery"
# Both mounts of the card -- the vfat boot partition and the ext4 root -- are taken
# read-only, so even a logic error cannot modify what is on it.
check "hook mounts read-only"          "[[ \$(grep -c 'mount -o ro' $MNT/usr/local/bin/uconsole-ota-recovery) -ge 2 ]]"
# The marker is a data file read off the card. Sourcing it would turn one bad line
# into a command running as root in early userspace.
check "hook does not source marker"    "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-ota-recovery | grep -cE '^[[:space:]]*(\\.|source)[[:space:]]') -eq 0 ]]"
# Cleanup on SIGTERM matters because the timeout is how a hang ends: without it a
# killed run would leave the root mounted from the initramfs into the real system.
check "hook cleans up when killed"     "grep -q 'trap .*INT TERM' $MNT/usr/local/bin/uconsole-ota-recovery"
# The interlock that stops the unit ever running on the real system.
check "unit is initramfs-only"         "grep -q 'ConditionPathExists=/etc/initrd-release' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
# Naming sysroot.mount is the part that actually orders this ahead of the root
# being mounted: systemd-fstab-generator gives that unit Before=initrd-root-fs.target
# too, so sharing only the target leaves the two unordered against each other.
check "unit runs before the real root" "grep -qE '^Before=.*sysroot\\.mount' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
check "unit runs before the fs target" "grep -qE '^Before=.*initrd-root-fs\\.target' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
# Nothing may Require it, or a failure would fail the boot instead of being logged.
check "unit has a hang timeout"        "grep -q 'TimeoutStartSec=' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
# And not a short one: a timeout that fires mid-write kills the write and lets the
# boot carry on onto a half-written card. 300s was enough for the test card and
# far too little for a class-10 one, so hold it at 20 minutes or more.
check "timeout outlasts a slow write"  "grep -qE '^TimeoutStartSec=([2-9][0-9]|[1-9][0-9]{2,})min\$' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
# Measured on hardware: a Type=oneshot without this ran the hook twice per boot,
# because finishing returns it to inactive and a second pull-in restarts it.
check "unit cannot re-run in a boot"   "grep -q '^RemainAfterExit=yes' $MNT/usr/lib/systemd/system/uconsole-ota-recovery.service"
check "script has its own run-once guard" "grep -q '/run/uconsole-ota.ran' $MNT/usr/local/bin/uconsole-ota-recovery"
check "mkinitcpio hook installed"      "[[ -x $MNT/etc/initcpio/install/uconsole-ota ]]"
check "hook listed in HOOKS"           "grep -qE '^HOOKS=.*uconsole-ota' $MNT/etc/mkinitcpio.conf"
# The hook being present is not the same as it having run: an install hook that
# is not listed in HOOKS is a silent no-op, so assert the built artefact.
for f in usr/local/bin/uconsole-ota-recovery usr/lib/systemd/system/uconsole-ota-recovery.service usr/lib/systemd/system/initrd-root-fs.target.wants/uconsole-ota-recovery.service; do
    # ${f##*/system/}, not basename: the unit and its .wants symlink share a name,
    # and two identical labels hide which of the two is actually missing.
    check "initramfs carries ${f##*/system/}" \
          "chroot $MNT /usr/bin/lsinitcpio /boot/initramfs-linux-uconsole-cm5-git.img 2>/dev/null | grep -qx '$f'"
done

check "arming tool present"            "[[ -x $MNT/usr/local/bin/uconsole-ota ]]"
check "arming tool parses"             "bash -n $MNT/usr/local/bin/uconsole-ota"
# The split that makes this safe: the userspace side only ever stages a file and
# writes a marker. Every block-device verb lives in the initramfs script, where
# the root is unmounted first.
check "arming tool touches no device"  "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-ota | grep -cE '\\b(dd|mkfs|sfdisk|parted)\\b') -eq 0 ]]"
# Arming the real write is the one irreversible act on this side.
check "flash refuses without power"    "grep -q 'refusing to arm' $MNT/usr/local/bin/uconsole-ota"
check "flash needs typed confirmation" "grep -q 'Type FLASH to confirm' $MNT/usr/local/bin/uconsole-ota"
# The loop-breaker. Without it a failed update re-stages on every boot and fires
# an unattended write the moment the battery guard stops refusing.
check "stale-marker cleanup present"   "[[ -x $MNT/usr/local/bin/uconsole-ota-cleanup ]]"
check "stale-marker cleanup parses"    "sh -n $MNT/usr/local/bin/uconsole-ota-cleanup"
check "cleanup enabled"                "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-ota-cleanup.service ]]"
# The mirror of the recovery unit's interlock: that one only in the initramfs,
# this one only on the real system.
check "cleanup is real-system-only"    "grep -q 'ConditionPathExists=!/etc/initrd-release' $MNT/usr/lib/systemd/system/uconsole-ota-cleanup.service"

echo "-- low-power blank (Stage 1) --"
check "lowpower policy ships"          "[[ -f $MNT/etc/uconsole/lowpower.conf ]]"
check "lowpower policy parses"         "bash -n $MNT/etc/uconsole/lowpower.conf"
check "lowpower helper present"        "[[ -x $MNT/usr/local/bin/uconsole-lowpower ]]"
check "lowpower helper parses"         "bash -n $MNT/usr/local/bin/uconsole-lowpower"
# A second descent used to truncate the state file and record the ALREADY-CLAMPED
# values as "pre-blank", so `up` restored the clamp and the machine sat at 62% of
# its clock in the powersave governor until reboot. Two power-key presses in
# quick succession were enough. Same shape as the audio-mute latch.
check "descent does not re-record state" "grep -q 'ALREADY_DOWN=1' $MNT/usr/local/bin/uconsole-lowpower"
check "save() honours the already-down guard" \
      "grep -q '(( ALREADY_DOWN )) && return 0' $MNT/usr/local/bin/uconsole-lowpower"
check "state file is not truncated unconditionally" \
      "[[ \$(grep -c '^    : > \"\$STATE\"' $MNT/usr/local/bin/uconsole-lowpower) -eq 0 ]]"
# Belt and braces: a saved ceiling equal to the floor is a stale clamp, never a
# preference, and restoring it strands the machine at minimum clock.
check "wake rejects a floor-valued ceiling" \
      "grep -q 'stale clamp, restoring hardware max' $MNT/usr/local/bin/uconsole-lowpower"
# sudo IGNORES a drop-in that is not root-owned and 0440, warning only to syslog.
# The symptom is a key binding that quietly stops saving power, so assert both.
check "sudoers drop-in ships"          "[[ -f $MNT/etc/sudoers.d/uconsole-lowpower ]]"
check "sudoers drop-in is 0440"        "[[ \$(stat -c%a $MNT/etc/sudoers.d/uconsole-lowpower) == 440 ]]"
check "sudoers drop-in is root-owned"  "[[ -f $MNT/etc/sudoers.d/uconsole-lowpower && \$(stat -c%u:%g $MNT/etc/sudoers.d/uconsole-lowpower) == 0:0 ]]"
check "sudoers drop-in parses"         "chroot $MNT /usr/bin/visudo -c -f /etc/sudoers.d/uconsole-lowpower"
# Scoped to one binary: no shell, no systemctl, no wildcard.
check "sudoers grants only the helper" "[[ \$(grep -c 'NOPASSWD: /usr/local/bin/uconsole-lowpower$' $MNT/etc/sudoers.d/uconsole-lowpower) -eq 1 ]]"
check "toggle calls lowpower down"     "grep -q 'lowpower down' $MNT/usr/local/bin/uconsole-screen-toggle"
# The sudoers rule grants NOPASSWD for uconsole-lowpower and NOTHING ELSE, so
# probing with any other command ("sudo -n true") gets "a password is required"
# and silently skips the whole descent -- on a machine whose screen is off, so
# it looks like it worked. Never probe with a different command than you run.
# Comment lines are excluded deliberately: both scripts DESCRIBE this bug in
# their headers so it does not get reintroduced, and a naive grep matches the
# explanation as readily as the defect. Same trap as the gpiochip0 check.
check "toggle does not probe sudo -n true" "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-screen-toggle | grep -c 'sudo -n true') -eq 0 ]]"
check "toggle invokes the helper directly" "grep -q 'sudo -n /usr/local/bin/uconsole-lowpower' $MNT/usr/local/bin/uconsole-screen-toggle"
check "unstick does not probe sudo -n true" "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-unstick | grep -c 'sudo -n true') -eq 0 ]]"
check "unstick delegates to the helper" "grep -q 'uconsole-lowpower up' $MNT/usr/local/bin/uconsole-unstick"
# A descent that silently fails to engage is indistinguishable, in watts alone,
# from one that engaged and had nothing to give. The probe must record state.
check "probe records power state"      "grep -q '_NPROCESSORS_ONLN' $MNT/usr/local/bin/uconsole-power-probe"
check "probe flags a skipped descent"  "grep -q 'DID NOT ENGAGE' $MNT/usr/local/bin/uconsole-power-probe"
# The wake path is where the risk lives. A descent that half-failed must still
# come back to a usable machine, so every one of these has to be on the way up.
check "wake restores lowpower state"   "grep -q 'lowpower up' $MNT/usr/local/bin/uconsole-screen-toggle"
check "wake restores mute state"       "grep -q 'set-mute @DEFAULT_AUDIO_SINK@ 0' $MNT/usr/local/bin/uconsole-screen-toggle"
check "lowpower up restores cores"     "grep -q 'brought .* core' $MNT/usr/local/bin/uconsole-lowpower"
check "lowpower up unblocks radios"    "grep -q 'rfkill unblock wifi bluetooth' $MNT/usr/local/bin/uconsole-lowpower"
# Written BEFORE the block, so a machine that dies mid-descent still comes back
# with radios rather than stranded with no network and no explanation.
check "radio stamp set before block"   "[[ \$(grep -n 'touch \"\$STAMP\"' $MNT/usr/local/bin/uconsole-lowpower | cut -d: -f1) -lt \$(grep -n 'rfkill block' $MNT/usr/local/bin/uconsole-lowpower | cut -d: -f1) ]]"
# cpu0 must never be offlined -- the glob is cpu[1-9]*, not cpu*.
check "core offlining spares cpu0"     "[[ \$(grep -c 'cpu\[1-9\]\*/online' $MNT/usr/local/bin/uconsole-lowpower) -ge 2 ]]"
# Offlining is ONE-WAY on this board: bring-up fails with EINVAL and only a
# reboot recovers. Shipping this on by default cripples the machine after the
# first blank, silently, because the write on the way down reports success.
check "core parking off by default"    "grep -q '^CPU_OFFLINE_CORES_ON_BLANK=0' $MNT/etc/uconsole/lowpower.conf"
# The panel power-down, and more importantly its restore. The ORDER of those two
# sway commands IS the fix -- each alone restored 0/3 cycles and the pair 3/3 --
# so pin both, and pin that IPC is tried before the VT bounce, which is the path
# that used to strand the session on a dead VT.
check "panel power-down on by default" "grep -q '^PANEL_OFF_ON_BLANK=1' $MNT/etc/uconsole/lowpower.conf"
check "panel restore uses sway IPC"    "grep -qF 'panel_on_ipc' $MNT/usr/local/bin/uconsole-screen-toggle"
check "panel restore sends power on"   "grep -qF 'output \"\$out\" power on' $MNT/usr/local/bin/uconsole-screen-toggle"
check "panel restore then sends enable" "grep -qF 'output \"\$out\" enable' $MNT/usr/local/bin/uconsole-screen-toggle"
check "panel state read from DRM"      "grep -qF 'card*-DSI-*' $MNT/usr/local/bin/uconsole-screen-toggle"
check "restore path is logged"         "grep -qF 'panel restored by \${_how' $MNT/usr/local/bin/uconsole-screen-toggle"
check "root panel-on tries IPC first"  "grep -qF 'panel_on_ipc_as_user && return 0' $MNT/usr/local/bin/uconsole-lowpower"
check "core bring-up is verified"      "grep -q 'stayed offline after writing 1' $MNT/usr/local/bin/uconsole-lowpower"
check "hotplug selftest present"       "grep -q 'selftest-cores' $MNT/usr/local/bin/uconsole-lowpower"

# The measurement tool behind every number above.
check "power budget tool present"      "[[ -x $MNT/usr/local/bin/uconsole-power-budget ]]"
check "power budget parses"            "bash -n $MNT/usr/local/bin/uconsole-power-budget"
# A/B/A, not A/B: the pack is discharging while we measure, and a single pair
# charges that drift to whichever subsystem happened to be under test.
check "budget brackets B between two A" \
      "grep -qF 'a1 + a2' $MNT/usr/local/bin/uconsole-power-budget"
check "budget refuses on AC"           "grep -qF 'on AC -- unplug' $MNT/usr/local/bin/uconsole-power-budget"
check "budget skips missing helpers"   "grep -qF 'which is not installed' $MNT/usr/local/bin/uconsole-power-budget"
# libgpiod v2's gpioset holds its line until killed. Without -t 0 the audio-amp
# row never returned, and without a deadline on every step nothing said so.
check "budget gpioset sets and exits"  "grep -qF 'gpioset -t 0' $MNT/usr/local/bin/uconsole-power-budget"
check "budget bounds every step"       "[[ \$(grep -vE '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-power-budget | grep -cF 'run_bounded \"\$') -eq 2 ]]"
# Modem presence is the only direct evidence MODEM_OFF_ON_BLANK actually worked.
# A QMI raw_ip netdev reports operstate "unknown" whether the radio is on or
# off, so it can never show the transition. Read ModemManager's power state --
# once per phase, because mmcli is far too heavy to run per sample.
check "probe records modem state"      "grep -q 'modem_state()' $MNT/usr/local/bin/uconsole-power-probe"
check "probe reads MM power state"     "grep -q 'power state' $MNT/usr/local/bin/uconsole-power-probe"
check "probe caches modem state per phase" "grep -q 'PHASE_MODEM=\$(modem_state)' $MNT/usr/local/bin/uconsole-power-probe"
check "probe does not use operstate proxy" "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-power-probe | grep -c 'operstate') -eq 0 ]]"
# Releasing the GPIO rail is not a power-down sequence -- the module stayed
# enumerated and nothing checked. The radio goes to sleep via ModemManager.
check "modem uses MM low-power state"  "grep -q 'set-power-state-low' $MNT/usr/local/bin/uconsole-lowpower"
check "modem power-down is verified"   "grep -q \"wanted 'low'\" $MNT/usr/local/bin/uconsole-lowpower"
check "modem rail cut is opt-in"       "grep -q '^MODEM_RAIL_OFF_ON_BLANK=0' $MNT/etc/uconsole/lowpower.conf"
# Saving the PRIOR mute state latches: once anything leaves the sink muted, every
# later cycle faithfully re-mutes it. Record our own action instead.
check "mute records our own action"    "grep -q 'we are muting' $MNT/usr/local/bin/uconsole-screen-toggle"
check "missing mute state means unmute" "grep -q 'cat \"\$MUTESTATE\" 2>/dev/null || echo 1' $MNT/usr/local/bin/uconsole-screen-toggle"
check "no grep -q on the mute probe"   "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-screen-toggle | grep -c 'grep -q MUTED') -eq 0 ]]"
check "unstick unmutes"                "grep -q 'set-mute @DEFAULT_AUDIO_SINK@ 0' $MNT/usr/local/bin/uconsole-unstick"
# The wake has to give the screen back at the SAME brightness, not merely a
# non-zero one -- on a 0-9 panel, 1 vs 5 is unreadable vs usable.
check "probe samples the backlight"    "grep -q 'BLMAX' $MNT/usr/local/bin/uconsole-power-probe"
check "probe checks backlight on wake" "grep -q 'matching before the blank' $MNT/usr/local/bin/uconsole-power-probe"
check "probe checks mute on wake"      "grep -q 'audio mute state unchanged' $MNT/usr/local/bin/uconsole-power-probe"
check "probe default run is short"     "grep -q 'local base_s=60 blank_s=60' $MNT/usr/local/bin/uconsole-power-probe"
check "modem policy is set"            "grep -qE '^MODEM_OFF_ON_BLANK=[01]$' $MNT/etc/uconsole/lowpower.conf"
# Cycling the modem on every blank makes these load-bearing rather than nice to
# have: the reconnect must be backgrounded (the 180s unit timeout must never
# block a wake) and the routing mode must be re-applied, because tearing the
# bearer down drops whatever `uconsole-wan lte|auto` the user had selected.
# The modem wake MUST NOT be a background subshell. uconsole-lowpower runs under
# `sudo -n` from a key binding, and sudo 1.9.14+ runs commands in a pty and kills
# what is left in that session on exit -- so `( ... ) &` was reaped every time,
# leaving the radio in low power after every wake while everything synchronous
# restored correctly. A transient systemd unit is not reaped.
check "modem wake helper present"      "[[ -x $MNT/usr/local/bin/uconsole-modem-wake ]]"
check "modem wake helper parses"       "bash -n $MNT/usr/local/bin/uconsole-modem-wake"
check "wake uses a transient unit"     "grep -q 'systemd-run --unit=uconsole-modem-wake' $MNT/usr/local/bin/uconsole-lowpower"
check "wake is not a background subshell" "[[ \$(grep -c ') &\$' $MNT/usr/local/bin/uconsole-lowpower) -le 1 ]]"
check "modem wake verifies power state" "grep -q 'stuck in power state' $MNT/usr/local/bin/uconsole-modem-wake"
check "modem wake retries"             "grep -q 'attempt \$attempt' $MNT/usr/local/bin/uconsole-modem-wake"
check "modem wake reconnects bearer"   "grep -q 'systemctl restart uconsole-modem-connect.service' $MNT/usr/local/bin/uconsole-modem-wake"
# Restoring POWER state does not ENABLE the modem. A modem left "disabled" never
# searches and never registers, so uconsole-modem-connect burns its full 90s
# wait and exits 2 -- reported only as "failed to start".
check "modem wake enables the modem"   "grep -q 'mmcli -m \"\$IDX\" --enable' $MNT/usr/local/bin/uconsole-modem-wake"
check "modem wake waits for registration" "grep -q 'registered|connected' $MNT/usr/local/bin/uconsole-modem-wake"
check "modem wake reports why it failed" "grep -q 'systemctl status --no-pager' $MNT/usr/local/bin/uconsole-modem-wake"
# mmcli prints both "state:" and "power state:", so line-oriented scraping picks
# whichever comes first. Parse the JSON instead.
check "modem wake parses mmcli JSON"   "grep -q 'mmcli -m \"\$1\" -J' $MNT/usr/local/bin/uconsole-modem-wake"
# Under systemd-run stdout is captured into the journal, so an unguarded printf
# alongside logger writes every line twice.
check "modem wake does not double-log" "grep -q '\[\[ -t 1 \]\] && printf' $MNT/usr/local/bin/uconsole-modem-wake"
check "wake restores WAN mode"         "grep -q 'wan mode restored' $MNT/usr/local/bin/uconsole-modem-wake"
check "unstick uses the transient unit" "grep -q 'systemd-run --unit=uconsole-modem-wake' $MNT/usr/local/bin/uconsole-unstick"
check "uconsole-wan persists its mode" "grep -q 'MODE_FILE=/var/lib/uconsole/wan-mode' $MNT/usr/local/bin/uconsole-wan"
check "wan mode saved for all 3 modes" "[[ \$(grep -c '^    save_mode ' $MNT/usr/local/bin/uconsole-wan) -eq 3 ]]"

echo "-- session restore (Stage 2) --"
check "session snapshot present"       "[[ -x $MNT/usr/local/bin/uconsole-session-snapshot ]]"
check "session restore present"        "[[ -x $MNT/usr/local/bin/uconsole-session-restore ]]"
# Parsed with the IMAGE's python3, not the host's -- the base container has no
# python at all, so a host-side check reports "command not found" as a failure.
#
# ast.parse, NOT py_compile: py_compile WRITES __pycache__ next to the source, so
# verifying the image would leave build artifacts inside /usr/local/bin on the
# card it is meant to be checking. Verification must not modify what it verifies.
check "session snapshot parses"        "chroot $MNT /usr/bin/python3 -c \"import ast;ast.parse(open('/usr/local/bin/uconsole-session-snapshot').read())\""
check "session restore parses"         "chroot $MNT /usr/bin/python3 -c \"import ast;ast.parse(open('/usr/local/bin/uconsole-session-restore').read())\""
check "no python bytecode in the image" "[[ -z \$(find $MNT/usr/local/bin $MNT/etc -name '__pycache__' -o -name '*.pyc' 2>/dev/null | head -1) ]]"
check "sway starts the restore"        "grep -q 'exec /usr/local/bin/uconsole-session-restore' $MNT/etc/skel/.config/sway/config"
check "sway starts the snapshotter"    "grep -q 'exec /usr/local/bin/uconsole-session-snapshot' $MNT/etc/skel/.config/sway/config"
# Order matters: the restore takes a lock the snapshotter honours. Reversed, the
# snapshotter can capture the half-restored desktop and overwrite the file being
# restored from -- destroying the session while appearing to work.
check "restore is exec'd before snapshot" \
      "[[ \$(grep -n 'uconsole-session-restore' $MNT/etc/skel/.config/sway/config | head -1 | cut -d: -f1) -lt \$(grep -n 'uconsole-session-snapshot' $MNT/etc/skel/.config/sway/config | head -1 | cut -d: -f1) ]]"
check "snapshotter honours the lock"   "grep -q 'os.path.exists(LOCK)' $MNT/usr/local/bin/uconsole-session-snapshot"
check "restore takes the lock"         "grep -q 'O_CREAT | os.O_EXCL' $MNT/usr/local/bin/uconsole-session-restore"
# A restore killed before its `finally` runs used to leave the lock behind, and
# the snapshotter skips writing whenever it exists -- a session that silently
# stopped recording, and a next boot with nothing to restore from.
check "restore reclaims a stale lock"  "grep -q 'clearing a stale restore lock' $MNT/usr/local/bin/uconsole-session-restore"
# Otherwise an uninstalled app costs the full window timeout, per app, at login.
check "restore skips missing apps"     "grep -q 'is gone; skipping' $MNT/usr/local/bin/uconsole-session-restore"
# The boot id is what distinguishes a resume from an ordinary re-login. Without
# it a logout and login would duplicate every window.
check "restore is gated on boot id"    "grep -q 'snap.get(\"boot_id\") == now_boot' $MNT/usr/local/bin/uconsole-session-restore"
check "snapshot stamps the boot id"    "grep -q '\"boot_id\": boot_id()' $MNT/usr/local/bin/uconsole-session-snapshot"
# for_window makes EVERY window fullscreen, so the work is removing it from the
# ones that were not. Applying it would be a no-op and leave the rest wrong.
check "restore clears unwanted fullscreen" "grep -q 'fullscreen disable' $MNT/usr/local/bin/uconsole-session-restore"
# Switch workspace, then launch. Moving an already-fullscreen container between
# workspaces leaves two competing on the destination.
check "restore switches workspace first" "grep -q 'Switch workspace BEFORE launching' $MNT/usr/local/bin/uconsole-session-restore"
# Firefox is one process with N windows; launching per window starts N browsers.
check "restore launches per process"   "grep -q 'One launch per PROCESS' $MNT/usr/local/bin/uconsole-session-restore"
check "snapshot keyed on processes"    "grep -q '\"processes\":' $MNT/usr/local/bin/uconsole-session-snapshot"
# Window titles are the most sensitive thing on screen and nothing in the restore
# path needs them. Matched precisely: sway puts a window's title in the CHILD
# node's "name", while a WORKSPACE's "name" is read from the workspace node and
# is both needed and harmless. A looser pattern matches the docstring saying
# titles are not recorded -- the same comment-matching trap as the gpiochip0 and
# "no sleep states" checks.
check "snapshot records no window titles" \
      "[[ \$(grep -c 'child.get(\"name\")\|\"title\"' $MNT/usr/local/bin/uconsole-session-snapshot) -eq 0 ]]"
check "snapshot is written 0600"       "grep -q '0o600' $MNT/usr/local/bin/uconsole-session-snapshot"
check "snapshot never ships in skel"   "[[ ! -e $MNT/etc/skel/.local/state/uconsole/session.json ]]"
check "restore policy is configurable" "grep -qE '^SESSION_RESTORE=[01]$' $MNT/etc/uconsole/lowpower.conf"
# A denylist, so an application installed later comes back without editing config.
check "restore skiplist ships"         "grep -q '^SESSION_RESTORE_SKIP=' $MNT/etc/uconsole/lowpower.conf"
check "restore has no allowlist"       "[[ \$(grep -c 'SESSION_RESTORE_ALLOW' $MNT/etc/uconsole/lowpower.conf $MNT/usr/local/bin/uconsole-session-restore | awk -F: '{s+=\$2} END{print s+0}') -eq 0 ]]"
# sway reports XWayland windows by WM_CLASS ("Gimp"), which never resolves in
# PATH -- checking app_id here would skip every X11 app as uninstalled.
check "missing-app check uses cmdline" "grep -q 'exe = (proc.get(\"cmdline\") or' $MNT/usr/local/bin/uconsole-session-restore"
check "restore launch cap ships"       "grep -qE '^SESSION_RESTORE_MAX=[0-9]+$' $MNT/etc/uconsole/lowpower.conf"
# Firefox exits CLEANLY at poweroff, so it will not restore tabs unless told to.
check "firefox session policy ships"   "[[ -f $MNT/etc/firefox/policies/policies.json ]]"
check "firefox policy is valid JSON"   "chroot $MNT /usr/bin/python3 -c \"import json;json.load(open('/etc/firefox/policies/policies.json'))\""
check "firefox policy restores session" "grep -q 'browser.startup.page' $MNT/etc/firefox/policies/policies.json"
# tmux-continuum restores into the server; attaching before it is up lands you
# in an empty session instead of the one you left.
check "restore waits for tmux"         "grep -q 'def tmux_ready' $MNT/usr/local/bin/uconsole-session-restore"
# /proc reports Firefox as /usr/lib/firefox/firefox; relaunching that bypasses
# whatever /usr/bin/firefox does. Prefer the name the desktop knows it by.
check "restore prefers the PATH name"  "grep -q 'shutil.which(app_id)' $MNT/usr/local/bin/uconsole-session-restore"
# A terminal launched from sway inherits sway's cwd of "/", so restoring it
# faithfully drops you in the root directory instead of at home.
check "restore ignores a cwd of /"     "grep -q 'cwd not in (\"/\", os.sep)' $MNT/usr/local/bin/uconsole-session-restore"

echo "-- power measurement --"
check "power probe present"            "[[ -x $MNT/usr/local/bin/uconsole-power-probe ]]"
check "power probe parses"             "bash -n $MNT/usr/local/bin/uconsole-power-probe"
# On AC the charger current swamps the load current, which is the easiest way to
# produce a confident and completely wrong idle figure.
check "power probe refuses on AC"      "grep -q 'on AC power' $MNT/usr/local/bin/uconsole-power-probe"
# Blanking switches Wi-Fi off, so a session watching over SSH cannot survive its
# own measurement.
check "power probe refuses over SSH"   "grep -q 'SSH_CONNECTION' $MNT/usr/local/bin/uconsole-power-probe"
# Pack size is policy, not a constant -- it depends on which cells are fitted.
# The probe must read it from the config rather than carrying its own copy, or
# the two drift apart and the runtime figures quietly become wrong.
check "pack size is configurable"      "grep -qE '^PACK_WH=[0-9.]+$' $MNT/etc/uconsole/lowpower.conf"
check "probe reads pack size from conf" "grep -q 'lowpower.conf' $MNT/usr/local/bin/uconsole-power-probe"
# Cell swaps should not mean hand-editing a config file and redoing arithmetic.
check "pack has a setter"              "grep -q 'do_pack()' $MNT/usr/local/bin/uconsole-power-probe"
# A sed that silently no-ops would leave every future runtime estimate wrong
# with nothing to notice -- the S3.1 failure mode again.
check "pack setter verifies its write" "grep -q 'write did not take' $MNT/usr/local/bin/uconsole-power-probe"
# The AXP223 balances nothing across a parallel pair, so mismatched cells are a
# hazard rather than an untidiness. Warn where someone is actually changing it.
check "pack setter warns on mismatch"  "grep -q 'same capacity, age and charge level' $MNT/usr/local/bin/uconsole-power-probe"
# 24.79 Wh came from the defect report and describes larger cells than this unit
# has. Assert it is gone so it cannot creep back into a runtime estimate.
check "stale 24.79Wh figure is gone"   "[[ \$(grep -rc '24\\.79' $MNT/etc/uconsole $MNT/usr/local/bin/uconsole-power-probe 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}') -eq 0 ]]"
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
# tmux keeps its own look: a green status bar with black text at the BOTTOM.
# waybar already owns the top of a 576px-tall screen, so a second bar there was
# a worse layout than leaving tmux alone.
check "tmux does not override status position" "! grep -q 'status-position' $MNT/etc/skel/.tmux.conf"
check "tmux does not override status colours"  "! grep -q 'status-style' $MNT/etc/skel/.tmux.conf"
check "tmux does not restyle windows or panes" "! grep -qE 'window-status-style|pane-border-style|message-style' $MNT/etc/skel/.tmux.conf"
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
check "integrates current for capacity" "grep -q 'chg + a \\* dt' $MNT/usr/local/bin/uconsole-battery-calibrate"
# The sample loop must stay fork-free: at 1 Hz the forks cost more than the reads
# they surround, and they draw current from the very pack being measured.
check "sample loop forks nothing per sample" \
      "grep -q 'rdv v voltage_now' $MNT/usr/local/bin/uconsole-battery-calibrate && ! grep -q 'sleep \"\$SAMPLE_SEC\"' $MNT/usr/local/bin/uconsole-battery-calibrate"
# The datasheet lookup, and the two things that make it trustworthy: the table
# carries the resistance needed to correct a loaded voltage, and that correction
# is SIGNED -- |I| would add it while charging too, where the terminal voltage
# already sits above the OCV.
check "soc subcommand present"          "grep -q 'soc)     shift; do_soc' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "table carries its resistance"    "grep -q 'pack_resistance_ohm' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "soc corrects load to OCV"        "grep -qF 'ocv = uv/1e6 - (ua/1e6) * R' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "soc flags off-table lookups"     "grep -q 'clamped=' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "stops above the PMU cutoff"     "grep -q 'FLOOR_UV:-3500000' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "warns when the modem is powered" "grep -q 'modem_is_on' $MNT/usr/local/bin/uconsole-battery-calibrate"
# The AXP223 driver never sets status=Full: measured at 4.213V / 100% / 5mA it
# still read "Charging". Waiting on that string hung phase 1 forever on a pack
# that was already charged. Terminate on the CV taper instead.
check "charge phase does not wait on status=Full" \
      "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-battery-calibrate | grep -c 'rd status) != \"Full\"') -eq 0 ]]"
check "charge phase detects the CV taper" "grep -q 'fully_charged()' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "charge phase requires a sustained taper" "grep -q '_need=3' $MNT/usr/local/bin/uconsole-battery-calibrate"
check "charge phase cannot hang forever"  "grep -q 'still not charged after 4 hours' $MNT/usr/local/bin/uconsole-battery-calibrate"
# Read BOTH numbers out of the shipped scripts and compare them. This used to be
# `[[ 3500000 -gt 3400000 ]]` -- both sides hardcoded, so it could never fail and
# never noticed either value changing. The calibrator must stop discharging above
# the guard's cutoff, or a calibration run would trigger the shutdown it exists
# to measure around.
check "calibrator floor sits above the guard cutoff" \
      "[[ \$(grep -oE 'FLOOR_UV:-[0-9]+' $MNT/usr/local/bin/uconsole-battery-calibrate | grep -oE '[0-9]+') -gt \$(grep -oE '^CRIT_UV=[0-9]+' $MNT/usr/local/bin/uconsole-battery-guard | grep -oE '[0-9]+') ]]"
check "guard cutoff is 3.40V"          "grep -q '^CRIT_UV=3400000' $MNT/usr/local/bin/uconsole-battery-guard"
# The gauge reads high near empty because it is uncalibrated, so a shutdown looks
# premature from the percentage alone. Both numbers must appear together or the
# journal cannot explain itself.
check "guard logs the gauge alongside volts" "grep -q 'gauge()' $MNT/usr/local/bin/uconsole-battery-guard"
# The warn must fire before the cut, or the warning is useless.
check "guard warns above its cutoff" \
      "[[ \$(grep -oE '^WARN_UV=[0-9]+' $MNT/usr/local/bin/uconsole-battery-guard | grep -oE '[0-9]+') -gt \$(grep -oE '^CRIT_UV=[0-9]+' $MNT/usr/local/bin/uconsole-battery-guard | grep -oE '[0-9]+') ]]"
check "guard and calibrator agree on the battery path" "grep -q 'axp20x-battery' $MNT/usr/local/bin/uconsole-battery-guard && grep -q 'axp20x-battery' $MNT/usr/local/bin/uconsole-battery-calibrate"

echo
echo "### 18. Tailscale"
check "tailscale CLI installed"        "[[ -x $MNT/usr/bin/tailscale ]]"
check "tailscaled installed"           "[[ -x $MNT/usr/bin/tailscaled || -x $MNT/usr/sbin/tailscaled ]]"
check "tailscaled.service enabled"     "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/tailscaled.service ]]"
check "netfilter userspace present"    "[[ -x $MNT/usr/bin/nft ]]"
check "tun module available"           "[[ -n \$(find $MNT/usr/lib/modules/$KVER -name 'tun.ko*' -print -quit) ]]"
echo "-- no identity or credentials baked into the image --"
check "no tailscaled state directory"  "[[ ! -e $MNT/var/lib/tailscale/tailscaled.state ]]"
check "no auth key in any unit"        "! grep -rqiE 'tskey-|TS_AUTHKEY|--authkey' $MNT/etc/systemd/system/ 2>/dev/null"
check "no auth key in our scripts"     "! grep -rqiE 'tskey-|TS_AUTHKEY' $MNT/usr/local/bin/ 2>/dev/null"
check "no tailscale node key on disk"  "[[ -z \$(find $MNT/var/lib/tailscale -type f -print -quit 2>/dev/null) ]]"
echo "-- follows the WAN when it changes --"
check "tailscale nudge script present"  "[[ -x $MNT/usr/local/bin/uconsole-tailscale-nudge ]]"
check "nudge rebinds magicsock"         "grep -q 'debug rebind' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "nudge forces endpoint restun"    "grep -q 'debug restun' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "nudge is a no-op when logged out" "grep -q 'tailscale status >/dev/null 2>&1 || exit 0' $MNT/usr/local/bin/uconsole-tailscale-nudge"
check "NM dispatcher hook present"      "[[ -x $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale ]]"
check "dispatcher hook is root-owned"   "[[ -f $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale ]] && [[ \$(stat -c%u $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale) -eq 0 ]]"
check "dispatcher not group/world writable" "[[ \$(stat -c%a $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale) =~ ^7[05][05]$ ]]"
check "dispatcher skips tailscale's own iface" "grep -q 'tailscale\*|ts\*' $MNT/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale"
check "uconsole-wan nudges on switch"   "[[ \$(grep -c 'tailscale_follow' $MNT/usr/local/bin/uconsole-wan) -ge 4 ]]"
check "overlay scripts are root-owned"  "[[ -f $MNT/usr/local/bin/uconsole-wan ]] && [[ \$(stat -c%u $MNT/usr/local/bin/uconsole-wan) -eq 0 ]]"

echo
echo "### 19. login and lock-on-wake"
check "swaylock installed"             "[[ -x $MNT/usr/bin/swaylock ]]"
check "swaylock has a PAM config"      "[[ -s $MNT/etc/pam.d/swaylock ]]"
check "screen toggle locks the session" "grep -q 'swaylock -f' $MNT/usr/local/bin/uconsole-screen-toggle"
check "lock happens before blanking"   "grep -q 'lock_session' $MNT/usr/local/bin/uconsole-screen-toggle"
check "unlock failure is logged, not silent" "grep -q 'WITHOUT locking' $MNT/usr/local/bin/uconsole-screen-toggle"
echo "-- input silenced while blanked --"
check "blanking disables pointers"     "grep -q 'set_inputs disabled pointers' $MNT/usr/local/bin/uconsole-screen-toggle"
# Keyboards are never disabled: the power key is a keyboard-type device whose
# identifier this script cannot predict, and silencing it is unrecoverable.
check "keyboards are never disabled"   "grep -q 'POINTERS = (\"pointer\", \"touchpad\", \"touch\", \"tablet_tool\")' $MNT/usr/local/bin/uconsole-screen-toggle"
check "wake re-enables ALL input"      "grep -q 'set_inputs enabled all' $MNT/usr/local/bin/uconsole-screen-toggle"
# Silencing the power key would be an unrecoverable lockout: it is the only
# device that can bring the machine back.
check "no fragile name-based power match" "! grep -q '\"pek\"' $MNT/usr/local/bin/uconsole-screen-toggle"
check "input filter needs python3, which is installed" "[[ -x $MNT/usr/bin/python3 ]]"
check "swaymsg available for input control" "[[ -x $MNT/usr/bin/swaymsg ]]"
check "sway still starts after login"  "grep -q 'exec sway' $MNT/etc/skel/.bash_profile"

echo
echo "### 20. hardening and resources"
echo "-- zram (was installed but inert) --"
check "zram-generator config present"  "[[ -s $MNT/etc/systemd/zram-generator.conf ]]"
check "zram is 4 GB"                   "grep -qx 'zram-size = 4096' $MNT/etc/systemd/zram-generator.conf"
check "zram uses zstd"                 "grep -q 'compression-algorithm = zstd' $MNT/etc/systemd/zram-generator.conf"
check "zram-generator installed"       "[[ -x $MNT/usr/lib/systemd/system-generators/zram-generator ]]"
echo "-- firewall --"
check "nftables ruleset present"       "[[ -s $MNT/etc/nftables.conf ]]"
check "nftables.service enabled"       "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/nftables.service ]]"
check "input policy is drop"           "grep -qE 'policy drop' $MNT/etc/nftables.conf"
check "ssh restricted to LAN/tailnet"  "grep -q '100.64.0.0/10' $MNT/etc/nftables.conf"
check "ssh is NOT open to the world"   "! grep -qE '^[[:space:]]*tcp dport ssh accept' $MNT/etc/nftables.conf"
check "tailscale interface trusted"    "grep -q 'iifname \"tailscale0\" accept' $MNT/etc/nftables.conf"
check "loopback and conntrack allowed" "grep -q 'iif lo accept' $MNT/etc/nftables.conf && grep -q 'established, related' $MNT/etc/nftables.conf"
echo "-- kernel update path --"
check "kernel-check helper present"    "[[ -x $MNT/usr/local/bin/uconsole-kernel-check ]]"
check "kernel-check queries upstream"  "grep -q 'ak-rex/ClockworkPi-linux' $MNT/usr/local/bin/uconsole-kernel-check"
check "kernel-check explains pacman will not update it" "grep -q 'never update this kernel' $MNT/usr/local/bin/uconsole-kernel-check"

echo
echo "### profile: $PROFILE"
# Cross-check the declared profile against what is actually inside, so verifying
# a dev image as "runtime" (or the reverse) fails loudly instead of passing the
# wrong assertions.
HAS_DEV=0; [[ -x $MNT/usr/local/bin/uconsole-selftest ]] && HAS_DEV=1
check "image contents match the declared profile" \
      "[[ ( '$PROFILE' == dev && $HAS_DEV -eq 1 ) || ( '$PROFILE' == runtime && $HAS_DEV -eq 0 ) ]]"

# --- runtime stack: kept, and kept honest ----------------------------------
# These are present on purpose, judged on size, usefulness and background cost:
# htop 480K, net-tools 955K, parted 2.8M, alsa-utils 3.4M, git 46M. None runs a
# daemon. Asserted PRESENT so a future "leanness" pass cannot quietly drop a
# tool someone reaches for.
for pkg in parted git htop alsa-utils net-tools; do
    check "runtime ships $pkg" "chroot $MNT /usr/bin/pacman -Q $pkg >/dev/null 2>&1"
done
# The real criterion is background cost, not disk. alsa-utils ships alsa-state:
# a RESIDENT alsactl daemon, "static" so it reads as disabled, but symlinked into
# sound.target.wants -- so udev starts it the moment the card appears. Masked,
# because WirePlumber owns mixer state here.
#
# Asserted via the mask symlink, not `is-enabled`: that returns 0 for "static"
# too, so it cannot tell "will never run" from "will run via a .wants symlink".
check "alsa-state daemon masked"       "[[ \$(readlink $MNT/etc/systemd/system/alsa-state.service) == /dev/null ]]"
check "alsa-restore oneshot untouched" "[[ ! -L $MNT/etc/systemd/system/alsa-restore.service ]]"
# evtest is NOT optional: uconsole-powerkey-hold uses `evtest --query` to confirm
# the key is physically down, and without it the 2s poweroff silently never arms.
check "evtest present (powerkey-hold needs it)" "[[ -x $MNT/usr/bin/evtest ]]"
# growpart is now the only resizer; parted is gone and so is the fallback to it.
check "growpart present"               "[[ -x $MNT/usr/bin/growpart ]]"
check "expand-root has no parted fallback" \
      "[[ \$(grep -v '^[[:space:]]*#' $MNT/usr/local/bin/uconsole-expand-root | grep -c 'parted') -eq 0 ]]"

# --- tmux plugin tree ------------------------------------------------------
# This tree is copied into /etc/skel and again into every account, so anything
# dead in it is paid for per user.
check "no git repos in the tmux plugins" \
      "[[ -z \$(find $MNT/etc/skel/.tmux/plugins -name .git -print -quit 2>/dev/null) ]]"
check "no plugin test suites shipped" \
      "[[ -z \$(find $MNT/etc/skel/.tmux/plugins -type d -name tests -print -quit 2>/dev/null) ]]"
check "plugin versions still knowable" \
      "[[ \$(ls $MNT/etc/skel/.tmux/plugins/*/PINNED_COMMIT 2>/dev/null | wc -l) -eq 3 ]]"
# The automatic-start helpers LOOK macOS-only and are not: continuum calls them
# on every load, taking the disable branch when @continuum-boot is unset.
check "continuum automatic-start helpers intact" \
      "[[ -f $MNT/etc/skel/.tmux/plugins/tmux-continuum/scripts/handle_tmux_automatic_start/systemd_disable.sh ]]"

# --- credentials -----------------------------------------------------------
# The repository is public and the dev image carries a Wi-Fi PSK. The runtime
# image must carry none, and neither may leak one anywhere but the connection
# file itself.
if [[ $PROFILE == runtime ]]; then
    check "runtime ships no wifi connection" \
          "[[ -z \$(find $MNT/etc/NetworkManager/system-connections -name '*.nmconnection' -print -quit 2>/dev/null) ]]"
    # A default account with a published password, autologin, and passwordless
    # sudo are dev-image conveniences. Reaching the runtime image would mean
    # shipping a machine anyone can walk up to and own.
    check "runtime has NO autologin"   "[[ ! -e $MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf ]]"
    check "runtime has NO dev sudoers" "[[ ! -e $MNT/etc/sudoers.d/99-dev-account ]]"
    check "runtime keeps the firstboot wizard" \
          "[[ -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-firstboot-user.service ]]"
    # uid >= 1000 means a human account was baked in; the stock `alarm` user is
    # uid 1000 in the ALARM rootfs, so look above it.
    check "runtime bakes in no extra account" \
          "[[ \$(awk -F: '\$3 > 1000 && \$3 < 65000' $MNT/etc/passwd | wc -l) -eq 0 ]]"
    check "runtime authorises no SSH key" \
          "[[ -z \$(find $MNT/home -name authorized_keys -print -quit 2>/dev/null) ]]"
else
    check "dev ships a wifi connection" \
          "[[ -n \$(find $MNT/etc/NetworkManager/system-connections -name '*.nmconnection' -print -quit 2>/dev/null) ]]"
    # NetworkManager refuses to load a connection readable by anyone but root,
    # and says so only in its own log.
    check "wifi connection is 0600 root" \
          "[[ \$(stat -c'%a %U' $MNT/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -1) == '600 root' ]]"
    check "dev ships firefox"   "[[ -x $MNT/usr/bin/firefox ]]"
    # Default account + autologin. Convenient on a test device, and exactly the
    # thing that must never reach the runtime image.
    check "dev has a default account"  "[[ \$(grep -c '^[^:]*:x:1[0-9][0-9][0-9]:' $MNT/etc/passwd) -ge 1 ]]"
    check "dev autologs in on tty1"    "grep -q -- '--autologin' $MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    check "dev skips the firstboot wizard" \
          "[[ ! -L $MNT/etc/systemd/system/multi-user.target.wants/uconsole-firstboot-user.service ]]"
    check "dev sudoers drop-in is 0440" "[[ \$(stat -c%a $MNT/etc/sudoers.d/99-dev-account) == 440 ]]"
    check "dev ships selftest"  "[[ -x $MNT/usr/local/bin/uconsole-selftest ]]"
    check "dev selftest parses" "bash -n $MNT/usr/local/bin/uconsole-selftest"
fi
# No PSK may appear in a script, a unit, or skel -- only in the connection file.
check "no psk= outside the connection file" \
      "[[ \$(grep -rl 'psk=' $MNT/usr/local/bin $MNT/etc/systemd $MNT/etc/skel 2>/dev/null | wc -l) -eq 0 ]]"

echo
echo "########################################"
echo "RESULT: $PASSES passed, $FAILS failed"
echo "########################################"
[[ $FAILS -eq 0 ]]
