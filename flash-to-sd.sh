#!/usr/bin/env bash
# Flash the uConsole Arch image to the SD card.
#
#   sudo ./flash-to-sd.sh [disk-identifier] [image-path]
#
# THIS ERASES THE TARGET CARD COMPLETELY.
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="${1:-disk4}"
IMG="${2:-$DIR/out/uconsole-arch-cm5-sway.img}"
RAW="/dev/r${DISK}"

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 $DISK [image]"; exit 1; }
[[ -f $IMG ]] || { echo "image not found: $IMG"; exit 1; }

echo "=== target safety check ==="
info="$(diskutil info "/dev/$DISK")"
echo "$info" | grep -E 'Device / Media Name|Protocol|Removable Media|Disk Size'

# Refuse to touch anything that is not a removable SD card of roughly the right size.
grep -q 'Removable Media:  *Removable' <<<"$info" || { echo "REFUSING: /dev/$DISK is not removable"; exit 1; }
grep -q 'Protocol:  *Secure Digital'   <<<"$info" || { echo "REFUSING: /dev/$DISK is not an SD card"; exit 1; }

img_bytes=$(stat -f%z "$IMG")
disk_bytes=$(echo "$info" | awk -F'[()]' '/Disk Size/ {print $2}' | awk '{print $1}')
echo "image: ${img_bytes} bytes / card: ${disk_bytes} bytes"
(( disk_bytes >= img_bytes )) || { echo "REFUSING: card is smaller than the image"; exit 1; }

echo
echo "=== unmounting ==="
diskutil unmountDisk "/dev/$DISK"

echo
echo "=== writing $(basename "$IMG") -> $RAW ==="
dd if="$IMG" of="$RAW" bs=4m status=progress
sync

echo
echo "=== ejecting ==="
diskutil eject "/dev/$DISK"

# No read-back hash check here on purpose.
#
# macOS auto-mounts the freshly written FAT partition as soon as dd finishes and
# immediately writes its own metadata into it (.Spotlight-V100, .fseventsd).
# A whole-disk hash therefore ALWAYS differs from the image, even on a perfect
# write, and unmounting afterwards cannot undo writes that already happened.
# The check reported a real difference but the wrong conclusion, every time.
#
# verify-card.sh does this correctly instead: a raw byte compare of the ext4
# root (which macOS has no driver for and cannot touch) plus a file-by-file
# compare of the FAT boot partition that ignores macOS's additions.
echo
echo "Done. The card is flashed."
echo "To verify it:  sudo ${DIR}/verify-card.sh ${DISK}"
