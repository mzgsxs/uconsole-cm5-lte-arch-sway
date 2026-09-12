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
| Does cutting the modem rail move the floor further than powering the modem down? | `MODEM_RAIL_OFF_ON_BLANK=1`, compare with `uconsole-power-probe run` (the power-key press is already measured at 0.325 W) |
| What does the machine draw while flashing? | `uconsole-power-probe` across an OTA write |

Two that `uconsole-power-budget` opened and cannot close over SSH:

| Question | Why it needs someone at the device |
|---|---|
| What does Wi-Fi cost while awake, as opposed to power-save? | The measurement has to run over a link that is not the one being switched off — from the device's own terminal, or over the modem |
| Does `dtparam=pciex1` cost anything with nothing in the slot? | The 4G module is USB-attached, so the external PCIe controller may be training for nothing. Needs a boot with it removed, and a bad `config.txt` needs the card in hand to fix |

Not worth trying without physical access: a negative `over_voltage_delta`. It would reduce
core voltage at every OPP, and the idle rail sits at the 1.5 GHz point because that is the
lowest OPP BCM2712 has — so it is one of the few remaining levers on the ~2.9 W that is left
once the backlight and panel are off. It is also the one change that can leave the machine
unable to boot, with the only recovery being the SD card in another machine.

Settled, and kept here so nobody re-opens them: the pack's real capacity (18 Wh usable,
measured); whether cpuidle is worth enabling (no — the firmware's retention state is a
WFI, its core power-down is the `CPU_OFF` path that saved −8 mW and does not return, and on
the shipped `bcm2712` branch a power-down idle request asks VideoCore for system suspend; see
`HARDWARE.md`); and whether USB autosuspend is (no — −98 mW in all, the
keyboard −10 mW of it, and the rest on the modem, where autosuspend risks the data link).
