# Changelog

## Session restore, and a power key you can actually use

Suspend is unreachable on this hardware and a blanked machine still draws ~3.2 W that
userspace cannot switch off, so the only state that reaches zero is **off**. This release
makes "off" tolerable: power down, come back to where you were.

### The machine remembers what was open

`uconsole-session-snapshot` runs under sway and records which applications are open and
where; `uconsole-session-restore` replays it at the next login. Workspace, fullscreen
state, floating geometry and focus.

It snapshots **continuously** rather than saving at shutdown. sway is started by `exec
sway` from `.bash_profile`, not as a systemd user unit, so the user manager cannot order a
hook against it — at poweroff logind SIGTERMs the session scope and sway dies in a race
with anything you write. Recording continuously removes the race, and covers a crash, a
battery pull and the low-voltage guard for free.

What decides a restore is the **boot id** stamped in the snapshot. Nothing is written at
poweroff, so there is no marker to lose and nothing to race.

Out of scope deliberately: the split/tabbed/stacked container tree. Sway has no layout
save/restore — `append_layout` was closed unmerged as swaywm/sway#3022 — so the mechanism
i3-resurrect relies on does not exist here. swayrst, the only sway-native tool in this
space, moves already-running windows rather than relaunching and says outright it knows no
way to identify the same windows after a reboot.

### A 2-second power key

logind's long-press is a hardcoded 5 s: not a kernel setting and not a logind setting,
just `LONG_PRESS_DURATION` in its source, with systemd#28100 the open request to change
that. The AXP223's forced-off offers only 4/6/8/10 s and is parked at 10 s deliberately,
because a clean shutdown takes ~8 s from the press and anything shorter cuts power
mid-unmount.

So the hold is measured by sway, which already sees the key. Three paths now exist and the
shorter ones do not remove the longer:

| | | |
|---|---|---|
| ~2 s | sway | clean |
| 5 s | logind | clean |
| 10 s | AXP223 hardware | unclean, for a wedged kernel |

It fires **while the key is still down**, on a timer — but the timer does not trust the
release event. When it expires it asks the kernel whether the key is still physically
held, so a tap cannot power the machine off even if the release binding is missed
entirely. Every failure lands on doing nothing.

### tmux state survives a poweroff

`tmux.service` now forces a tmux-resurrect save in `ExecStop` before killing the server,
and the continuum interval drops 15 → 5 minutes as the safety net for unclean stops.

This was a real loss, not a theoretical one: a `vim` started after the last 15-minute tick
was gone after a power-button poweroff, and the saved state still showed the pane at a
shell.

### Defects found by testing, not by reading

- **The device lookup matched nothing.** `/axp[0-9]*-pek/` cannot match `axp20x-pek` — the
  `x` in `20x` defeats it. `press()` returned early, no timer was ever armed, and both
  safety tests "passed" because there was nothing to fire.
- **Multi-window placement was wrong and looked right.** The workspace is switched once,
  before the launch, so windows 2..N were born on window 1's workspace; and arrival order
  was zipped blindly against snapshot order. Fixed by giving `place()` the workspace move,
  in the order that works: fullscreen off, move, geometry, fullscreen on.
- **Window pairing worked by luck.** The snapshot recorded tree order (workspace order)
  while Firefox reopens in creation order. Now sorted by `con_id`, which is creation order.
- **A stale lock silently disabled snapshotting** for the whole session. The holder pid was
  already in the file; nothing read it.
- **An allowlist was the wrong default.** `"foot firefox"` meant anything installed later
  silently failed to come back. Inverted to a denylist, empty by default.
- **The uninstalled-app guard would have skipped every XWayland app**, since it checked
  `app_id` and sway reports X11 windows by capitalised WM_CLASS, which never resolves in
  PATH. It now checks the recorded command.
- **Verification wrote into the image it was verifying.** `py_compile` leaves `__pycache__`
  next to the source; now `ast.parse`, plus a check that no bytecode ships.

### Verification

344 → **385 checks**. The new ones cover the session snapshot and restore (boot-id gating,
the lock, workspace placement, no window titles recorded, 0600 permissions), the power key
(both bindings, the kernel key-state guard, device lookup by name), and each specific
defect above so it cannot return.

Two of those checks caught real regressions during this work: the "no sleep states" one
matched a corrected comment that quoted the old claim, and the missing-app check still
grepped for a message that had been reworded. Both are the comment-matching trap this
suite exists to catch.

### Hardware findings

**The DSI panel often fails to initialise on a cold boot** and lies about it —
`enabled=enabled`, `fb0` present, backlight normal, nothing on screen. The tell is
`[drm] Receive failed` in dmesg. A warm reboot fixes it; another power cycle often does
not, which makes the instinctive recovery the wrong move. `Ctrl`+`Alt`+`F2` then
`Ctrl`+`Alt`+`Del`.

That matters here specifically, because session restore encourages powering off and back
on — exactly the operation this panel is worst at.

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
