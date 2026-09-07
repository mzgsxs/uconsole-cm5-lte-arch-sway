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

## Lessons that shaped the verification suite

Several checks are written in a non-obvious way because the obvious version was wrong.

**`grep -q` under `set -o pipefail` produces false failures.** `grep -q` exits as soon as
it matches, sending SIGPIPE upstream; `pipefail` then reports the whole pipeline as failed.
This produced a false "kernel lacks Landlock" result on a kernel that had it. Checks that
scan large output now decompress to a file first and use `grep -c … || true`.

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

**Docker Desktop's shared filesystem lags.** A host-side `rm` of the output image is not
always visible inside the container, so the build removes stale images from *inside*.
