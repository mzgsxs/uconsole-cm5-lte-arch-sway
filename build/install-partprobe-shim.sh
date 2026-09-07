#!/usr/bin/env bash
# Docker Desktop's /dev is a plain tmpfs, and no in-container udev can populate it.
# `losetup -P` therefore registers partitions with the kernel (they show up in sysfs)
# but /dev/loopNpM device nodes are never created. Wrap partprobe so that every
# rescan also materialises the missing nodes from sysfs.
set -Eeuo pipefail

REAL=/usr/sbin/partprobe
[[ -f ${REAL}.real ]] || mv "$REAL" "${REAL}.real"

cat > "$REAL" <<'WRAP'
#!/usr/bin/env bash
/usr/sbin/partprobe.real "$@"
rc=$?
for dev in "$@"; do
    base="$(basename "$dev")"
    for pdir in /sys/block/"$base"/"$base"p*; do
        [[ -d $pdir ]] || continue
        pn="$(basename "$pdir")"
        devspec="$(cat "$pdir/dev")"
        if [[ ! -b /dev/$pn ]]; then
            mknod "/dev/$pn" b "${devspec%%:*}" "${devspec##*:}"
            echo "partprobe-shim: created /dev/$pn (${devspec})" >&2
        fi
    done
done
exit $rc
WRAP
chmod +x "$REAL"
echo "partprobe shim installed"
