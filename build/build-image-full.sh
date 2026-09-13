#!/usr/bin/env bash
set -Eeuo pipefail

# Two trees from one source: PROFILE=runtime ships the machine people use;
# PROFILE=dev adds test utilities, a browser, and a pre-provisioned network so a
# freshly flashed card is reachable without sitting at the keyboard.
#
# The DIFFERENCE is additive only -- dev is runtime plus overlay-dev/ plus extra
# packages. There is no dev-only fork of any shipped file, so a fix cannot land
# in one tree and miss the other.
PROFILE="${BUILD_PROFILE:-runtime}"
case "$PROFILE" in
  runtime) IMG="/work/out/uconsole-arch-cm5-sway.img" ;;
  dev)     IMG="/work/out/uconsole-arch-cm5-sway-dev.img" ;;
  *) echo "BUILD_PROFILE must be 'runtime' or 'dev', got '$PROFILE'" >&2; exit 2 ;;
esac
echo "=== building the $PROFILE image: $(basename "$IMG") ==="

# BUILD size, not shipped size. The image is shrunk to fit in step [8/8].
#
# It has to be generous here because pacman's PEAK usage is far above the final
# content: it downloads and extracts before cleaning up. Sizing this to measured
# final usage (2.9G runtime) failed with "Partition / too full: 299385 blocks
# needed, 277133 blocks free" -- about 1.2G of transient space that the finished
# image does not contain.
SIZE="${IMAGE_SIZE:-8G}"

# Free space to leave in the shrunk root. Enough for a `pacman -Syu` on the
# device before uconsole-expand-root grows it on first boot.
SHRINK_FREE="${SHRINK_FREE:-256}"      # MiB
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
  arch-install-scripts psmisc systemd coreutils gawk sed grep python git

echo "=== [1b/6] upstream builder and rootfs ==="
# Pinned so a build is reproducible and so a fresh clone of THIS repository can
# actually build -- uconsole-arch is gitignored and was previously expected to
# already exist, which meant the documented quick start only worked on the
# machine that happened to have cloned it by hand.
UCONSOLE_ARCH_COMMIT=896a3acd39e0831fa4a1093ff4bb0db71d09c07d
ROOTFS_SHA256=42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319
ROOTFS=/work/cache/ArchLinuxARM-aarch64-latest.tar.gz

if [[ ! -d /work/uconsole-arch/.git ]]; then
    echo "cloning wdkdot/uconsole-arch"
    rm -rf /work/uconsole-arch
    git clone --quiet https://github.com/wdkdot/uconsole-arch.git /work/uconsole-arch
fi
git -C /work/uconsole-arch fetch --quiet origin 2>/dev/null || true
# reset --hard, not checkout: the build patches these scripts in place, and a
# clean tree each run keeps the build idempotent.
git -C /work/uconsole-arch reset --hard --quiet "$UCONSOLE_ARCH_COMMIT"
echo "upstream builder pinned at $(git -C /work/uconsole-arch rev-parse --short HEAD)"

if [[ ! -f $ROOTFS ]]; then
    echo "fetching the Arch Linux ARM rootfs"
    install -d /work/cache
    curl -L --retry 3 -o "$ROOTFS" http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
fi
actual_sha="$(sha256sum "$ROOTFS" | awk '{print $1}')"
if [[ $actual_sha == "$ROOTFS_SHA256" ]]; then
    echo "rootfs matches the recorded build"
else
    echo "NOTE: rootfs differs from the recorded build"
    echo "      recorded: $ROOTFS_SHA256"
    echo "      actual  : $actual_sha"
    echo "      Arch Linux ARM publishes only a rolling 'latest' tarball, so this"
    echo "      drifts over time. The build is pinned everywhere it can be, but is"
    echo "      not bit-for-bit reproducible across rootfs refreshes."
fi

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
# Runtime stack: everything here must support a shipped feature. A package that
# is only ever useful to whoever is debugging the image belongs in PKGS_DEV.
PKGS=(
  sway swaybg swayidle swaylock foot fuzzel waybar xorg-xwayland
  polkit ttf-dejavu mesa
  pipewire pipewire-alsa pipewire-pulse wireplumber
  brightnessctl wl-clipboard grim slurp
  bluez bluez-utils
  # Kept deliberately, judged on size / usefulness / background cost:
  #   htop 480K, net-tools 955K, parted 2.8M, alsa-utils 3.4M, git 46M.
  # None runs a daemon, so none costs battery; the only real price is SD space.
  #
  # parted is here as an INTERACTIVE tool. The S3.1 bug was our own script
  # calling `parted -s resizepart`, which answers "No" to the in-use prompt and
  # reports success -- that call is gone and growpart is the only resizer now.
  # Run by a human, parted prompts and works.
  #
  # git is the outlier at 46M (it pulls perl) and earns it twice: TPM needs it to
  # install any plugin beyond the three pre-installed here, and this is a machine
  # people work on.
  parted git htop alsa-utils
  # 4G/LTE: ModemManager stack plus libgpiod, which the CM5 power-on
  # script uses (gpioset) instead of CM4's pinctrl approach.
  #
  # usb_modeswitch looks unused -- nothing in the overlay calls it -- but it
  # ships udev rules that ModemManager relies on for modems that present as
  # mass storage first. Removing it to save a megabyte risks LTE not coming up
  # at all, on a device where that is hard to notice.
  #
  # net-tools is not listed: the ALARM base rootfs already ships it, so asking
  # for it re-installs something we get regardless. It is present either way.
  modemmanager libgpiod libqmi usb_modeswitch
  # From the on-device defect report:
  cloud-guest-utils   # growpart, the ONLY partition resizer now (S3.1)
  wireless-regdb iw   # regulatory.db, or brcmfmac floods the log (S3.7); `iw reg set` is documented
  usbutils            # lsusb, documented for modem triage (S3.11)
  zram-generator      # compressed swap; there is none and only 4GB RAM (S3.11)
  python              # waybar modem module, session snapshot/restore, mmcli JSON parsing
  tmux                # TPM + resurrect + continuum are pre-installed in /etc/skel
  tailscale           # daemon enabled but unauthenticated; no key is baked in
  evtest              # REQUIRED at runtime: uconsole-powerkey-hold uses `evtest --query`
                      # to confirm the key is still physically down before powering off
)

# Dev-only. Nothing here may be referenced by a shipped script, or the runtime
# image would break in a way the dev image hides.
PKGS_DEV=(
  firefox             # the browser the session-restore path is written around
  mpv imv             # media and images, so the panel can actually be exercised
  neovim              # editing on the device without scp round-trips
  git htop strace     # triage
  powertop            # wakeup counts -- the one lever left after the 2.6W floor
  net-tools           # ifconfig/route, for comparing against the ip(8) output
  tcpdump             # LTE vs Wi-Fi path debugging
)
if [[ $PROFILE == dev ]]; then
  PKGS+=("${PKGS_DEV[@]}")
  echo "dev profile: adding ${#PKGS_DEV[@]} extra packages"
fi

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
bash /work/build/customize-image.sh "$IMG" "$PROFILE"

echo "=== [7/8] flash verification artifacts ==="
# Generated here rather than by hand. Producing them manually risked leaving a
# stale manifest behind, and verify-card.sh comparing a card against the wrong
# image is worse than not checking at all -- a stale PASS is the dangerous case.
ART_LOOP="$(losetup -Pf --show "$IMG")"
partprobe "$ART_LOOP" >/dev/null 2>&1 || true
sleep 1
install -d /mnt/artman
mount -o ro "${ART_LOOP}p1" /mnt/artman
( cd /mnt/artman && find . -type f | sort | xargs sha256sum ) > /tmp/boot-manifest.sha256
umount /mnt/artman
losetup -d "$ART_LOOP"
cp /tmp/boot-manifest.sha256 /work/out/boot-manifest.sha256
echo "boot manifest: $(wc -l < /work/out/boot-manifest.sha256) files"

echo "=== [8/8] shrinking the image to fit ==="
# Sized to the content, not to the card.
#
# uconsole-expand-root grows the root to fill whatever card it is flashed to on
# first boot, so image size constrains nothing on the device -- it is purely a
# build and transfer artifact. The 8G build image carried ~4.4G of zeroes, which
# cost real time on every `dd` to a card.
#
# This runs AFTER customize-image.sh on purpose. Upstream's own --minimize flag
# does the same job but runs at the end of ITS script, which is before our
# overlay and chroot step -- it would shrink the filesystem we then write into.
align_up() { echo $(( ( ($1) + ($2) - 1 ) / ($2) * ($2) )); }

SH_LOOP="$(losetup -Pf --show "$IMG")"
partprobe "$SH_LOOP" >/dev/null 2>&1 || true
sleep 1
SH_ROOT="${SH_LOOP}p2"

e2fsck -fy "$SH_ROOT" >/dev/null 2>&1 || true
# Reserved blocks count toward the minimum resize2fs will accept, and the ext4
# default of 5% is 216MiB here -- pointless on an image that expands on first
# boot. 1% is plenty of anti-fragmentation headroom for a root filesystem.
tune2fs -m 1 "$SH_ROOT" >/dev/null 2>&1 || true
# Twice: the first pass relocates blocks, and a second pass can usually go
# further once they have moved.
resize2fs -M "$SH_ROOT" >/dev/null 2>&1 || true
e2fsck -fy "$SH_ROOT" >/dev/null 2>&1 || true
resize2fs -M "$SH_ROOT"
e2fsck -fy "$SH_ROOT" >/dev/null 2>&1 || true

_bs=$(tune2fs -l "$SH_ROOT" | awk -F: '/Block size:/ {gsub(/ /,"",$2); print $2}')
_min=$(tune2fs -l "$SH_ROOT" | awk -F: '/Block count:/ {gsub(/ /,"",$2); print $2}')
_want=$(( (_min * _bs + SHRINK_FREE * 1048576 + _bs - 1) / _bs ))
echo "root: ${_min} blocks minimum, growing to ${_want} for ${SHRINK_FREE}M free"
resize2fs "$SH_ROOT" "$_want"
e2fsck -fy "$SH_ROOT" >/dev/null 2>&1 || true

_blocks=$(tune2fs -l "$SH_ROOT" | awk -F: '/Block count:/ {gsub(/ /,"",$2); print $2}')
_bs=$(tune2fs -l "$SH_ROOT" | awk -F: '/Block size:/ {gsub(/ /,"",$2); print $2}')
_fsbytes=$(( _blocks * _bs ))
_start=$(parted -ms "$SH_LOOP" unit B print | awk -F: '$1 == "2" {sub(/B/,"",$2); print $2}')
_partbytes=$(align_up $(( _fsbytes + 1048576 )) 1048576)
_newsize=$(align_up $(( _start + _partbytes )) 1048576)

_ss=$(blockdev --getss "$SH_LOOP")
_sectors=$(( _partbytes / _ss ))
sfdisk --dump "$SH_LOOP" > /tmp/sf.old
awk -v part="$SH_ROOT" -v size="$_sectors" \
    'index($0, part " :") == 1 { sub(/size=[[:space:]]*[0-9]+/, "size= " size) } { print }' \
    /tmp/sf.old > /tmp/sf.new
sfdisk "$SH_LOOP" < /tmp/sf.new >/dev/null
partprobe "$SH_LOOP" >/dev/null 2>&1 || true
losetup -d "$SH_LOOP"

truncate -s "$_newsize" "$IMG"
echo "image shrunk: $(( _newsize / 1048576 )) MiB (was $(( $(numfmt --from=iec "$SIZE") / 1048576 )) MiB)"

img_bytes=$(stat -c%s "$IMG")
img_mib=$(( img_bytes / 1048576 ))
root_mib=$(( img_mib - 513 ))
{
  echo "# region hashes for $(basename "$IMG")"
  echo "mbr_gap   0 1        $(dd if="$IMG" bs=1M count=1 2>/dev/null | sha256sum | awk '{print $1}')"
  echo "fat_boot  1 512      $(dd if="$IMG" bs=1M skip=1 count=512 2>/dev/null | sha256sum | awk '{print $1}')"
  echo "ext4_root 513 ${root_mib}   $(dd if="$IMG" bs=1M skip=513 count=${root_mib} 2>/dev/null | sha256sum | awk '{print $1}')"
} > /work/out/region-hashes.txt
sha256sum "$IMG" | sed "s| .*| $(basename "$IMG")|" > "${IMG}.sha256"
cat /work/out/region-hashes.txt

echo "IMAGE BUILD OK: $IMG"
