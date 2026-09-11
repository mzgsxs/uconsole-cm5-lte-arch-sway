# Planned work

Things that are designed but not built, with enough detail to pick up cold. Items are
ordered by what unblocks the most, not by size.

Anything here that touches power or the display should be read alongside
[`HARDWARE.md`](HARDWARE.md) first — several obvious-looking approaches are already known
not to work on this board.

---

## 1. OTA reflash — follow-ups

Built, and tested end to end on the machine with both images: a real dev flash took 169 s
from typing `FLASH` to a settled desktop on the new card. Usage and measurements are in
[`USAGE.md`](USAGE.md#reflashing-the-whole-card-over-the-network); what building it found is
in [`CHANGELOG.md`](CHANGELOG.md). Left open:

- **A runtime flash still needs someone at the machine.** The runtime image ships no Wi-Fi,
  account or key, so it comes back offline at the first-boot wizard. Carrying the current
  network connection and an authorised key across the flash — copied into the new image's
  `/boot` and applied once on first boot — would make it truly remote, at the cost of writing
  credentials onto the card's FAT partition, which anyone holding the card can read.
- **The flash boot leaves no log.** The write runs in the initramfs, whose journal lives in
  RAM, onto the card being replaced — so the one boot that matters most is the one with no
  record, and the ~90 s write time is inferred from timestamps either side. Appending the
  hook's log to the *new* boot partition after the write would fix it, at the cost of a
  second write to a card that has just been flashed. Worth it the first time a flash fails.
- **Does the panel initialise in the initramfs?** The `kms` hook is present, so early KMS may
  bring it up — visible progress instead of three minutes of black screen, on a device whose
  panel already fails silently on cold boot.
- **Is 3.7 V the right battery floor?** A guess at "never approaches the 3.4 V cut under the
  sag of a write". Logging the voltage across a flash would settle it.
- **Should the initramfs load the battery driver?** It carries the AXP core but not
  `axp20x_battery`, so its own check has nothing to read and the check at arming is the real
  guard. Adding it means probing another driver on every boot, in the one place a fault is
  hardest to see.

---

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
| What does the machine draw while flashing? | `uconsole-power-probe` across an OTA write |

The last one also gives a measured `PACK_WH`, replacing the nameplate figure that every
runtime estimate currently relies on.
