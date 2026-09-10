# Planned work

Things that are designed but not built, with enough detail to pick up cold. Items are
ordered by what unblocks the most, not by size.

Anything here that touches power or the display should be read alongside
[`HARDWARE.md`](HARDWARE.md) first — several obvious-looking approaches are already known
not to work on this board.

---

## 1. Full OTA reflash

**Problem.** Updating this machine means carrying the SD card to another computer. That is
the single biggest friction in the whole workflow, and it is the reason the test device
spent days running hand-copied files that did not match any built image — which in turn
produced at least two wrong conclusions recorded and later retracted in `HARDWARE.md`.

**Why the obvious approach fails.** The machine boots from `/dev/mmcblk0p2` and runs from
it. Writing an image over that device while it is the live root means every page fault
after the first written byte reads whatever `dd` has already put there. systemd, journald
and sshd fault in code continuously, so the write crashes partway and leaves an unbootable
card — needing the physical reflash it was trying to avoid. Staging the image in RAM first
is not an option either: the image is 8 GB and the machine has 3.9 GB.

**The approach that works.** Run entirely from RAM with the card unmounted, then stream the
image from the network straight to the block device so it never has to fit in memory. This
is what OpenWrt's `sysupgrade` and Armbian's `nand-sata-install` do.

Sketch:

1. **Recovery boot mode.** The Raspberry Pi bootloader already loads the kernel and a 15 MB
   initramfs into RAM from `/boot`. Add a `cmdline.txt` switch (or a second `config.txt`
   section) that tells the initramfs *not* to pivot to the real root — it stays on its own
   ramfs, brings up Wi-Fi from a copy of the NetworkManager profile, starts sshd, and waits.
2. **Flash.** From the workstation: `ssh … 'dd of=/dev/mmcblk0 bs=4M'` with the image on
   stdin. Nothing is mounted, so there is no live root to corrupt.
3. **Reboot** into the fresh system, which expands the root filesystem on first boot as
   usual.

**Measured cost.** Taken on this hardware 2026-09-10, over 5 GHz Wi-Fi at −64 dBm:

| | |
|---|---|
| SSH throughput, workstation → device | **12 MB/s** (10.7 and 13.3 in two samples) |
| SD card write | 74.7 MB/s |
| `gunzip` on the CM5 | 438 MB/s output |
| Image, gzip -1 | 8.00 GB → **1.48 GB** (5.4×) |

**The network is the only bottleneck**, by a factor of six over the card. Two consequences
worth designing around:

- **Stream compressed.** Raw, the 8 GB image takes **~12 minutes**. Piped through
  `gzip -1` it measured **42.8 MB/s of image throughput end-to-end — about 3.3 minutes**.
  Most of the image is zeroed free space, which is why the ratio is so high.
- **Don't bother tuning the cipher.** `aes128-gcm` and `chacha20-poly1305` measured 12.1 and
  12.3 MB/s — identical. The CM5's crypto extensions are not the limit, the link is.

**Stage the compressed image in RAM, then write locally.** The raw image never fits in
memory — 4.46 GB runtime against 3987 MB total — and would not even after the boot
partition shrink in item 5. But **compressed it does**, comfortably:

| | Runtime | Dev |
|---|---|---|
| raw | 4.46 GB | 4.83 GB |
| `gzip -1` | **1.34 GB** | **1.53 GB** |
| device RAM | 3987 MB total, 3664 MB available | |

That is worth more than the few seconds it saves. Streaming decompressed straight to the
block device means the network is in the critical path for the *entire* write, so a Wi-Fi
drop at 80 % leaves a half-written card and a machine that will not boot. Staging first
splits it into two phases where only the first can fail recoverably:

1. Transfer 1.34 GB into a tmpfs — ~1.9 min at the measured 12 MB/s. A failure here costs
   nothing; the card is still intact and bootable.
2. `gunzip < /tmp/img.gz | dd of=/dev/mmcblk0` from RAM — ~1 min at the card's 74.7 MB/s,
   with the network no longer involved.

About three minutes either way, but only one of them has a failure mode that bricks the
card mid-write.

One detail for whoever builds it: the default tmpfs is half of RAM (1994 MB here), which
the dev image's 1.53 GB fits but not by much. Mount it with an explicit size — `-o
size=2500m` — rather than relying on the default.

**Risks.**
- The first attempt at a recovery boot is exactly the failure mode that leaves you at a
  black screen, and **this panel already fails silently on cold boot**. Develop it with the
  card physically reachable.
- The recovery initramfs needs the Wi-Fi firmware, `brcmfmac`, `wpa_supplicant`, `dropbear`
  or `sshd`, and `dd`. That is a custom mkinitcpio hook, not a default one.
- Getting the credential into the recovery image without committing it is the same problem
  `secrets/wifi.env` already solves; reuse that path rather than inventing a second one.

**Do not attempt the shortcut** of `dd`-ing the live root and rebooting quickly. It appears
to work on machines with enough free RAM to cache the whole running system and fails on
this one.

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

The last one also gives a measured `PACK_WH`, replacing the nameplate figure that every
runtime estimate currently relies on.
