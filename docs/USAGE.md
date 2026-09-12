# Using the image

## First boot

The machine prompts on tty1 for a **username and password**. That account gets sudo via
`wheel`, and the same password is applied to `root` and to the stock `alarm` account.
The wizard then disables itself.

**There is no autologin.** Every boot presents a login prompt; sway starts once you log in
on tty1. A short press of the power button blanks the backlight, **locks the session,
silences the trackball, and puts the machine into low power** — radios off, CPU governor
switched to powersave — so it can sit in a bag without stray input reaching your work and without
draining the pack. Pressing it again restores everything and asks for your password. See
[Low-power blank](#low-power-blank) for what exactly gets switched off.

Only **pointer** devices are silenced — the trackball, which is what actually generates
spurious events rolling around in a bag. Keyboards are deliberately left alone: the power
key is a keyboard-type device whose identifier cannot be predicted reliably, and silencing
it would be unrecoverable. Keyboard input is not a hazard anyway, because swaylock holds the
session and keystrokes go to the password prompt rather than to your work.

### If you are ever stuck at a black screen

Press **`Ctrl`+`Alt`+`F2`**, log in, and run:

```bash
uconsole-unstick
```

That restores the backlight, re-enables every sway input, brings any offlined CPU cores
back, clears the frequency clamp and unblocks the radios. Add `--unlock` to dismiss
`swaylock` too. Return to the desktop with `Ctrl`+`Alt`+`F1`.

Use the second virtual terminal rather than SSH. VT switching is handled by the kernel and
logind, so it works when sway has stopped responding to input, when sway's inputs have
been left disabled, **and when the network is off** — which matters because the low-power
blank is itself capable of switching the radios off. SSH works too when there is a
network, and `uconsole-unstick` behaves identically over it.

Holding the power key still shuts down cleanly from here too. The ~2 s path needs sway, but
logind's 5 s and the AXP223's 10 s hardware cut do not — see [The power button](#the-power-button).

Two other things happen on first boot without any input:

- The root filesystem expands to fill the card.
- The clock corrects itself once Wi-Fi associates — usually within a minute. There is no
  RTC, so this repeats on every cold boot. Opening a browser in that first minute may
  produce a TLS certificate warning; it resolves itself.

## Desktop

Alt is the modifier throughout — the uConsole keyboard has no Super key.

| Keys | Action |
|---|---|
| `Alt`+`Enter` | Terminal (foot) |
| `Alt`+`d` | Launcher (fuzzel) |
| `Alt`+`q` | Close window |
| `Alt`+`f` | Toggle fullscreen |
| `Alt`+`1`…`9`, `Alt`+`0` | Switch to workspace 1–10 |
| `Alt`+`h/j/k/l` or arrows | Move focus |
| `Alt`+`Shift`+ number | Move window to that workspace |
| `Alt`+`Shift`+`h/j/k/l` | Move window within the layout |
| `Alt`+`Shift`+`c` | Reload sway config |
| `Print` | Region screenshot |
| Power button (tap) | Blank, lock and enter low power; press again to restore |
| Power button (~2 s) | Clean poweroff — fires while you are still holding |

The trackball has no scroll wheel: **hold the right button and roll** to scroll.

Windows open fullscreen, which covers waybar. If you would rather see the status bar,
comment out the two `fullscreen enable` lines in `~/.config/sway/config` — with
`default_border none` a single window already fills the workspace.

The screen dims after 5 minutes of idle and returns on any key or trackball movement. It
deliberately does **not** use `dpms`, which does not come back on this panel.

## tmux — sessions survive reboots

TPM, tmux-resurrect and tmux-continuum are pre-installed; no `prefix + I` needed.

```bash
ta          # attach to the restored session, or start one
```

tmux keeps its stock appearance — green status bar at the bottom — deliberately, so it sits
opposite waybar rather than stacking a second bar at the top.

A `tmux.service` user unit starts the server at login, and continuum restores into it — so
after a reboot your session is already back and `ta` just attaches. Pane contents and
running programs come back, not merely the layout.

**Saving happens on the way down, not only on a timer.** `tmux.service` forces a
tmux-resurrect save in `ExecStop` before the server is killed, so a poweroff — by power
button, `systemctl poweroff`, or the low-voltage guard — keeps what you had. Continuum's
own interval is 5 minutes and exists as the safety net for *unclean* stops that `ExecStop`
cannot help with: a crash, a battery pull, a forced power cut.

That distinction is not academic. With the timer alone, a `vim` started after the last tick
was simply gone after a poweroff, and the saved state still showed the pane at a shell.

To save immediately: `prefix + Ctrl-s`. To restore by hand: `prefix + Ctrl-r`.

## LTE

```bash
sudo uconsole-modem-power status      # is the module powered and enumerated?
sudo uconsole-modem-power enable      # power it on
sudo uconsole-modem-power disable     # release the power line
```

The modem powers on at boot via `uconsole-modem-power.service`, and
`uconsole-modem-connect.service` brings up the bearer with `raw_ip`, roaming allowed and
MTU 1280. Both are enabled by default; `systemctl disable` either if you would rather the
radio stayed off.

### WAN routing

```bash
uconsole-wan status        # which path is live (no root)
uconsole-wan test          # ping, HTTPS, DNS, RTT, public exit IP (no root)
sudo uconsole-wan lte      # route everything via LTE (metric 100)
sudo uconsole-wan wifi     # Wi-Fi only — drop the LTE default route
sudo uconsole-wan auto     # LTE as failover (metric 700, below Wi-Fi)
```

The bearer stays connected in every mode; only routing changes, so switching is
instantaneous and standby costs roughly 4 MiB/month.

`uconsole-wan test` reporting the **public exit IP** is the quickest way to confirm traffic
is really leaving where you think it is.

**Limitation of `auto`:** metric-based failover reacts to a route being *withdrawn*. Wi-Fi
that stays associated to a dead uplink keeps its route, so nothing fails over. Treat `auto`
as "failover if Wi-Fi drops", not "failover if the internet breaks".

## Battery

A voltage-based guard runs every 30 seconds: it warns at 3.50 V and shuts down cleanly at
3.40 V with a 30-second grace period, aborting if you plug in. It is voltage-based on
purpose — the gauge's percentage is not trustworthy on this hardware.

```bash
uconsole-battery-calibrate status     # gauge state, and a voltage/percentage cross-check
sudo uconsole-battery-calibrate run   # guided charge -> measured discharge -> recharge
uconsole-battery-calibrate report     # results and a voltage -> charge table
uconsole-battery-calibrate soc 3900000 -900000   # voltage (+current) -> charge left
sudo uconsole-battery-calibrate apply # write calibration where the driver allows
```

**The percentage reads high — measured, at every level** (`calibrate` reads 0; the gauge has
never been calibrated). A full discharge put it 10 points high at 82 % charge, 24 high at
43 %, and 35 high at 15 %: it still said 49 % minutes before the guard fired. A shutdown at
"30 % remaining" is the gauge being wrong, not the guard being early, and the journal prints
both numbers together so the two can be compared directly.

**And less of the pack is reachable than the nameplate suggests.** The same run measured
4.47 Ah / 16.5 Wh to 3.50 V resting. Two 3500 mAh cells are rated down to a ~2.7 V cutoff
this machine never reaches — it stops at 3.40 V — so the nameplate is not the number to plan
around; this one is. `report` corrects for the pack's measured 68 mΩ, so a discharge that
ended under load is not read as an empty battery, prints the voltage → charge table, and
saves it to `/var/lib/uconsole/battery-calibration/table.tsv`. Compare its "resting V"
column against a voltage read while the machine is idle, not busy.

If the guard fires, **charge before powering on again**. A pack flat enough to trigger it
will usually die part-way through the next boot, and every attempt that does leaves the FAT
boot partition dirty.

`status` is safe any time and immediately tells you whether the gauge is lying. `run`
measures real pack capacity by integrating current, stopping at 3.50 V so it can never
trigger the undervoltage cut. It refuses to start quietly while the LTE modem is powered,
because transmit bursts both corrupt the measurement and risk a crash.

## Tailscale

Pre-installed with `tailscaled` enabled, but **not authenticated**. The daemon runs and
does nothing until you connect it to a tailnet:

```bash
sudo tailscale up
```

That prints a login URL. Authenticate in a browser — on the device, or by copying the URL
elsewhere — and the machine joins your tailnet.

```bash
tailscale status          # peers and connection state
tailscale ip -4           # this machine's tailnet address
sudo tailscale down       # disconnect, leaving the daemon running
```

**No identity ships in the image.** There is no auth key, no node key and no
`tailscaled.state` — deliberately, because these images get published and a baked-in key
would let anyone who downloaded one join your tailnet. Verification asserts their absence
on every build.

### Following the WAN

Tailscale binds its UDP sockets against whichever default route existed when it started,
and discovers its public endpoints through that path. Switching the WAN therefore leaves it
talking over a route that no longer exists until its own link monitor catches up — the
tunnel can black-hole for anywhere from seconds to a minute.

This image nudges it explicitly. After any switch, `uconsole-wan` runs `tailscale debug
rebind` (re-opens the sockets on the new path) and `tailscale debug restun` (forces endpoint
rediscovery so peers relearn the address). You will see `tailscale: rebound and re-STUNed
onto the new path` in the output.

Explicit switches are only half the problem, so a NetworkManager dispatcher hook at
`/etc/NetworkManager/dispatcher.d/50-uconsole-tailscale` does the same on *any* interface
change — Wi-Fi dropping and LTE taking over under `uconsole-wan auto`, roaming to a
different access point, or the modem re-establishing its bearer. Both paths call
`uconsole-tailscale-nudge`, which is a silent no-op when Tailscale is not connected.

`uconsole-wan status` shows the Tailscale address, and `uconsole-wan test` pings a tailnet
peer through the tunnel — the quickest way to confirm the underlay actually survived a
switch.

**One caveat.** `uconsole-wan lte` makes the carrier's DNS authoritative for all lookups
(`~.` on the LTE interface). If you run Tailscale with MagicDNS, both want to own `~.` and
name resolution can flap. If that bites you, either use `uconsole-wan auto` instead (which
does not claim `~.`) or run `tailscale up --accept-dns=false`.

Two notes specific to this hardware:

- Tailscale defaults its interface MTU to 1280, which happens to match exactly what the
  LTE bearer advertises — so it works over the modem without further tuning.
- The legacy `iptable_filter`/`iptable_nat` kernel modules are absent, so Tailscale uses
  the nftables path. `nft` and `iptables-nft` are both installed.

If you want this machine to act as an exit node or subnet router, that additionally needs
IP forwarding enabled — not on by default, since it changes how the box treats traffic:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

## Security

**Login is required** at boot and whenever you wake the device from a short power-button
press. Waking shows `swaylock`; type your password to get back in. If `swaylock` ever fails
to start, the screen still blanks but the session is *not* locked — that case is logged to
the journal under `uconsole-screen-toggle` rather than failing silently.

The idle timeout (5 minutes) only dims the backlight; it does **not** lock. If you want idle
to lock too, add `timeout 600 'swaylock -f -c 000000'` to the `swayidle` line in
`~/.config/sway/config`.

An **nftables firewall** runs by default with a drop policy on input. SSH is reachable only
from private LANs (`10/8`, `172.16/12`, `192.168/16`) and the tailnet (`100.64/10`) — never
from a public or carrier-assigned address. The tailnet interface itself is fully trusted.
Password authentication stays enabled, because the firewall is what closes the exposure:

```bash
sudo nft list ruleset          # what is actually loaded
```

## Low-power blank

A short power press does more than blank the screen. It locks the session, silences the
trackball, mutes audio, blocks Wi-Fi and Bluetooth, powers the LTE modem down, clamps the
CPU to minimum frequency and takes cores 1–3 offline. Pressing again reverses all of it.

Policy lives in `/etc/uconsole/lowpower.conf`; every knob can be turned off individually.

```bash
uconsole-lowpower status         # what is currently switched off
journalctl -t uconsole-modem-wake -b   # what the last wake did to the modem
```

The modem wake runs as its own transient unit rather than a background job, so it survives
the key-binding process that started it and its progress is in the journal.
`sudo uconsole-lowpower selftest-cores` tests whether CPU core parking is reversible on
your board — it is not on this one.

**LTE takes a while to come back.** Re-powering the module and re-registering can take
anywhere from twenty seconds to the three-minute unit timeout. The wake path never blocks
on it — the desktop returns immediately and data catches up behind it. Your
`uconsole-wan` routing mode is re-applied automatically once the bearer is back. Set
`MODEM_OFF_ON_BLANK=0` if you blank in short bursts and would rather keep the bearer
alive.

**Wi-Fi off means no SSH while blanked.** That is why the recovery path is
`Ctrl`+`Alt`+`F2` rather than SSH — see above. Set `RADIO_OFF_ON_BLANK=0` to keep the
machine reachable.

## Coming back where you left off

There is no suspend on this hardware, and a blanked machine still draws ~3.2 W of SoC,
DSI panel and RP1 that userspace cannot switch off. The only state that reaches zero is
**off** — so instead of sleeping, this image powers off and puts your desktop back.

Nothing to run and nothing to remember. `uconsole-session-snapshot` records what is open
while sway runs; `uconsole-session-restore` replays it at the next login.

```bash
journalctl -t uconsole-session-restore -b     # what came back, and where
```

**What decides a restore is the boot id.** The snapshot carries the one it was written
under; a differing one means the machine went down and came back. Nothing is written at
shutdown, so a crash, a battery pull and the low-voltage guard all restore identically to
a deliberate poweroff.

**It restores at login, not at boot.** There is no autologin, so the sequence is power on
→ log in → desktop returns.

| Restored | Not restored |
|---|---|
| Which applications were open | The split/tabbed/stacked container tree |
| Which workspace each window was on | Anything *inside* an application |
| Fullscreen, floating, geometry, focus | Programs started in a **bare** terminal |
| tmux terminals, reattached to their session | |

That last exclusion is the one to know: the snapshot records the *terminal's* command
line, so a plain `foot` comes back as a shell and whatever you were running inside it is
gone. Running things inside **tmux** is what makes them survive, which is why tmux ships
pre-configured. Firefox restores its own tabs and windows; a `policies.json` sets
`browser.startup.page=3` so it will.

Sway has no layout save/restore of its own — `append_layout` was
[closed unmerged](https://github.com/swaywm/sway/pull/3022) — which is why the container
tree is out of scope rather than merely unimplemented.

Policy lives in `/etc/uconsole/lowpower.conf`:

```bash
SESSION_RESTORE=1          # 0 disables it entirely
SESSION_RESTORE_SKIP=""    # app_ids NOT to relaunch; empty restores everything
SESSION_RESTORE_MAX=10     # cap on how many applications a restore will launch
```

`SESSION_RESTORE_SKIP` is a **denylist** on purpose. An allowlist has to be edited every
time you install something, and until you do, that application silently fails to come
back with nothing said anywhere.

## The power button

```
tap        blank, lock, radios and CPU down
~2 s       clean poweroff, while you are still holding
5 s        clean poweroff (logind, if the 2 s path is unavailable)
10 s       hardware power cut (AXP223) — unclean, for a wedged kernel only
```

The 2 s threshold is `POWERKEY_HOLD_MS` in `/etc/uconsole/lowpower.conf`.

The shorter paths do not remove the longer ones. logind's 5 s is a compile-time constant
with no setting in any systemd version ([systemd#28100](https://github.com/systemd/systemd/issues/28100)),
and the AXP223 register offers only 4/6/8/10 s — parked at 10 s deliberately, because a
clean shutdown takes about 8 s from the press and anything shorter would cut power
mid-unmount. So the 2 s path is measured by sway, which already sees the key.

It fires on a **timer**, but the timer does not trust the release event: when it expires
it asks the kernel whether the key is still physically held. A tap therefore cannot power
the machine off even if the release binding is missed entirely, and every failure — no
device, `evtest` missing, key already up — lands on doing nothing.

## Checking the machine actually works (dev image)

The dev image ships `uconsole-selftest`. It checks what image verification cannot —
that the machine behaves — and every check in it exists because the matching bug shipped
once and looked correct from outside.

```bash
uconsole-selftest            # read-only; safe any time, over SSH included
uconsole-selftest --cycle    # plus a real blank/wake cycle, asserting the restore
```

`--cycle` refuses to run over SSH when `RADIO_OFF_ON_BLANK=1`, because the blank switches
off the Wi-Fi carrying the session. To run it remotely anyway, detach it and arm a
dead-man's switch so a failed wake cannot strand the device:

```bash
sudo systemd-run --unit=uc-watchdog --collect --on-active=150 /usr/local/bin/uconsole-lowpower up
```

```bash
sudo systemd-run --unit=uc-cycle --collect /bin/bash -c 'uconsole-selftest --cycle --force-ssh > /tmp/cycle.log 2>&1'
```

Then reconnect and read `/tmp/cycle.log`.

## Measuring power draw

```bash
uconsole-power-probe run          # baseline -> blank -> wake -> report
uconsole-power-probe watch        # live readings, one line per interval
uconsole-power-probe report       # re-print the most recent run
```

`run` measures two minutes with the screen on, blanks the machine, measures five more,
wakes it and prints a comparison with estimated runtime on the pack. Defaults are
adjustable: `--baseline SEC`, `--blank SEC`, `--interval SEC`.

Two things it refuses to do, both because they produce confident wrong answers. It will
not run **on AC** — charging current swamps load current. And it will not run **over SSH**
— blanking switches Wi-Fi off, so the session watching the measurement is the one thing
guaranteed not to survive it. Start it from the uConsole's own terminal and leave the
machine alone until it wakes itself.

Absolute figures include the sampler's own overhead, which is not nothing on a machine
clamped to one core under a watt. **Trust the difference between phases, not the
absolutes.**

### After a cell swap

Runtime estimates use `PACK_WH` from `/etc/uconsole/lowpower.conf`. Don't edit it by hand
and don't redo the arithmetic — tell the tool what's fitted:

```bash
sudo uconsole-power-probe pack 2x3500
```

| Cells (parallel) | `PACK_WH` |
|---|---|
| 2 × 2000 mAh | 14.8 Wh |
| 2 × 3500 mAh — **fitted** | 25.9 Wh |

`uconsole-power-probe pack` with no argument shows what's currently set. A bare number
(`pack 20.35`) sets watt-hours directly, which is what you want after measuring the pack
for real.

Nothing safety-critical reads this value — the low-voltage guard is voltage-based and
never consults it. The estimate it produces is an **upper bound**: the guard shuts down at
3.40 V, well above where an 18650 is actually empty, so several percent of nominal energy
is never available to you. Nameplate capacity is optimistic too, especially on used cells,
so `sudo uconsole-battery-calibrate run` gives a truer figure than any datasheet.

> **Pairing cells.** The AXP223 is a single-cell PMIC: it sees the parallel pair as one
> cell and balances nothing. Fit two cells of the **same capacity, age and charge level**.
> A 3500 mAh cell wired alongside a 2000 mAh one dumps current into it the moment they're
> connected, and the pair drifts further apart with every cycle. Pair like with like.

## Updating the machine

For anything short of a full image — scripts, config, even the kernel package and its
device-tree overlay — a targeted update over SSH is the right tool:

```bash
sudo pacman -U /tmp/linux-uconsole-cm5-4k-git-*.pkg.tar.xz
```

That covers every change except the base package set and a clean filesystem. A kernel or
device-tree change needs a reboot to take effect.

### Reflashing the whole card, over the network

A full image no longer means carrying the card to another computer. From the workstation
that built it:

```bash
build/ota-push.sh <user>@<host> out/uconsole-arch-cm5-sway.img
```

The image is compressed as it is sent, so a 4.79 GB image is 1.38 GB on the wire. Nothing
is armed by that command — it stages and checks the image and stops. Then, on the device:

```bash
sudo uconsole-ota dry-run
```

**Do the dry run.** It is the same code path as the real thing with the output going to
`/dev/null`: it stages the image into RAM, verifies it, unmounts the root and decompresses
all of it, then throws the result away and boots normally. It costs about 40 seconds and it
is the difference between finding a problem now and finding it with a half-written card.
The very first dry run failed — on a bug in the dry run itself — and the card was never at
risk.

When that comes back clean:

```bash
sudo uconsole-ota flash     # asks you to type FLASH, then reboots
```

`uconsole-ota status` shows what is staged, what is armed, and whether the machine is fit
to write. `uconsole-ota cancel` disarms.

### Driving it from the workstation

`ota-push.sh` calls plain `ssh`, so ssh has to find the device's key on its own. If the key
is not one of ssh's default names, give the device an alias once — without a `User` line,
because the account depends on which image is running:

```bash
cat >> ~/.ssh/config <<'EOF'

Host uconsole
    HostName <device-ip>
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes
EOF
```

| Image running now | Account to use | Its `sudo` |
|---|---|---|
| dev | `DEV_USER` from `secrets/dev-account.env` | no password |
| runtime | the one its first-boot wizard created | asks for the password |

The account is always that of the image being *replaced*, not the one being flashed. The
whole sequence then runs from the workstation, with `-t` so that `sudo` and the `FLASH`
confirmation can reach your terminal. The dry run offers to reboot; afterwards its log should
end with `DRY RUN OK`.

```bash
build/ota-push.sh <user>@uconsole out/uconsole-arch-cm5-sway-dev.img
```

```bash
ssh -t <user>@uconsole sudo uconsole-ota dry-run
```

```bash
ssh <user>@uconsole journalctl -b -t uconsole-ota
```

```bash
ssh -t <user>@uconsole sudo uconsole-ota flash
```

Use `out/uconsole-arch-cm5-sway.img` to flash the runtime image instead. A dev image comes
back on the network by itself; a runtime one does not — see below.

### What actually happens

The machine cannot overwrite the card it is running from — every page fault after the first
written byte would read whatever `dd` had already put there. So the write happens in the
initramfs, before the real root is ever mounted:

1. `uconsole-ota` stages the compressed image on the root filesystem, records its SHA-256
   and writes `/boot/OTA-PENDING`.
2. On the next boot, before the root is mounted, the initramfs hook copies the image into a
   tmpfs, re-checks its SHA-256, and unmounts the root. **The card is now free.**
3. It decompresses the image straight onto `/dev/mmcblk0` and reboots.
4. The write replaced the marker along with everything else, so the next boot is an ordinary
   one, and `uconsole-expand-root` grows the root to fill the card.

Measured on this hardware over 5 GHz Wi-Fi at −64 dBm:

| | |
|---|---|
| Transfer, 4.79 GB runtime image → 1.38 GB on the wire | 123–136 s (three runs) |
| Stage into RAM at boot | 15–17 s at 91 MB/s |
| SHA-256 of 1.38 GB | 1 s (1.3 GB/s — the SoC has crypto extensions) |
| Decompress 4.79 GB / 5.19 GB | 22 s / 25 s, at 205–220 MB/s |
| Transfer, 5.19 GB dev image → 1.62 GB | 160 s |
| Write to the card | ~85 s (4.79 GB) to ~90 s (5.19 GB) — inferred from timestamps; the flash boot's own log cannot survive it |
| Typing `FLASH` → settled desktop on the new card (dev) | **169 s** |
| Typing `FLASH` → runtime image booting to its first-boot wizard | ~135 s |

So a full reflash is two to three minutes of transfer that can be interrupted harmlessly,
then about three minutes of reboots — of which only the ~90 seconds of writing cannot.

### When it refuses, and when it cannot

The write refuses to start without a recorded checksum, and without either AC or a battery
above 3.7 V — losing power during those ninety seconds leaves a card that has to be
reflashed from another computer, which is the exact situation this feature exists to avoid.
The floor is a voltage because the gauge on this machine has read 30%+ moments before an
undervoltage cut. It is checked when arming. The initramfs checks again when it can, but it
does not carry the battery driver, so in practice the check at arming is the guard — reboot
promptly after arming rather than leaving the machine armed on battery.

If anything goes wrong before the write starts — no staged image, a bad checksum, too little
RAM — the boot continues normally and the card is
untouched. `journalctl -b -t uconsole-ota` says why — the hook's own lines and the
cleanup's together — and the marker is cleared so the machine does not retry it on every
subsequent boot. Not `journalctl -k | grep uconsole-ota`: journald files lines written to
`/dev/kmsg` under their identifier, so the message text no longer contains it. `dmesg` works.

If the write itself fails part-way there is no recovery on the device: the card holds an
incomplete image and must be written from another computer. That is the one failure this
design cannot engineer away, and it is why the battery guard is deliberately conservative.

Tested end to end on this machine with both images, each pushed, rehearsed with a dry run,
then flashed for real. Each new card came up with a fresh machine-id and host keys, the root
grown to fill it, and its OTA files byte-identical to the repo, and canary files planted on
the old root and boot partitions were gone — the card was rewritten, not just rebooted. The
dev flash came back with autologin; the runtime flash came back with neither the dev account
nor autologin, as it should.

**After a flash the machine has new SSH host keys**, so the workstation's next `ssh` refuses
with a host-key warning. That is the right behaviour, not a fault: remove the old key with
`ssh-keygen -R <host>`, and compare the new fingerprint with the one the device shows.

**Flashing the runtime image takes the machine off the network.** The runtime image carries
no Wi-Fi, account or SSH key — deliberately — so after the flash it sits at the first-boot
wizard, offline, until someone is at it: finish the wizard, connect with `nmtui`, clear the
old host key as above, then install a key for the new account:

```bash
ssh-copy-id <user>@<host>
```

That account's `sudo` asks for its password, so the next `uconsole-ota flash` is armed from
a terminal that can answer it. `ota-push.sh` itself needs no root.

## Suspend — do not use it

`systemctl suspend` will not work, and that is deliberate. The sleep targets are masked
in this image.

If you look at `/sys/power/state` you will see `freeze mem` and reasonably conclude
suspend is available. It is not. `deep` is a firmware stub with no DDR self-refresh behind
it, and `s2idle` reliably wedges the Wi-Fi chip badly enough that only a reboot recovers
it. Five attempts produced five hard hangs and two dirty filesystems. The full account is
in [`docs/HARDWARE.md`](HARDWARE.md) §3.9.

If you unmask the targets anyway, do not run a bare `rtcwake -m mem`: read
`/sys/power/mem_sleep` first (it resets to `deep` on every boot), and bisect with
`/sys/power/pm_test` rather than power-cycling.

## Keeping the kernel current

```bash
uconsole-kernel-check
```

The kernel is built from source and served by **no** pacman repository, so `pacman -Syu`
updates all of userspace and silently leaves the kernel where it is, forever. This helper
compares the installed build against upstream `ak-rex/ClockworkPi-linux` and prints the exact
rebuild command when it has fallen behind. Worth running occasionally — nothing else will
tell you.

## Networking

```bash
nmcli device wifi list
nmcli device wifi connect "SSID" password "PASSWORD"
nmtui                                  # interactive, easier on this keyboard
```

## Packages

```bash
sudo pacman -Syu <package>
```

Never `-Sy` followed by a separate `-S`; that produces a partial upgrade. If pacman
complains that Landlock is unsupported, the kernel predates the fix — `sudo pacman
--disable-sandbox -Syu` works, and `DisableSandbox` in `/etc/pacman.conf` makes it
permanent.

## Defaults worth changing

- `sshd` is enabled with password authentication. Convenient for pasting from another
  machine; tighten it if the device leaves your network.
- The timezone is **UTC**: `sudo timedatectl set-timezone <zone>`.
- Wi-Fi regulatory domain is not set: `sudo iw reg set <CC>` if 5 GHz channels are missing.
