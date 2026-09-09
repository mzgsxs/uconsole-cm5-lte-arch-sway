# Troubleshooting

Problems hit while developing this image, what actually caused them, and how they were
fixed. Several were misdiagnosed first — those detours are kept, because the wrong theory
is usually the more instructive half.

---

## The machine does not boot — black screen, LEDs on

**By far the most likely cause on a CM5 Lite, and it is not the image.**

The bootloader fails to detect the SD card at all
([rpi-eeprom #670](https://github.com/raspberrypi/rpi-eeprom/issues/670)). It reports
`failed to open device 'sdcard'` and never reads the card, so every image fails
identically. It triggers after a complete power-off.

**Symptoms:** LEDs light, nothing on the panel, and two independently built images fail the
same way. Reflashing changes nothing.

**Getting in once, with no extra hardware:**

1. Power off fully and remove the SD card.
2. Power on with no card inserted.
3. Wait a few seconds while the bootloader scans for boot devices.
4. Insert the card while it is still searching.

It may take a few attempts at different timings. A variant that also works: boot with the
card in, wait ~30 s, then pull and reinsert it while powered.

**Making it permanent** — once you have a shell:

```bash
sudo rpi-eeprom-update -a
sudo rpi-eeprom-config -e
```

```
BOOT_UART=1
POWER_OFF_ON_HALT=1
BOOT_ORDER=0xf461
SD_BOOT_MAX_RETRIES=2
SD_QUIRKS=1
```

`SD_QUIRKS=1` disables SD high-speed modes (clock capped at 12.5 MHz) and is the setting
that actually fixes detection — removing it reproduces the failure. `SD_BOOT_MAX_RETRIES`
matters too: the default is **0**, meaning the firmware gives your card exactly one chance.
`BOOT_ORDER=0xf461` reads right-to-left as SD → NVMe → USB → restart; the trailing `f`
makes it loop forever rather than halting, which is *why* the insert-mid-boot trick works.

This lives in EEPROM **on the compute module**, not on the card, so it survives reflashing
and card swaps. If the timing trick never works, the EEPROM must be reflashed externally
with `rpiboot`/`usbboot` using the `recovery5` binaries.

### It is not your SD card

Multiple brands fail identically before the EEPROM fix, and a byte-perfect write still
will not boot. A card that verifies fine in a reader can also fail under the CM5's SD
controller at boot clock rates — but fix the EEPROM before suspecting the card.

---

## Verification says the flash failed, but the card is fine

`flash-to-sd.sh` no longer does a whole-disk read-back comparison, because on macOS it
**always** fails on a perfect write.

The moment `dd` finishes, macOS auto-mounts the FAT boot partition and writes its own
metadata into it (`.Spotlight-V100`, `.fseventsd`). A whole-disk hash therefore differs
from the image every time, and unmounting afterwards cannot undo writes that already
happened.

Use `verify-card.sh` instead. It checks each partition the way that partition can actually
be checked:

- **ext4 root** — raw byte compare. macOS has no ext4 driver and cannot have touched it.
- **FAT boot** — file-by-file against a manifest, ignoring macOS's additions.

Optionally, stop macOS mounting the card at all:

```bash
printf 'LABEL=UCONSOLE none msdos rw,noauto\n' | sudo tee /etc/fstab
```

Reverse with `sudo rm /etc/fstab`. The card then needs `diskutil mount /dev/disk4s1` when
you do want it.

---

## The clock is wrong

Expected on a cold boot: there is no RTC, so the clock is wrong until Wi-Fi associates and
NTP replies — usually under a minute. It self-corrects.

If it *never* corrects, the cause was `systemd-networkd` being enabled alongside
NetworkManager. networkd manages nothing, its `wait-online` times out after two minutes on
every boot, and — the non-obvious part — `systemd-timesyncd` follows networkd's online
signal, so it never polls at all. Both are disabled in this image.

Check with `timedatectl`. If `Universal time` is correct but the displayed time is not, the
timezone is simply unset (the image ships UTC):

```bash
sudo timedatectl set-timezone <zone>
```

---

## pacman fails: "landlock is not supported by the kernel"

pacman 7 sandboxes its downloader with Landlock and refuses to run without it.
`bcm2712_defconfig` leaves `CONFIG_SECURITY_LANDLOCK` off.

Fixed here by enabling it in the kernel build *and* passing `lsm=landlock,apparmor` on the
kernel command line — `lsm=` overrides `CONFIG_LSM` outright, so listing Landlock there
guarantees it is active regardless of what the defconfig chose.

Immediate workaround on an older kernel:

```bash
sudo pacman --disable-sandbox -Syu
```

---

## pacman cannot reach a repository at 127.0.0.1

An early build shipped its build-time local package repository in the image's
`pacman.conf`. That address serves packages during the build and is dead on the device.

`build/customize-image.sh` now strips the stanza, and verification fails if `127.0.0.1`
ever appears in `pacman.conf` again.

To remove it by hand — note the pattern avoids brackets, because backslashes get eaten in
transit and an unescaped `[uconsole-arch]` parses as a character class whose `e-a` is an
invalid range:

```bash
sudo sed -i '/uconsole-arch/,+2d' /etc/pacman.conf
```

---

## The screen goes black after 5 minutes and never comes back

Caused by `output dpms off` as the idle action. On the `cwu50` panel the power-down does
not reverse — no keyboard or trackball input revives it, and it presents as a completely
hung machine. The kernel log shows the panel re-enable never firing.

This image dims the **backlight** instead and never uses `dpms`. If you reintroduce
`dpms off`, validate it on the panel first and keep a documented recovery key.

---

## Cursor leaves pixel residue at the screen edge

Two plausible causes, both addressed:

- **Fractional scaling.** 1280 ÷ 1.2 = 1066.67 leaves a partial pixel column at exactly
  the right edge. The image uses scale **1.25** (1024×576), which divides evenly.
- **Hardware cursor plane.** `WLR_NO_HARDWARE_CURSORS=1` is exported before sway starts,
  forcing software cursors.

If it persists, try `scale 1.0` to rule scaling out entirely.

---

## Kernel messages scribble over the first-boot prompt

Two separate things compete for tty1 during early boot: **kernel printk** (`cmdline.txt`
carries `console=tty1`, so `KERN_ERR` and worse are printed there) and **systemd's own
`[ OK ] Started ...` status lines**. Either will interleave with the account prompt.

The wizard now silences both for its duration and restores them from an `EXIT` trap:

- `console_loglevel` is set to 1 via `/proc/sys/kernel/printk`, so only `KERN_EMERG`
  reaches the console. Only the first of the file's four values is saved and rewritten,
  so the restore is an unambiguous integer.
- `kill -s RTMIN+21 1` tells PID 1 to stop emitting status messages; `RTMIN+20` re-enables
  them.
- `setterm --msg off` stops this particular console accepting kernel messages.
- The unit sets `TTYVTDisallocate=yes` so the VT starts clean.

Silencing is deliberately **temporary**. Permanently quieting the console (`quiet` in
`cmdline.txt`, or dropping `console=tty1`) would also hide the messages you need when a
boot goes wrong — and on this machine the panel is often the only output available.

---

## Power button: long press takes 8 s, and the screen strobes while held

Two unrelated causes.

**The strobing was a missing `--no-repeat`.** The binding was
`bindsym XF86PowerOff exec uconsole-screen-toggle`. Sway repeats a held binding at
the keyboard repeat rate, which this image sets to 30/s — so holding the power button
toggled the backlight about thirty times a second. The binding is now
`bindsym --no-repeat --release`: `--no-repeat` stops the storm, and `--release` means a
long press never toggles at all, because logind powers off while the key is still down
and the release event never arrives.

**The 8 seconds is the PMIC delaying the press.** systemd's long-press threshold is a
hardcoded 5 s — `logind.conf` exposes the `Handle*LongPress=` *actions* but no duration —
and that timer only starts once logind sees the key go down. The AXP's `startup` register
sets how long the button must be held before the PMIC reports a press at all; at 3 s the
whole gesture takes ~8 s.

`uconsole-powerkey-tune` runs at boot and sets two registers on the `axp221-pek` device:

- **`startup` → 128 ms**, so systemd's 5 s is essentially the whole wait.
- **`shutdown` → 10000 ms**, the maximum. This is the PMIC's *hardware* force-off, an
  unclean cut of exactly the kind that previously corrupted the journal and left the FAT
  boot partition dirty. Pushing it to the maximum guarantees systemd's clean shutdown
  always wins the race, leaving the hardware cut as a genuine last resort.

Worth checking on any given unit which of the two actually fired: if the machine cuts at
the `shutdown` value rather than ~5 s, it was the hardware, and the filesystem took an
unclean shutdown.

---

## Screen blanks on a power press and never comes back

Caused by a missing `--locked` on the sway binding. From `sway(5)`:

> Unless the flag `--locked` is set, the command will not be run when a screen locking
> program is active.

Locking and the power-key binding were introduced in the same change, so the instant
`swaylock` started, the key that was supposed to bring the screen back stopped being
delivered. Pressing it again did nothing, however many times.

The binding is now `bindsym --no-repeat --release --locked XF86PowerOff`, and the
brightness and volume keys carry `--locked` too.

A second, compounding hazard was silencing input devices by name — the filter skipped
anything matching `power`/`pek`/`axp`, which is a guess about a device identifier that
cannot be verified in advance. It now silences **pointer devices only** and never
keyboards, so whatever the power key's device happens to be called, it survives.

**Recovering a machine that is stuck black**, over SSH:

```bash
brightnessctl set 50% && swaymsg input '*' events enabled && pkill swaylock
```

A long power press also still powers off cleanly, because logind sees the power key
directly rather than through the compositor.

---

## Black screen after powering on from fully off

The panel failed to initialise. It is a cold-boot problem, not a software one, and it lies
about itself: `status=connected enabled=enabled`, `fb0` present, backlight at its normal
level, nothing on screen. The tell is in dmesg:

```bash
sudo dmesg | grep -E 'cwu50|Receive failed'
```

`[drm] Receive failed` means a DSI command read-back failed during init. Compare the
retries — a bad boot shows about six `regulator isn't ready`, a good one shows one.

**Recover with a warm reboot, not another power cycle.** Press `Ctrl`+`Alt`+`F2`, then
`Ctrl`+`Alt`+`Del`. No login needed. Powering off and on again is another *cold* boot,
which is the case this panel is worst at, so the instinctive fix can loop.

If sway was running, the VT switch matters: a compositor holds the seat, so
`Ctrl`+`Alt`+`Del` alone never reaches the kernel's VT layer.

## The machine powers off when I meant to blank the screen

`POWERKEY_HOLD_MS` in `/etc/uconsole/lowpower.conf` is the hold that triggers a clean
poweroff, 2000 ms by default. Raise it if that is too easy to hit by accident.

```bash
journalctl -t uconsole-powerkey-hold -b
```

A line reading `held 2000ms with the key still down; clean poweroff` means the hold path
fired. If you see nothing there but the machine still powered off after about five
seconds, that was logind's own long-press, which is a hardcoded 5 s and cannot be changed.

## A long press does not power the machine off

If the kernel is healthy, hold for 5 s and logind will do it even when the 2 s path is
unavailable. If the machine is genuinely wedged, the button will not help on a CM5 — see
[the next section](#the-machine-is-frozen-and-the-power-button-does-nothing).

Check what the key is set to with:

```bash
cat /sys/bus/platform/devices/*pek*/startup /sys/bus/platform/devices/*pek*/shutdown
```

Expect `128` and `10000`. If `startup` reads `3000`, `uconsole-powerkey-tune` has not run
and every press is taking three seconds longer than it should. The `10000` is the AXP223's
own 10 s hardware cut. It is kept above a clean shutdown (about 8 s from the press) so it
can never cut a rail mid-unmount, but on a CM5 it was observed not to power the module off,
so do not count on it as a force-off.

## The machine is frozen and the power button does nothing

Expected on CM5, and not a fault in this image. The power button only works while the
kernel is still responding — Raspberry Pi changed the power-control pins between CM4 and
CM5, so the CM4 trick of holding it for ten seconds does not apply.

In order of what to try:

1. **Wait ~15 seconds.** The hardware watchdog is armed by default; a kernel that has
   stopped running resets itself. This is the normal recovery and needs nothing from you.
2. **REISUB**, if the keyboard still responds: hold `Alt`+`SysRq` and press `R` `E` `I`
   `S` `U` `B` with a second between each. `SysRq` is `Print` on this keyboard. This only
   works when the kernel is alive and userspace is not — if the hang took USB down, which
   is what a failed suspend does, the keypresses never arrive.
3. **Pull the batteries.** Still the only guaranteed method, and it means opening the back
   panel.

After any unclean stop, clear the boot partition before doing anything else — the FAT
driver does not self-repair the way ext4 does:

```bash
sudo umount /boot && sudo fsck.vfat -a /dev/mmcblk0p1 && sudo mount /boot
```

To check the watchdog is actually armed:

```bash
cat /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeout
```

If a spurious reboot ever bites you, comment out `RuntimeWatchdogSec` in
`/etc/systemd/system.conf.d/uconsole-watchdog.conf` and run `systemctl daemon-reexec`.

## My session did not come back after a poweroff

```bash
journalctl -t uconsole-session-restore -b
```

Nothing at all means the restore did not consider this a resume. It is gated on the boot
id in the snapshot, so check they differ:

```bash
cat /proc/sys/kernel/random/boot_id
python3 -m json.tool ~/.local/state/uconsole/session.json | grep boot_id
```

Two other causes worth knowing. **The restore runs at login, not at boot** — there is no
autologin, so nothing happens until you log in on tty1. And **a program started in a bare
terminal is never restored**: the snapshot records the terminal's own command line, so
`foot` comes back as a shell. Run things inside tmux if you want them to survive.

If an application is missing from the restore, it may be named in `SESSION_RESTORE_SKIP`,
or the snapshot may predate it — skips are logged either way.

## The machine is frozen and the power button does nothing

Expected on CM5, and not a fault in this image. The power button only works while the
kernel is still responding — Raspberry Pi changed the power-control pins between CM4 and
CM5, so the CM4 trick of holding it for ten seconds does not apply.

In order of what to try:

1. **Wait ~15 seconds.** The hardware watchdog is armed by default; a kernel that has
   stopped running resets itself. This is the normal recovery and needs nothing from you.
2. **REISUB**, if the keyboard still responds: hold `Alt`+`SysRq` and press `R` `E` `I`
   `S` `U` `B` with a second between each. `SysRq` is `Print` on this keyboard. This only
   works when the kernel is alive and userspace is not — if the hang took USB down, which
   is what a failed suspend does, the keypresses never arrive.
3. **Pull the batteries.** Still the only guaranteed method, and it means opening the back
   panel.

After any unclean stop, clear the boot partition before doing anything else — the FAT
driver does not self-repair the way ext4 does:

```bash
sudo umount /boot && sudo fsck.vfat -a /dev/mmcblk0p1 && sudo mount /boot
```

To check the watchdog is actually armed:

```bash
cat /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeout
```

If a spurious reboot ever bites you, comment out `RuntimeWatchdogSec` in
`/etc/systemd/system.conf.d/uconsole-watchdog.conf` and run `systemctl daemon-reexec`.

## Anything involving suspend hangs the machine

`systemctl suspend` is masked in this image and `/sys/power/state` should not be written
by hand. If you unmask it and try anyway, expect a hard hang needing a battery pull, and a
dirty FAT boot partition afterwards:

```bash
sudo umount /boot && sudo fsck.vfat -a /dev/mmcblk0p1 && sudo mount /boot
```

`/sys/power/mem_sleep` reading `s2idle [deep]` does **not** mean suspend works — `deep` is
a firmware stub and `s2idle` wedges the Wi-Fi chip beyond what a driver reload can fix.
Full account in [`HARDWARE.md`](HARDWARE.md) §3.9.

## No Wi-Fi after a blank, or after the battery died while blanked

The low-power blank `rfkill`-blocks Wi-Fi and Bluetooth. If the machine died before waking,
`uconsole-radio-restore` unblocks them at the next boot — it keys on a stamp written
*before* anything is blocked, precisely so a half-finished descent still recovers.

If you are stuck now, and the network is what you would have used to fix it:

```bash
# Ctrl+Alt+F2, log in, then:
sudo uconsole-unstick --unlock
```

That restores backlight, input, audio, CPU and radios, and starts the modem wake. Return
with `Ctrl`+`Alt`+`F1`. Set `RADIO_OFF_ON_BLANK=0` in `/etc/uconsole/lowpower.conf` if you
would rather keep SSH reachable while the screen is off.

## LTE does not come back after waking

Check what the wake actually did — it runs as its own unit and logs every step:

```bash
journalctl -t uconsole-modem-wake -b
```

A healthy wake reads `modem state after power-on: disabled` → `enabling the modem` →
`modem registered` → `bearer reconnected` → `done`. It can legitimately take twenty
seconds to a couple of minutes; the desktop returns immediately and LTE catches up behind
it.

Two failure modes have real history here. **Restoring power state does not enable the
modem** — coming back from ModemManager's low-power state leaves it `disabled`, which
never searches and never registers, so the bearer times out after 90 s. And **the wake
used to be a background subshell**, which sudo killed on exit, so it never ran at all. To
recover by hand:

```bash
sudo mmcli -m 0 --set-power-state-on && sudo mmcli -m 0 --enable
```

## Audio is silent after waking

Fixed, but if you hit it on an older image: the blank used to save the *prior* mute state
and replay it on wake, which latches — once anything leaves the sink muted, every later
cycle faithfully re-mutes it. Clear it with:

```bash
wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && rm -f /run/user/$(id -u)/uconsole-mute.save
```

`uconsole-unstick` does both unconditionally.

## The machine is running on one CPU core

**CPU offlining is one-way on this board.** Bring-up fails with `CPU1: failed in unknown
state : 0x0` and only a reboot recovers. Check with:

```bash
uconsole-lowpower status
```

`CPU_OFFLINE_CORES_ON_BLANK` defaults to `0` for this reason. If you enabled it, disable
it and reboot. On other hardware, test reversibility first — it costs one core if the
answer is no:

```bash
sudo uconsole-lowpower selftest-cores
```

## The blank does not seem to save any power

Measure rather than guess:

```bash
uconsole-power-probe run
```

If the report prints `THE LOW-POWER DESCENT DID NOT ENGAGE`, the blanked phase ran in the
same state as the baseline and only the backlight was switched off. Check:

```bash
journalctl -t uconsole-screen-toggle -t uconsole-lowpower -b | tail
```

If it *did* engage and the saving is still around a watt, that is expected. Measured on
this hardware: backlight ~0.7 W, everything else in the blank ~0.2 W, and a ~3.2 W floor
of SoC, DSI panel and RP1/USB that userspace cannot reach.

## ssh refuses to connect after an OTA flash

**`REMOTE HOST IDENTIFICATION HAS CHANGED`.** Correct, not an attack: a flash writes a new
system, with new host keys. Compare the fingerprint with the one the device shows, then drop
the old key:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub    # on the device
ssh-keygen -R <host>                                 # on the workstation
```

**Nothing answers at all, after flashing the runtime image.** Also expected. The runtime
image ships no Wi-Fi, account or SSH key, so it is sitting at the first-boot wizard, offline.
Finish the wizard at the machine, connect with `nmtui`, then `ssh-copy-id <user>@<host>`.

**The flash seems not to have happened.** `journalctl -b -t uconsole-ota` on the device says
what the hook did this boot. A refused flash logs why and boots the old system; a completed
one shows only `no marker; normal boot`, because the flash boot's own log was on the card it
replaced.

## Lessons that shaped the verification suite

Several checks are written in a non-obvious way because the obvious version was wrong.

**`grep -q` under `set -o pipefail` produces false failures, and the bug is
size-dependent.** `grep -q` exits as soon as it matches, sending SIGPIPE upstream;
`pipefail` then reports the whole pipeline as failed. This produced a false "kernel lacks
Landlock" result on a kernel that had it, and later two false "waybar lacks this module"
results on a binary that had them.

The size dependence is why it keeps recurring: on a small input the upstream process
finishes before `grep -q` exits, so the pipeline succeeds and the mistake stays invisible.
It only shows up once the input is large enough — a multi-megabyte binary — that `grep`
exits first. It has caught this suite out three times.

Checks that scan large output now decompress to a file first and use `grep -c … || true`,
and binary string searches go through the `has_string` helper, which drains its input.

**Greps that match comments are false results in both directions.** A check for "no
hardcoded `gpiochip0`" matched the *comment* explaining the bug being fixed. A check
asserting `dpms off` would have passed against a comment saying we deliberately avoid it.
Checks now exclude comment lines with `grep -vE '^\s*#'`.

**"It built" is not "it works".** The suite verified that packages installed *during* the
build, but never that the resulting system could install packages *after* boot. Two real
defects — the dead repo and missing Landlock — would both have been caught by a single
`pacman -Sy` inside the image. That check now runs at build time.

**Config files need parsing, not grepping.** A `[colors]` section that foot 1.28 rejects
shipped because nothing ran `foot --check-config`. Both `sway --validate` and
`foot --check-config` now run against the shipped configs, and the sway check was itself
validated by injecting a syntax error to confirm it fails.

**`stat` on a missing file passes an arithmetic comparison.** `[[ $(stat -c%u missing) -eq 0 ]]`
is *true*, because `stat` prints nothing and bash treats the empty string as 0 in arithmetic
context. Two ownership checks therefore passed for files that were not in the image at all.
Every `stat`-based check now asserts the file exists first.

**Wait on the container, not the launcher.** Backgrounding `docker run ... &` returns the
shell's exit status immediately, not the container's. Acting on that "success" started a
second build while the first was still extracting the rootfs, and verification then ran
against a half-built image and reported 115 failures. Build scripts now wait on
`docker ps --filter name=...` instead.

**Docker Desktop's shared filesystem lags.** A host-side `rm` of the output image is not
always visible inside the container, so the build removes stale images from *inside*.
