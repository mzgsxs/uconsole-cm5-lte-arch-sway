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
| `Alt`+`1`…`9`, `Alt`+`0` | Switch to workspace 1–10 |
| `Alt`+`h/j/k/l` or arrows | Move focus |
| `Alt`+`Shift`+ number | Move window to that workspace |
| `Alt`+`Shift`+`h/j/k/l` | Move window within the layout |
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
