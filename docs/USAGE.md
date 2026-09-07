# Using the image

## First boot

The machine prompts on tty1 for a **username and password**. That account gets sudo via
`wheel`, and the same password is applied to `root` and to the stock `alarm` account.
Autologin is then pointed at your new user, and the wizard disables itself.

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
| `Alt`+`1`…`5` | Switch workspace |
| `Alt`+`h/j/k/l` or arrows | Move focus |
| `Alt`+`Shift`+ same | Move window |
| `Alt`+`Shift`+`c` | Reload sway config |
| `Print` | Region screenshot |
| Power button (short) | Blank the backlight; press again to restore |
| Power button (~5 s) | Clean poweroff |

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

Continuum saves every 15 minutes and restores when the tmux server starts. A `tmux.service`
user unit starts that server at login, so after a reboot your session is already back —
`ta` just attaches to it. Pane contents and vim sessions are restored, not just the layout.

To save immediately rather than waiting for the interval: `prefix + Ctrl-s`.
To restore by hand: `prefix + Ctrl-r`.

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
sudo uconsole-battery-calibrate apply # write calibration where the driver allows
```

`status` is safe any time and immediately tells you whether the gauge is lying. `run`
measures real pack capacity by integrating current, stopping at 3.50 V so it can never
trigger the undervoltage cut. It refuses to start quietly while the LTE modem is powered,
because transmit bursts both corrupt the measurement and risk a crash.

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
