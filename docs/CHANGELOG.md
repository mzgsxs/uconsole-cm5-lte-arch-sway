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
- waybar in black and green, with an LTE status module, CPU temperature and RAM usage.
  The CM5 is a BCM2712, but its device tree declares the AVS block as
  `brcm,bcm2711-thermal`, so `bcm2711_thermal` binds and `cpu-thermal` is thermal zone 0 --
  confirmed by decompiling the CM5 DTB rather than inferring from the SoC name.
- foot with a black background and a full 16-colour palette. The section is `[colors-dark]`
  — foot 1.28 rejects the older `[colors]` outright.
- vim with soft tabs and syntax colour; Makefiles keep hard tabs.
- Idle **dims the backlight** rather than using `dpms off`, which does not reverse on this
  panel and presents as a hung machine.

### First boot

- A wizard prompts for a username and password, creates the account with sudo, applies
  the same password to `root` and `alarm`, and disables itself. It runs on its own VT
  (tty7) because `console=tty1` means tty1 receives every kernel printk, which otherwise
  interleaves with the prompt. There is no autologin.
- The wizard also silences kernel printk and systemd status output as belt-and-braces,
  restoring both on exit so later boot diagnostics survive.
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
- Power key: short press blanks the backlight, long press powers off cleanly. The sway
  binding uses `--no-repeat --release`; without `--no-repeat` a held key fired the
  backlight toggle at the 30/s repeat rate and the screen strobed. `uconsole-powerkey-tune`
  sets the AXP `startup` register to 128 ms so systemd's hardcoded 5 s long-press is the
  whole wait rather than ~8 s, and pushes the PMIC's hardware force-off to its 10 s maximum
  so the clean shutdown always beats the unclean cut.
- Added `wireless-regdb` and `iw`; without them brcmfmac errors were 14.5 % of the journal.

### VPN

- Tailscale pre-installed with `tailscaled` enabled. It is deliberately
  **unauthenticated** — no auth key, node key or `tailscaled.state` is baked in, since
  these images are published and a shipped key would let any downloader join the tailnet.
  Verification asserts their absence on every build.

- Tailscale follows the WAN. `uconsole-wan` runs `tailscale debug rebind` and
  `debug restun` after every switch, and a NetworkManager dispatcher hook does the same on
  any interface change, so automatic Wi-Fi/LTE failover is covered too. Without this the
  tunnel stays bound to a path that no longer routes until Tailscale notices by itself.

### Security and resources

- **No autologin.** A login is required at boot, and a short power-button press now locks
  the session with `swaylock` as well as blanking the backlight, so waking needs the
  password. A failure to lock is logged rather than silently leaving the session open.
- **nftables firewall**, drop policy on input, SSH reachable only from private LANs and the
  tailnet. sshd previously listened on every interface with password auth while the machine
  roamed onto public Wi-Fi and a carrier LTE address; restricting the source beats disabling
  password auth, which would have broken the paste-over-SSH workflow.
- A short power press also **silences the keyboard and trackball** so the device can be
  carried without stray input landing in whatever was on screen. The power button is
  excluded from that — silencing it would be an unrecoverable lockout — and waking
  re-enables every input, not just the ones that were silenced.
- **zram configured.** The package was installed but had no `zram-generator.conf`, so it did
  nothing at all — 4 GB of RAM, no swap, and `cgroup_disable=memory` meant an OOM hard-locked
  the machine. Now 4 GB of zstd-compressed swap.
- **`uconsole-kernel-check`.** The kernel is in no pacman repository, so `pacman -Syu` would
  silently never update it. This reports whether the build has fallen behind upstream and
  prints the rebuild command.

### Build correctness

- The image build now **fetches and pins the upstream builder** itself. It previously did
  `cd /work/uconsole-arch` against a gitignored directory that nothing created, so the
  documented quick start only worked on a machine that had cloned it by hand.
- The rootfs SHA-256 is recorded and checked, with an explicit note that Arch Linux ARM
  publishes only a rolling `latest` tarball — so "reproducible" has been softened in the
  README to match what is actually true.
- `boot-manifest.sha256`, `region-hashes.txt` and the image checksum are **generated by the
  build** instead of by hand. Producing them manually risked leaving a stale manifest, and a
  stale *pass* from `verify-card.sh` is worse than no check at all.
- The partprobe shim now always refreshes `/dev/loopNpM` nodes. Partition minors are
  allocated dynamically, so a node left from an earlier `losetup` could point at the wrong
  device and surface as "Can't open blockdev" on a perfectly good partition.

### Terminal

- tmux with TPM, resurrect and continuum pre-installed, and a user service that starts the
  server at login so sessions return after a reboot.
- tmux keeps its **own** appearance: a green status bar with black text at the bottom. An
  earlier version restyled it to black-and-green at the top to match the desktop, which was
  a mistake -- waybar already owns the top of a 576px-tall screen, so that stacked two bars
  together and wasted vertical space.

### Tooling

- `flash-to-sd.sh` writes and ejects; its whole-disk read-back check was **removed**
  because macOS writes Spotlight metadata to the card between `dd` and verification,
  making it fail on every good write.
- `verify-card.sh` verifies correctly instead — raw compare on ext4, file-level on FAT.
- `verify-image.sh` grew from 64 to 265 checks, including config parsing and a post-build
  proof that the image can install packages.

### Fixed along the way

Two classes of bug appeared repeatedly and are worth naming:

- **`grep -q` under `pipefail`** reports success as failure via SIGPIPE. This caused a
  false "kernel lacks Landlock" result.
- **Greps matching comments** give false results in both directions — a check for "no
  hardcoded `gpiochip0`" matched the comment describing the bug it fixed.
