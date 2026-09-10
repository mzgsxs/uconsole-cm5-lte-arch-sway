# Planned work

Things that are designed but not built, with enough detail to pick up cold. Items are
ordered by what unblocks the most, not by size.

Anything here that touches power or the display should be read alongside
[`HARDWARE.md`](HARDWARE.md) first — several obvious-looking approaches are already known
not to work on this board.

---

## 1. Full OTA reflash — **phase 0 implemented**

**Problem.** Updating this machine means carrying the SD card to another computer. That is
the single biggest friction in the workflow, and it is why the test device spent days
running hand-copied files that matched no built image — which produced two wrong
conclusions later retracted in `HARDWARE.md`.

**Why the obvious approach fails.** The machine boots from `/dev/mmcblk0p2` and runs from
it. Writing an image over that device while it is the live root means every page fault
after the first written byte reads whatever `dd` has already put there. systemd, journald
and sshd fault in continuously, so the write crashes partway and leaves an unbootable card.

**The design, and why it needs no network in early userspace.** The original sketch put
Wi-Fi, `wpa_supplicant` and `dropbear` into the initramfs so it could pull the image down
from recovery. That is the fiddliest and least debuggable part of the whole idea, and it is
unnecessary — the *compressed* image fits in RAM (1.34 GB runtime against 3.9 GB), so it
can be staged on the root filesystem while the machine is running normally, then copied
into RAM by the initramfs before the card is touched.

1. **Normal system.** `uconsole-ota` fetches the compressed image to `/var/tmp`, verifies
   its SHA-256, writes a marker to `/boot/OTA-PENDING`, reboots.
2. **Initramfs, before the real root is used.** Marker present → mount root read-only, copy
   the `.gz` into tmpfs, unmount. Nothing is on the card now.
3. `gunzip < /tmp/ota.img.gz | dd of=/dev/mmcblk0` — ~60 s at the card's 74.7 MB/s, with the
   network no longer involved.
4. Reboot. The write replaced the marker along with everything else, so the next boot is
   normal and `uconsole-expand-root` grows the root to fill the card.

The dangerous window shrinks from the whole transfer to 60 seconds of local writing. A
network failure in step 1 costs nothing — the card is untouched and still bootable.

**Measured, on this hardware over 5 GHz Wi-Fi at −64 dBm:**

| | |
|---|---|
| SSH throughput, workstation → device | 12 MB/s |
| SD card write | 74.7 MB/s |
| `gunzip` on the CM5 | 438 MB/s output |
| Runtime image, gzip -1 | 4.46 GB → **1.34 GB** |
| Device RAM | 3987 MB total, 3664 MB available |

Cipher choice is irrelevant — `aes128-gcm` and `chacha20-poly1305` both measured ~12 MB/s,
so the CM5's crypto extensions are not the limit. Default tmpfs is half of RAM (1994 MB),
which the dev image's 1.53 GB fits but not comfortably: mount it with an explicit size.

### Phases

| Phase | State | Deliverable |
|---|---|---|
| 0 | **done, untested on hardware** | Marker check that observes and falls through |
| 1 | | Copy-to-RAM + `umount` of the root, still no writing |
| 2 | | Add the `dd` |
| 3 | | `uconsole-ota` CLI, checksum verification, battery/AC guard |

**Phase 0 is the one that matters**, because the hook runs on *every* boot — a bug there
breaks the machine on a normal boot, not just during an update. What exists now:

- `overlay/usr/local/bin/uconsole-ota-recovery` — mounts `/boot` read-only, logs whether the
  marker is present, unmounts, exits 0. It cannot write: verification asserts the script
  contains no `dd`, `mkfs`, `sfdisk`, `parted` or `gunzip`.
- `overlay/usr/lib/systemd/system/uconsole-ota-recovery.service` — `ConditionPathExists=/etc/initrd-release`
  so it can only ever run inside the initramfs, `Before=initrd-root-fs.target`, with a
  45-second timeout. Nothing Requires it, so a failure is logged and the boot continues.
- `overlay/etc/initcpio/install/uconsole-ota` — an **install** hook, not a runtime one: this
  initramfs runs systemd in early userspace, so the mechanism is a unit, not a `run_hook`.

Fifteen verification checks cover it, including that the built initramfs actually carries
all three files — an install hook present but absent from `HOOKS` is a silent no-op.

### Testing phase 0 — do this with the card physically reachable

The failure mode is a machine that will not boot and shows nothing, and this panel already
fails silently on cold boot, so a black screen will be ambiguous.

```bash
sudo touch /boot/OTA-PENDING && sudo reboot
```

Then after it comes up:

```bash
sudo dmesg | grep uconsole-ota
```

Expect `marker found` and `PHASE 0 -- observing only`. Boot without the marker should log
`no marker; normal boot`. Both must reach a normal desktop.

### Open questions phase 1 depends on

- **Does the panel initialise in the initramfs?** The `kms` hook is present, so early KMS
  may bring it up — which would give visible progress instead of flashing blind.
- **Can the root actually be unmounted at that point?** Phase 0 does not test this; it is
  the whole content of phase 1.

## 2. Escalation timer — standby that ends

`STANDBY_POWEROFF_MIN` is reserved in `/etc/uconsole/lowpower.conf` and read by nothing.

**Why it matters.** A blanked machine still draws ~3.2 W, and that is a floor set by the
SoC, the DSI panel and the RP1/USB tree — not something userspace can reduce further. The
measurements are unambiguous: the whole low-power blank recovers under a watt of a ~4 W
idle. Only being *off* reaches zero, and session restore already exists to make "off"
tolerable.

**Shape.** Arm a transient timer on blank; cancel it on wake. When it fires, re-check AC
(abort if plugged in), let the session snapshot settle, and power off. Everything needed
already exists — `uconsole-session-snapshot` runs continuously and `tmux.service` forces a
resurrect save in `ExecStop`.

**The one thing that can lose work.** A timer that fails to cancel on wake powers the
machine off in the user's hands. Test the cancel path before wiring anything else to it.

---

## 3. Stage 3 — `uconsole-powermode`

`LONGPRESS_ACTION` is reserved and read by nothing. A CLI to choose what a long power press
does: save-and-restore, or plain poweroff.

The mechanism is already settled: the snapshot carries a boot id, so restore happens only
when the id differs from the current boot. `off-now` deletes the snapshot before powering
off. No shutdown hook is needed, which is what makes it cheap.

Known limitation to document rather than solve: the setting applies to any poweroff, not
just a long press. Distinguishing them means taking the power key from logind, and logind's
handler is the one thing that still works when sway has hung.

---

## 4. The cold-boot panel failure

Branch `s2idle-brcmstb-gpio-fix` carries a cwu50 DCS-failure patch that may address the
silent cold-boot black screen documented in `HARDWARE.md`. It is unverified and unbuilt.

This is the highest user-facing impact item here — a machine that looks bricked is worse
than one that drains overnight — but it needs a kernel rebuild and many cold-boot cycles to
show anything, since the failure is intermittent.

---

## 5. Reclaim the boot partition

`/boot` is 512 MiB and holds **29 MB**. That is 483 MB of the remaining slack in every
image, and it is the largest single item left after the shrink step took the runtime image
from 8 GB to ~4.5 GB.

Upstream hardcodes the geometry:

```
parted -s "$LOOPDEV" mkpart primary fat32 1MiB 513MiB
parted -s "$LOOPDEV" mkpart primary ext4  513MiB 100%
```

A 128 MiB boot partition still leaves 4x headroom for the kernel, initramfs and every DTB,
and would put the runtime image just under 4 GB.

Not done because it is more than a two-line `sed`: `build-image-full.sh` generates
`region-hashes.txt` with `fat_boot 1 512` and `ext4_root 513 …` hardcoded to match, and
`verify-card.sh` compares against those offsets. All three have to move together or a card
verifies against the wrong regions — which is worse than a slightly larger image.

## 6. Open measurements

Small, and each one closes a question that is currently guessed at.

| Question | How to settle it |
|---|---|
| Does the boot-time clock ceiling depend on AC vs battery? | One boot on each, read `scaling_max_freq` immediately |
| What does Wi-Fi actually cost during a blank? | `RADIO_OFF_ON_BLANK=0`, compare with `uconsole-power-probe run` |
| Does cutting the modem rail move the 3.2 W floor? | `MODEM_RAIL_OFF_ON_BLANK=1`, same comparison |
| What is the pack's real capacity? | `uconsole-battery-calibrate run` — now that phase 1 terminates |

The last one also gives a measured `PACK_WH`, replacing the nameplate figure that every
runtime estimate currently relies on.
