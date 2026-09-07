#!/usr/bin/env bash
# Verify a flashed uConsole card against the image it was written from.
#
#   sudo ./verify-card.sh [disk-identifier]
#
# Read-only: this never writes to the card.
#
# Whole-disk hashing is useless on macOS because the FAT partition is auto-mounted
# the instant the write finishes and the OS immediately writes its own metadata
# (.Spotlight-V100, .fseventsd) into it. So verify the two partitions differently:
#   - ext4 root: raw byte compare. macOS cannot write ext4, so this must match exactly.
#   - FAT boot: compare the actual files against a manifest, ignoring macOS's additions.
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="${1:-disk4}"
RAW="/dev/r${DISK}"
REGIONS="$DIR/out/region-hashes.txt"
MANIFEST="$DIR/out/boot-manifest.sha256"

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 $DISK"; exit 1; }
[[ -f $REGIONS  ]] || { echo "missing $REGIONS"; exit 1; }
[[ -f $MANIFEST ]] || { echo "missing $MANIFEST"; exit 1; }

fail=0

echo "=== unmounting so nothing changes underneath us ==="
diskutil unmountDisk "/dev/$DISK"

region_hash() {  # name skip_mib count_mib
    dd if="$RAW" bs=1m skip="$2" count="$3" 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

echo
echo "=== raw region compare ==="
while read -r name skip count want; do
    [[ $name == \#* || -z $name ]] && continue
    got="$(region_hash "$name" "$skip" "$count")"
    if [[ $got == "$want" ]]; then
        printf '  [MATCH]    %-10s (%s MiB @ %s MiB)\n' "$name" "$count" "$skip"
    else
        printf '  [DIFFERS]  %-10s (%s MiB @ %s MiB)\n' "$name" "$count" "$skip"
        printf '             image: %s\n             card : %s\n' "$want" "$got"
        [[ $name == ext4_root ]] && fail=1
    fi
done < "$REGIONS"

echo
echo "=== boot partition: file-level compare ==="
MNT=/tmp/uconsole-verify
mkdir -p "$MNT"
if diskutil mount -mountPoint "$MNT" "/dev/${DISK}s1" >/dev/null 2>&1; then
    OWN_MNT=1
else
    # Fall back to letting diskutil pick the mount point (usually /Volumes/UCONSOLE).
    diskutil mount "/dev/${DISK}s1" >/dev/null
    MNT="$(diskutil info "/dev/${DISK}s1" | awk -F': *' '/Mount Point/ {print $2}')"
    OWN_MNT=0
fi
[[ -d $MNT ]] || { echo "could not mount /dev/${DISK}s1"; exit 1; }
echo "  boot partition mounted at: $MNT"

missing=0; changed=0; matched=0
while read -r want path; do
    f="$MNT/${path#./}"
    if [[ ! -f $f ]]; then
        echo "  [MISSING]  ${path#./}"; missing=$((missing+1)); continue
    fi
    got="$(shasum -a 256 "$f" | awk '{print $1}')"
    if [[ $got == "$want" ]]; then matched=$((matched+1))
    else echo "  [CHANGED]  ${path#./}"; changed=$((changed+1)); fi
done < "$MANIFEST"

echo "  $matched/$(wc -l < "$MANIFEST" | tr -d ' ') boot files match, $changed changed, $missing missing"

extra="$(cd "$MNT" && find . -type f | sort | comm -23 - <(awk '{print $2}' "$MANIFEST" | sort) || true)"
if [[ -n $extra ]]; then
    echo
    echo "  files macOS added to the boot partition (harmless to the Pi bootloader):"
    sed 's/^/    /' <<<"$extra"
fi

diskutil unmount "$MNT" >/dev/null 2>&1 || true
(( OWN_MNT == 1 )) && rmdir "$MNT" 2>/dev/null || true

(( changed > 0 || missing > 0 )) && fail=1

echo
if (( fail == 0 )); then
    echo "RESULT: card is good - root filesystem is byte-identical and every boot file matches."
else
    echo "RESULT: card FAILED verification - do not boot it."
fi
exit "$fail"
