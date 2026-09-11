#!/usr/bin/env bash
# Reflash a uConsole over the network, from this workstation.
#
#   build/ota-push.sh <user@host> <image.img> [--flash]
#
# Compresses the image on the fly and streams it straight to the device, so no
# .gz is ever written here and the transfer is the compressed size. The device
# stages it, checks it, and -- with --flash -- writes it to its own card from the
# initramfs on the next boot.
#
# Measured over 5GHz Wi-Fi at -64dBm: 4.79GB image -> 1.38GB on the wire in
# 130-136s, the 5.19GB dev image -> 1.62GB in 160s. The flash itself took 169s
# from typing FLASH to a settled desktop on the new card. Without --flash the
# device is left staged but unarmed, which is the safe default.
set -euo pipefail

HOST=${1:-}; IMG=${2:-}; MODE=${3:-}
# BSD sed (this runs on the workstation) has no \? quantifier, hence the interval.
[[ -n $HOST && -n $IMG ]] || { sed -n '2,6p' "$0" | sed 's/^#[ ]\{0,1\}//'; exit 2; }
[[ -f $IMG ]] || { echo "no such image: $IMG" >&2; exit 1; }

# The hash has to be of the compressed bytes, because those are what the device
# stores and what the initramfs re-checks before it touches the card. Computing
# it from a tee of the same stream is the only way to know both ends saw the
# same thing without writing the .gz down anywhere.
SHA_TMP=$(mktemp)
trap 'rm -f "$SHA_TMP"' EXIT
if command -v sha256sum >/dev/null; then HASH=(sha256sum); else HASH=(shasum -a 256); fi

SZ=$(stat -f %z "$IMG" 2>/dev/null || stat -c %s "$IMG")
echo "==> streaming $(( SZ / 1048576 ))MB image to $HOST (compressed on the fly)"
START=$(date +%s)
# gzip -1: the transfer is network-bound at ~12MB/s, so spending CPU on a
# smaller file only makes the whole thing slower.
gzip -1 -c "$IMG" \
  | tee >("${HASH[@]}" | cut -d' ' -f1 > "$SHA_TMP") \
  | ssh "$HOST" 'cat > /var/tmp/uconsole-ota.img.gz'
echo "==> transferred in $(( $(date +%s) - START ))s"

# bash does not wait for a >(...) process substitution, so the hash can still be
# being written when the pipeline returns. Wait for a complete one, and never pass
# an empty or partial hash on: the device would then fall back to whatever
# checksum it had recorded before, and report the wrong thing as verified.
SHA=
for _ in $(seq 1 50); do
    SHA=$(cat "$SHA_TMP" 2>/dev/null || true)
    [[ $SHA =~ ^[0-9a-f]{64}$ ]] && break
    sleep 0.2
done
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || { echo "no complete hash of the stream -- not verifying" >&2; exit 1; }
echo "==> sent sha256 $SHA"
echo "==> asking the device to verify what it received"
ssh "$HOST" "uconsole-ota verify $SHA"

if [[ $MODE == --flash ]]; then
    echo "==> arming the flash (the device will ask you to confirm)"
    ssh -t "$HOST" "sudo uconsole-ota flash"
else
    echo "==> staged but not armed. On the device:"
    echo "      sudo uconsole-ota dry-run   # rehearsal, writes nothing"
    echo "      sudo uconsole-ota flash     # the real thing"
fi
