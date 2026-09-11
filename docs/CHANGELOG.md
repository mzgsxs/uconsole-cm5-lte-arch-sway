# Changelog

## Reflash over the network: `uconsole-ota`

A full image no longer means carrying the card to another computer.

```bash
build/ota-push.sh <user>@<host> out/uconsole-arch-cm5-sway.img   # workstation: stage it
sudo uconsole-ota dry-run                                       # device: rehearse
sudo uconsole-ota flash                                         # device: do it
```

The machine cannot overwrite the card it is running from, so the write happens in the
initramfs: the image is copied into RAM, re-verified, the root is unmounted, and only then
is the card written. Usage, timings and failure modes are in
[`USAGE.md`](USAGE.md#reflashing-the-whole-card-over-the-network).

**Tested end to end on the machine.** The 5.19 GB dev image went over in 160 s, a dry run
passed, and the real flash took 169 s from typing `FLASH` to a settled desktop on the new card
— fresh machine-id, root grown to fill the card, and canary files planted on the old card
gone. A flashed machine has new SSH host keys: `ssh-keygen -R <host>` on the workstation.

Then the runtime image, the same way: pushed in 123 s, rehearsed, flashed, and 20/20 checks
afterwards — including that the dev account and autologin were gone. It comes back offline at
the first-boot wizard, because the runtime image carries no Wi-Fi or key of its own, so a
runtime flash still needs someone at the machine once it has finished.

The hook's log is `journalctl -b -t uconsole-ota`, not `journalctl -k | grep uconsole-ota`:
journald files lines written to `/dev/kmsg` under their identifier, so the message text no
longer contains it — which a first check of the runtime flash scored as "the hook never ran".

Found on the machine:

- **The initramfs hook ran twice per boot.** `Type=oneshot` without `RemainAfterExit`
  returns to inactive, and a second pull-in restarts it. With a write in the path that is
  two concurrent writes onto one card. Guarded twice now, in the unit and in the script.
- **The first dry run failed a good image**: `conv=fsync` on `/dev/null` is EINVAL. The log
  now reports which half of the pipe failed, and what `dd` said.
- **Both battery guards read "battery fitted" as "on AC"**: this PMIC's battery supply reports
  `online=1` whenever a battery is present. They now find AC by supply type and gate on
  voltage (3.7 V) rather than the gauge, as `uconsole-battery-guard` already did.

Found in review, before either could bite:

- **The hook was not ordered against `sysroot.mount`**, which fstab-generator gives the same
  `Before=initrd-root-fs.target`. It now names `sysroot.mount` and refuses if it finds the
  root already mounted.
- **The start timeout was sized for this card, not for SD cards.** 45 s would have killed
  every update here, and even 300 s is shorter than a healthy write on a class-10 card. A
  timeout mid-write lets the boot carry on onto a half-written card, so it is now 30 minutes.

A marker that survives into a normal boot means the update did not happen, and
`uconsole-ota-cleanup` now clears it. Without that, a refused update would re-stage on every
boot and fire an unattended write whenever the refusal stopped applying.

## Images shrunk to fit: 8 GB -> 4.5 GB runtime, 4.9 GB dev

The image is now built at 8 GB and shrunk as the final step, after customisation.

`uconsole-expand-root` grows the root to fill whatever card it is flashed to on first boot,
so image size constrains nothing on the device — but the old 8 GB image carried ~4.4 GB of
zeroes and `dd` wrote every one of them to the card. Measured content is 2.9 GB (runtime)
and 3.4 GB (dev).

**Built big and shrunk, not built small.** Sizing the build to measured final usage failed:
`Partition / too full: 299385 blocks needed, 277133 blocks free`. pacman's peak usage is
about 1.2 GB above the finished content, because it downloads and extracts before cleaning
up.

**Shrunk after `customize-image.sh`, not inside upstream's script.** Upstream's `--minimize`
flag does the same job but runs at the end of *its* script — before our overlay and chroot
step — so it would shrink the filesystem we then write into.

`SHRINK_FREE` (default 256 MiB) controls the free space left in the shrunk root. `tune2fs -m 1`
and a second `resize2fs -M` pass were tried and are kept, but bought only 12 MB — reserved
blocks turn out not to count toward the minimum.

What this does *not* change: compressed transfer. The zeroes compressed away regardless, so
a gzipped image was ~1.48 GB before and after. The win is entirely in writing to a card.

The largest remaining slack is the 512 MiB boot partition holding 29 MB — see
[`ROADMAP.md`](ROADMAP.md), which explains why it is not a two-line change.

## Battery: a hung calibrator, a corrected device tree, and a guard that explains itself

### `uconsole-battery-calibrate` hung in phase 1, on a full battery

It waited for `status == "Full"`. **This driver never sets it.** Measured with the pack at
4.213 V — above the 4.200 V design maximum — gauge at 100 % and charge current tapered to
4–19 mA, `status` still read `Charging`, indefinitely.

Phase 1 now terminates on the CV taper instead: at the voltage ceiling with the current
fallen below `TAPER_UA` (150 mA, ~C/46 on this pack). The condition must hold across three
samples, since charge current is noisy near the end and one low reading is not the taper
finishing. A four-hour deadline replaces the unbounded wait, and says what it last saw
rather than hanging silently.

### The device tree described the wrong battery

The uConsole CM5 overlay hardcodes ClockworkPi's stock 6700 mAh pack, and that value is
what the driver reports as `charge_full_design`. `build-kernel.sh` now patches it at kernel
build time from `BATTERY_MAH` (default 7000, for 2×3500 mAh in parallel), along with
`energy-full-design-microwatt-hours`. The patch is asserted, not assumed — if the property
moves or upstream changes it, the build fails rather than silently shipping the stock
figure. Confirmed in the shipped `.dtbo`: contains 7000000 and 25900000, no longer 6700000
or 24790000.

This does **not** fix the fuel gauge. That reads high because it is uncalibrated
(`calibrate` returns 0), and 6700 mAh was within 4 % of the fitted pack anyway.

### The low-voltage guard now explains itself

A shutdown at "30 % remaining" looks like the guard firing early. It was not: the guard
fired at 3.38 V and 3.357 V, both genuinely flat, both clean. The gauge was wrong.

Both guard messages now print the gauge's claim next to the voltage, so the journal
distinguishes "guard fired early" from "gauge is lying" without a second investigation.
The threshold was briefly lowered to 3.30 V and **put back to 3.40 V**: that margin exists
for the ~8 s clean shutdown against the 305 mV rail sag an LTE burst produces, and LTE was
connected during both events.

Also recorded: after a low-voltage shutdown, charge before powering on. The same incident
produced three boots of ~620 journal lines each, seconds apart — each one dying mid-boot
and leaving the FAT partition dirty.

### `PACK_WH` was still 14.8

Every runtime estimate the probe produced was against a 14.8 Wh pack while 25.9 Wh was
fitted — **all of them ~43 % pessimistic**. Now 25.9, and `uconsole-power-probe pack 2x3500`
is the way to change it.

### Corrected

A capacity-mismatch explanation for the gauge error was published and is withdrawn: it was
computed against 2×2000 mAh cells when 2×3500 mAh were fitted. The device tree's figure was
within 4 %, in the direction that would make the gauge read *low*. The gauge is simply
uncalibrated, which is what §3.5 said in the first place.

### Verification

406/410 → **413 runtime / 417 dev**.

## Two trees, a leaner runtime, and an on-device test harness

### Two images from one source

`BUILD_PROFILE=runtime|dev` selects which tree is assembled. Dev is runtime **plus**
`overlay-dev/` plus `PKGS_DEV` — additive only, so no shipped file has a dev-only variant.
Two parallel overlays containing the same script would let a fix land in one and miss the
other, and the tree that gets tested is usually not the tree that ships.

Dev adds `firefox`, `mpv`, `imv`, `neovim`, `powertop`, `strace`, `tcpdump`, and
`uconsole-selftest`. Wi-Fi comes from an untracked `secrets/wifi.env`; the build reads it
at assembly time, logs neither value, and the runtime image ships no connection profile at
all. This repository is public — a PSK committed here would survive any later removal.

### uconsole-selftest

An on-device harness for what image verification structurally cannot reach: whether the
machine behaves. Every check in it exists because the matching bug shipped once and looked
correct from the outside — masked sleep targets, the sudoers mode sudo ignores silently,
`evtest` being present at all, cores still online, no descent left pending, the snapshot's
boot-id gating, the modem not left in low power.

`--cycle` additionally runs a real blank/wake and asserts the restore. It refuses to run
over SSH when `RADIO_OFF_ON_BLANK=1`, since the blank switches off the network carrying the
session.

### Pruned

- **`parted`'s fallback in `uconsole-expand-root` is gone.** `parted -s resizepart` *is*
  the S3.1 bug — it answers "No" to the in-use prompt and reports success. It was a
  fallback for a case that cannot happen, since `cloud-guest-utils` is a hard dependency.
  Missing growpart is now a hard error that does not stamp, so it retries next boot.
- **The tmux plugin tree: 1.3 MB / 204 files → 288 KB / 66 files**, paid for per user
  account since it is copied from `/etc/skel` into every home. Three full git
  repositories, three test suites, the docs and a `video/` of PNGs — none of which a
  running tmux reads. Pinned commits are written to `PINNED_COMMIT` so versions stay
  knowable without `.git`.
- **`alsa-state.service` masked.** `alsa-utils` is installed for `alsamixer` and
  `speaker-test`; its daemon is "static", so it reads as disabled, but the package
  symlinks it into `sound.target.wants` and udev reaches that target as soon as the card
  appears. It would have run as a resident `alsactl` process on a battery device for no
  benefit — WirePlumber owns mixer state here. `alsa-restore` (a oneshot) is untouched.
- **`uconsole-power-probe sample`** removed: undocumented, called by nothing, scaffolding
  for a bisect harness that was not built.
- `net-tools` dropped from our package list — the Arch Linux ARM base rootfs already
  ships it, so asking for it re-installed something we get anyway.

`parted`, `git`, `htop` and `alsa-utils` are **kept**, judged on size, usefulness and
background cost: 2.8 MB, 46 MB, 480 KB, 3.4 MB, and not one of them runs a daemon. The
only real price is SD space. Verification now asserts them **present**, so a future
leanness pass cannot quietly remove a tool someone reaches for.

### Fixed

- **Five `grep -q`-under-`pipefail` instances in the verification suite itself**, four of
  them `find | grep -q` scanning a whole modules tree. They passed only because the output
  happened to be small enough that `find` finished before `grep` exited — the exact
  size-dependent trap the suite asserts against elsewhere. Now `find -print -quit`.
- `grep -qc` in the power probe, where `-c` is silently ignored under `-q`.
- A count compared with `grep -qE '[4-9]'`, which would break at 10.
- The logind comment still described its 5 s long-press as the primary poweroff path; it
  has been the backstop behind sway's 2 s hold for some time.

### Found by testing on hardware

Two bugs in the new selftest, both found by running it the awkward way rather than the
easy way:

- `findmnt -no SIZE` prints `57.9G`; stripping the suffix leaves `57.9`, and `[[ -gt ]]`
  aborts with an arithmetic error rather than returning a result. Now `-bno`.
- **`HOME` is not guaranteed.** Run as a systemd unit — which is how the cycle test *has*
  to run, since the blank drops SSH — there is no `HOME`, and `set -u` turned a bare
  `$HOME` into an abort partway through the run.

And one regression caught before it shipped: pruning
`tmux-continuum/scripts/handle_tmux_automatic_start/` looked safe — macOS-specific, and
`@continuum-boot` is deliberately unset — but `continuum.tmux` calls that helper on every
load and takes the *disable* branch when the option is off. Unused-looking and unused are
different things.

### Fixed: the low-power descent could latch the CPU at minimum clock

`uconsole-lowpower down` truncated its state file and recorded the **current** governor and
ceiling as "pre-blank" on every descent. A second descent — two power-key presses in quick
succession — recorded the already-clamped `1500000`/`powersave` as the values to restore,
and `up` put them back. The machine ran at 62 % of its clock in the powersave governor
until reboot, and `up` could not help because it was doing exactly what it had been told.

```
after down#1 ceiling=1500000 gov=powersave     <- correct
after down#2 ceiling=1500000 gov=powersave     <- records the CLAMPED values
after up     ceiling=1500000 gov=powersave     <- restores the clamp, permanently
```

`down` no longer re-records while a descent is active, and `up` treats a saved ceiling
equal to the floor as a stale clamp. Four verification checks guard it. Same shape as the
audio-mute latch fixed earlier: saving "what it was" is wrong whenever "what it was" might
already be the state you are about to impose.

### Corrected twice: the 1.5 GHz ceiling

An earlier release documented "the CPU boots capped at 1.5 GHz" as a hardware fact; the
next retracted it as "accumulated state, cause unknown". Both were too confident. There
were two causes and only one was ours — the latch above. The remainder is a firmware
behaviour: the boot-time ceiling is inconsistent between clean boots of the same image
(2400000 on one, 1500000 on another taken on battery), is not thermal or undervoltage, and
is not enforced — writing the higher value raises it and it holds. The battery hypothesis
is recorded in `HARDWARE.md` as untested.

### Verification

385 → **406 runtime / 410 dev**. The profile is now an argument and is cross-checked
against the image contents, so verifying a dev image as `runtime` fails loudly instead of
running the wrong assertions.

Tested on a flashed dev image: **31 passed, 0 failed** including the full blank/wake cycle, with the
modem sequence confirmed unattended — `disabled` → `enabling` → `registered` →
`bearer reconnected` → `done`.

## Power management: suspend closed off, a real low-power blank, and measurement

Everything in this entry was driven by measuring the machine rather than reasoning about
it. Six defects were found that way, and every one of them looked correct from the
outside.

### Suspend is a hazard, and is now unreachable

`/sys/power/state` reads `freeze mem` on this build, so suspend looks available. It is
not, and using it hard-hangs the machine — five attempts, five hangs, four battery pulls,
two dirty filesystems.

- **`deep`** is a PSCI firmware stub. Broadcom never shipped BCM2712's DDR self-refresh
  sequences; what the firmware advertises parks the ARM core for about a second.
  `mem_sleep` resets to `deep` on every boot, so a bare `echo mem` silently takes it.
- **`s2idle`** is real but wedges the SDIO Wi-Fi chip with `-110` backplane timeouts. The
  chip does not come back — a module reload fails on all three SDIO functions; only a
  reboot recovers it.

The five sleep targets are masked, `mem_sleep_default=s2idle` is pinned on the kernel
command line for anything that writes `/sys/power/state` directly, and `systemd-rfkill` is
masked so a radio block cannot outlive the boot that set it. The stale "the kernel
registers no sleep states" comments — which described CM4 and invited every one of those
five attempts — are corrected wherever they appeared.

### A short press now does more than blank the screen

`uconsole-lowpower {down|up|status}` handles what needs root: Wi-Fi and Bluetooth
`rfkill`, the LTE radio via ModemManager's low-power state, the cpufreq governor and clock
ceiling. `uconsole-screen-toggle` keeps the user-context half — backlight, lock, pointer
silencing, mute. A sudoers drop-in grants `wheel` NOPASSWD for that one binary: not a
shell, not `systemctl`, not a wildcard.

Policy lives in `/etc/uconsole/lowpower.conf`. Every knob is individually switchable.

### Recovery that does not need the network

Switching Wi-Fi off during a blank made the documented "SSH in and fix it" advice
self-defeating. `uconsole-unstick` is the replacement, run from `Ctrl`+`Alt`+`F2`: VT
switching is handled by the kernel and logind, so it works when sway has stopped
responding to input, when its inputs were left disabled, and when the network is off.
Confirmed on hardware.

`uconsole-radio-restore` covers the other half — a machine that dies mid-blank comes back
with radios, because the stamp it keys on is written *before* anything is blocked.

### Measurement

`uconsole-power-probe run` measures a baseline, blanks, measures again, wakes and reports
watts, mA and estimated runtime. It refuses to run on AC (charger current swamps the load)
and over SSH (blanking switches off the network carrying the session).

Every sample records the machine's *state* — cores, governor, clock ceiling, Wi-Fi block,
modem power state, backlight — because a descent that silently failed to engage is
indistinguishable, in watts alone, from one that engaged and had nothing to give. The
report says `THE LOW-POWER DESCENT DID NOT ENGAGE` outright when the blanked phase ran in
the same state as the baseline. That is not hypothetical; it caught exactly that.

`uconsole-power-probe pack 2x3500` records which cells are fitted, so a swap is not an
arithmetic exercise. The pack figure was corrected from an inherited 24.79 Wh (wrong for
this hardware) to a measured 14.8 Wh.

### What the measurements actually said

| | |
|---|---|
| Screen on, idle | ~4.1 W measured, not the ~5–7 W previously assumed |
| Backlight | **~0.7 W — about 18 %**, not the "dominant" share the design assumed |
| Governor + clock ceiling + radios | ~0.2 W |
| CPU core parking | unavailable — see below |
| **Remaining floor** | **~3.2 W: SoC, DSI panel, RP1/USB — unreachable from userspace** |

The claim that the backlight dominates idle draw, which justified stopping at the panel,
is false on this hardware and has been corrected in `docs/HARDWARE.md`.

### Six defects found by measuring

- **The entire descent was skipped.** The toggle guarded its privileged call with
  `sudo -n true`, but the sudoers rule grants one binary and nothing else, so sudo
  answered "a password is required" and the guard failed. The screen still blanked and
  locked, so it looked correct while saving only the backlight. **Never probe with a
  different command than the one you intend to run.**
- **CPU cores never came back.** Offlining is one-way on this board: `psci: CPU1 killed`
  succeeds, bring-up fails with `CPU1: failed in unknown state : 0x0`, and only a reboot
  recovers. The machine ran at 1 of 4 cores indefinitely — a later "idle" measurement was
  recorded that way without anyone noticing, because the write on the way *down* returns
  success. Core parking now defaults off, bring-up is verified, and
  `uconsole-lowpower selftest-cores` tests it safely on other boards.
- **Mute latched permanently.** Saving the *prior* mute state and replaying it means that
  once anything leaves the sink muted, every later cycle faithfully re-mutes it. It now
  records its own action; a missing state file means unmute.
- **The modem was never switched off.** Releasing the GPIO power rail is not a power-down
  sequence — the SIM7600 stayed enumerated and nothing checked. Now uses ModemManager's
  low-power state, verified by reading it back.
- **The modem wake was killed every time.** It ran as `( … ) &` inside a script invoked
  through `sudo -n`; since 1.9.14 sudo runs commands in a pty and kills what remains in
  that session on exit. Everything synchronous restored correctly and only the one
  asynchronous step silently never happened. It is now a transient systemd unit.
- **Restoring power state does not enable the modem.** Coming back from low power leaves
  ModemManager's modem `disabled`, which never searches and never registers, so the bearer
  burned its full 90-second wait and gave up. One missing `--enable`.

### Other fixes

- `uconsole-wan` now persists its routing mode to `/var/lib/uconsole/wan-mode`. It lived
  in `/run`, so cycling the modem — or any reboot — silently dropped you back to the boot
  default.
- `verify-image.sh` could not run standalone: it called `partprobe`, which the base
  container does not ship, and parsed JSON with a `python3` it does not have. Both
  dependencies are gone; the documented build steps now work from a fresh clone.
- A fourth and fifth instance of **`grep -q` under `pipefail`** were found and fixed.

### Verification

265 → **344 checks**. The new ones assert the locks (sleep targets masked, `mem_sleep`
pinned), the wake path (governor, mute, radios, backlight *to the same value*, standby
timer), the privilege boundary (sudoers drop-in root-owned and 0440 — sudo silently
ignores it otherwise), and each specific defect above so it cannot return.

Structural verification still proves only that files are in place. Every behavioural claim
here was confirmed on hardware.

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
