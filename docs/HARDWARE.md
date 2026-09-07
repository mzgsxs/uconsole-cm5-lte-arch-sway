# Hardware notes — uConsole with Raspberry Pi CM5

## The machine

| | |
|---|---|
| Carrier | ClockworkPi uConsole |
| Compute module | Raspberry Pi Compute Module 5 Lite (no eMMC — boots from SD) |
| SoC | BCM2712, with the RP1 southbridge over PCIe |
| Display | 5″ 1280×720 IPS, MIPI DSI, panel `cw,cwu50` |
| Backlight | OCP8178, exposed at `/sys/class/backlight/backlight@0` (range 0–9) |
| PMIC | X-Powers AXP223 (`axp20x-battery`, `axp22x-ac`) |
| Keyboard/trackball | USB HID via a LeafLabs Maple MCU, `1eaf:0024` |
| Audio | **PWM on GPIO 12/13**, not a codec |
| LTE (optional) | SIMCOM SIM7600G-H in the mini-PCIe slot, USB-signalled |
| RTC | **None usable** — no battery-backed clock |

## Things that surprise people

**There is no official CM5 image.** ClockworkPi has never released one; their downloads
are CM4, A06 and R01 only, and the CM4 image cannot boot a CM5 — different SoC, kernel and
device trees. Every working CM5 image is community-built.

**`/dev/ttyACM0` is not the modem.** It is the uConsole's own keyboard/trackball MCU,
which re-enumerates from `1eaf:0003` at boot. `cdc_acm` describes itself as a driver "for
USB modems", which makes this an easy misdiagnosis.

**GPIO numbering is not stable across compute modules.** On CM5 the header pins live on
the RP1 controller, which enumerates over PCIe and therefore appears *last* — typically
`gpiochip15`, label `pinctrl-rp1`. Anything hardcoding `gpiochip0` is a CM4-era assumption
and will fail. Detect by label.

**libgpiod v2 releases lines when the process exits.** A plain `gpioset` sets a pin, exits,
releases it, and the pin floats. Holding a power rail requires `gpioset -z` (daemonised).
A fix that corrects the chip name but not this will appear to work, then fail
intermittently.

**The panel is 1280×720, not 1280×480.** At 5″ that is ~294 PPI, so scaling is essential.
Prefer a scale that divides evenly: 1.25 → 1024×576, 1.6 → 800×450, 2.0 → 640×360. A
fractional scale that does not (1280/1.2 = 1066.67) leaves a partial pixel column at the
right edge and can produce visible artifacts there.

## Known defects and their status here

Derived from an on-device defect report. Section numbers reference that report.

| § | Defect | Status in this image |
|---|---|---|
| 3.1 | Root filesystem never expands — `parted -s` answers *No* to the in-use prompt, then the script stamps itself done and never retries | **Fixed** — uses `growpart`, asserts the partition grew, stamps only on success |
| 3.2 | 4G power-on broken on CM5: wrong gpiochip, libgpiod v1 syntax, line released on exit, and `ExecStart=-` hiding the failure | **Fixed** — `uconsole-modem-power` detects the chip by label and holds the line; the unit no longer masks failures |
| 3.3 | LTE defaults: QMI `raw_ip` off, roaming disallowed, MTU 1500 when the carrier advertises 1280 | **Fixed** — `uconsole-modem-connect` sets all three from the bearer |
| 3.4 | `systemd-networkd` and NetworkManager both enabled: two-minute boot delay, and timesyncd never syncs because it follows networkd's online signal | **Fixed** — networkd disabled, wait-online masked |
| 3.5 | No low-voltage protection; the gauge reads ~71 % about an hour before an undervoltage cut | **Guard shipped** — voltage-based, warns at 3.50 V, clean shutdown at 3.40 V. Gauge calibration available on demand |
| 3.6 | No RTC; clock wrong every boot | **Mitigated** — networkd fix lets timesyncd work; NTP servers pinned by IP so a first sync does not need DNS |
| 3.7 | `wireless-regdb` missing — 299 brcmfmac channel errors per boot, 14.5 % of the journal | **Fixed** — `wireless-regdb` and `iw` installed |
| 3.8 | DSI panel never wakes from `dpms off`; presents as a hung machine | **Fixed** — idle dims the backlight instead; `dpms` is never used |
| 3.9 | No kernel suspend support (`/sys/power/state` empty) | **Kernel rebuilt** with `CONFIG_SUSPEND`/`PM_SLEEP`. Not wired to the power key — see below |
| 3.10 | PWM audio picks up LTE transmit bursts as audible static | **Not fixable in software** — see below |
| 3.11 | Missing `usbutils`/`iw`, no swap, sshd defaults | **Partly fixed** — tools and `zram-generator` added; sshd left enabled |

## Two that cannot be fixed here

**§3.10, modem-TX static.** Audio is PWM on GPIO 12/13, filtered passively. Its amplitude
is referenced to the supply rail, and an LTE transmit burst was measured pulling 4.4 A
peak-to-peak with a 305 mV rail sag *while on AC*. That ripple lands directly in the audio
output. No driver change removes it; it needs antenna routing away from the audio traces,
or an I2S codec on a hardware revision. Usefully, the static is the audible signature of
the current spikes that cause undervoltage shutdowns — treat it as an early warning.

**§3.9, suspend.** The capability is now compiled in, but nothing uses it. BCM2712
suspend-to-RAM is not meaningfully supported upstream, so the likely outcome is s2idle,
which saves little. More importantly, resume must re-initialise the DSI link — and §3.8
showed the panel already fails to return from a plain `dpms off`. Validate the panel
before investing in suspend. The power key blanks the backlight instead, which captures
most of the practical benefit on a handheld where the backlight dominates idle draw.

## Power figures

Measured on this hardware:

- Idle, screen on: ~5–7 W
- LTE connected but not routed ("hot standby"): ~0.1 W, ~4 MiB/month
- LTE transmit burst: 4.4 A swing, 305 mV rail sag
- Pack: 24.79 Wh nominal

The gauge is uncalibrated (`calibrate` reads 0) and its percentage cannot be trusted —
it read 49 % at 3.402 V. Use voltage, which is what `uconsole-battery-guard` does.
