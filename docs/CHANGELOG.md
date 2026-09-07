# Changelog

## Initial release

A working Arch Linux ARM + Sway image for the uConsole with Raspberry Pi CM5, built and
verified from source. This entry records how it got here, since much of the value is in
the reasoning rather than the final file contents.

### Kernel

- Built from `ak-rex/ClockworkPi-linux` pinned at `84258d9b`, packaged as
  `linux-uconsole-cm5-4k-git` (4K pages).
- Patched the upstream PKGBUILD to compile natively on aarch64 — it fell back to a
  cross-compiler prefix even when told not to.
- Enabled `CONFIG_SECURITY_LANDLOCK`, without which pacman 7 refuses to run.
- Enabled `CONFIG_SUSPEND` / `CONFIG_PM_SLEEP`; the stock defconfig registered no sleep
  states at all.
- Added `lsm=landlock,apparmor` to the kernel command line so Landlock is active
  regardless of `CONFIG_LSM`'s default.

### Boot configuration

- Labels renamed to `UCONSOLE` / `uconsole-root` coherently across `mkfs`, `fstab` and
  `cmdline.txt`, with verification cross-checking `cmdline.txt`'s `root=LABEL=` against
  the filesystem's actual label.
- Added `ignore_lcd=1` and `max_framebuffers=2`, absent from the upstream profile and
  present in every known-working reference image.
- Added `fbcon=rotate:1` for console orientation.
- Removed the stock `linux-aarch64` kernel — ~60 MB of unusable `/boot`, and a future
  `-Syu` could have had it rewrite files there.

### Desktop

- Sway with Alt as the modifier (no Super key on this keyboard), no window titles, windows
  opening fullscreen, black background.
- Panel scale **1.25** rather than 1.2, so 1280×720 divides evenly into 1024×576 — a
  fractional scale leaves a partial pixel column at the right edge.
- `WLR_NO_HARDWARE_CURSORS=1` to force software cursors.
- waybar in black and green, with an LTE status module.
- foot with a black background and a full 16-colour palette. The section is `[colors-dark]`
  — foot 1.28 rejects the older `[colors]` outright.
- vim with soft tabs and syntax colour; Makefiles keep hard tabs.
- Idle **dims the backlight** rather than using `dpms off`, which does not reverse on this
  panel and presents as a hung machine.

### First boot

- A wizard on tty1 prompts for a username and password, creates the account with sudo,
  applies the same password to `root` and `alarm`, repoints autologin, and disables itself.
- Root filesystem expansion rewritten: the previous version used `parted -s`, which
  answers *No* to the in-use prompt, then stamped itself complete — stranding 52 GB of a
  64 GB card permanently. Now uses `growpart`, asserts the partition actually grew, and
  stamps only on success.

### LTE

- Replaced the vendor 4G script, which was broken on CM5 four ways: it hardcoded
  `gpiochip0` (a CM4 assumption — the header pins are on RP1, enumerated last over PCIe),
  used libgpiod v1 syntax against v2, released the power line when `gpioset` exited, and
  the unit's `ExecStart=-` masked the whole failure.
- `uconsole-modem-power` detects the chip by label and holds the line with `gpioset -z`.
- `uconsole-modem-connect` sets `raw_ip`, allows roaming, and takes MTU from the bearer.
- `uconsole-wan` switches routing between Wi-Fi and LTE.

### Power and network

- Disabled `systemd-networkd`, which ran alongside NetworkManager managing nothing, added
  two minutes to every boot, and silently prevented time sync — `systemd-timesyncd`
  follows networkd's online signal.
- NTP servers pinned by IP so a first sync does not depend on DNS.
- Voltage-based low-battery guard; the gauge reads ~71 % about an hour before an
  undervoltage cut, so percentage-based logic fires far too late.
- On-demand battery calibration utility that measures real capacity by integrating
  current, stopping safely above the PMU cutoff.
- Power key: short press blanks the backlight, long press powers off cleanly.
- Added `wireless-regdb` and `iw`; without them brcmfmac errors were 14.5 % of the journal.

### Terminal

- tmux with TPM, resurrect and continuum pre-installed, and a user service that starts the
  server at login so sessions return after a reboot.

### Tooling

- `flash-to-sd.sh` writes and ejects; its whole-disk read-back check was **removed**
  because macOS writes Spotlight metadata to the card between `dd` and verification,
  making it fail on every good write.
- `verify-card.sh` verifies correctly instead — raw compare on ext4, file-level on FAT.
- `verify-image.sh` grew from 64 to 182 checks, including config parsing and a post-build
  proof that the image can install packages.

### Fixed along the way

Two classes of bug appeared repeatedly and are worth naming:

- **`grep -q` under `pipefail`** reports success as failure via SIGPIPE. This caused a
  false "kernel lacks Landlock" result.
- **Greps matching comments** give false results in both directions — a check for "no
  hardcoded `gpiochip0`" matched the comment describing the bug it fixed.
