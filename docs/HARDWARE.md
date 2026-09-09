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
| Thermal | AVS block, driven by `bcm2711_thermal`; single zone `cpu-thermal` |
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

**The thermal driver is `bcm2711_thermal`, on a BCM2712.** The SoC is a 2712, but
Raspberry Pi reuses the BCM2711 AVS thermal block, so the CM5 device tree declares
`compatible = "brcm,bcm2711-thermal"` and the 2711 driver binds it. `cpu-thermal` is the
only zone in the tree, which is why `thermal-zone: 0` is the right waybar setting. Reasoning
from the part number rather than the DTB leads you to look for a 2712 driver that does not
exist.

**The DSI panel often fails to initialise on a COLD boot.** Powering on from fully off is
markedly less reliable than a warm restart, and the failure is silent: the panel reports
`status=connected enabled=enabled`, `fb0` exists, the backlight sits at its normal level —
and nothing is on screen. Only dmesg tells you, and the tell is `[drm] Receive failed`, a
DSI command read-back failure during panel init. Measured on this board 2026-09-09:

```
cold boot (black)          warm reboot (fine)
  6x "regulator isn't ready"   1x
  [drm] Receive failed         absent
```

**A warm reboot fixes it; another power cycle often does not**, which makes the instinctive
recovery — hold the power button, then power back on — the wrong move, since that is
another cold boot. From a black screen press `Ctrl`+`Alt`+`F2` then `Ctrl`+`Alt`+`Del`,
which is a clean warm reboot and needs no login. (With sway running, switch VT first: a
compositor holds the seat, so `Ctrl`+`Alt`+`Del` never reaches the kernel's VT layer.)

This matters more than it looks, because the session-restore feature deliberately
encourages powering off and back on — which is exactly the operation this panel is worst
at. The ClockworkPi community documents the same cold-boot fragility.

**CPU offlining is one-way — the firmware can park a core but cannot restart it.**
Offlining succeeds; bringing the core back fails, and only a reboot recovers it. Measured
on this board 2026-09-08 on all of cpu1–cpu3:

```
psci: CPU1 killed (polled 0 ms)         <- CPU_OFF worked
CPU1: failed to come online
CPU1: failed in unknown state : 0x0     <- the core never ran kernel code again
```

`unknown state : 0x0` is arm64's `secondary_data.status` never being updated by the
incoming CPU: PSCI `CPU_ON` returned, but the core never started executing. The userspace
write reports `EINVAL` (*write error: Invalid argument*) after arm64's **5-second per-CPU
boot timeout**, so recovering three cores stalls for fifteen seconds and then fails anyway.

This is the same minimal PSCI implementation described in §3.9 — the one whose
`SYSTEM_SUSPEND` is a firmware stub. It boots secondaries once, at startup, and that is
all.

Consequences for anything that parks cores to save power: the machine is crippled
*permanently*, not temporarily; the wake path stalls 5 s per core before failing; and
because the write on the way **down** returns success, a naive implementation leaves no
trace at all. A later "screen on, idle" power measurement was recorded at one core without
anyone noticing. `CPU_OFFLINE_CORES_ON_BLANK` therefore defaults to 0. Verify on any other
board with `uconsole-lowpower selftest-cores`, which costs one core if the answer is no.

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
| 3.9 | No kernel suspend support (`/sys/power/state` empty) | **Superseded.** The premise was a CM4 observation. On this build both sleep states register — and both are unusable. Suspend is now masked; see below |
| 3.10 | PWM audio picks up LTE transmit bursts as audible static | **Not fixable in software** — see below |
| 3.11 | Missing `usbutils`/`iw`, no swap, sshd defaults | **Partly fixed** — tools and `zram-generator` added; sshd left enabled |

## Two that cannot be fixed here

**§3.10, modem-TX static.** Audio is PWM on GPIO 12/13, filtered passively. Its amplitude
is referenced to the supply rail, and an LTE transmit burst was measured pulling 4.4 A
peak-to-peak with a 305 mV rail sag *while on AC*. That ripple lands directly in the audio
output. No driver change removes it; it needs antenna routing away from the audio traces,
or an I2S codec on a hardware revision. Usefully, the static is the audible signature of
the current spikes that cause undervoltage shutdowns — treat it as an early warning.

**§3.9, suspend.** Do not use it. Not "it saves little" — it hard-hangs this machine,
and the sysfs entries actively invite you to try.

`/sys/power/mem_sleep` reads `s2idle [deep]` and `/sys/power/state` reads `freeze mem`,
so everything looks available. Neither state is:

- **`deep` is not suspend-to-RAM on BCM2712.** Broadcom has never delivered the DDR PHY
  self-refresh entry/exit sequences. Raspberry Pi's firmware advertises PSCI
  `SYSTEM_SUSPEND` anyway, so the kernel registers `PM_SUSPEND_MEM` in good faith; behind
  it is a stub that exercises the mailbox and parks the ARM core for about a second.
  `mem_sleep` resets to `deep` on **every boot** — it is not persisted — so a bare
  `echo mem > /sys/power/state` silently takes this path.
- **`s2idle` is real, but its device-suspend phase wedges the Wi-Fi chip.** `brcmfmac`
  on the SDIO-attached BCM4345/6 fails its bus-sleep transition with `-110` backplane
  timeouts every single time, including with the radio already soft-blocked via `rfkill`.
  The chip does not come back: reprobing all three SDIO functions fails with
  `Failed to force clock for F2: err -110`. **A module reload does not recover it — only
  a reboot does.**

Five suspend attempts produced five hard hangs. Four needed a battery pull; the ext4 root
replayed its journal each time, systemd rotated corrupted journal files, and the FAT boot
partition was left dirty twice. A sixth attempt using `/sys/power/pm_test` at the
`devices` level isolated the two causes cleanly: it reproduced the Wi-Fi wedge without
hanging the kernel, proving brcmfmac is sufficient to kill the radio on its own but that
the total hang additionally needs the deeper stages `pm_test` skips.

Note that `pm_test`'s printed level list (`none core processors platform devices freezer`)
is **not** severity order. The cumulative order is
`freezer < devices < platform < processors < core < none`.

This image therefore masks `sleep.target`, `suspend.target`, `hibernate.target`,
`hybrid-sleep.target` and `suspend-then-hibernate.target`, and pins
`mem_sleep_default=s2idle` on the kernel command line so that anything writing
`/sys/power/state` directly degrades to the merely-broken state rather than the
firmware stub.

The power key blanks the backlight instead, and unlike suspend it comes back.

**Do not repeat the claim that the backlight dominates idle draw here — it does not.**
Measured on this unit: 4.08 W with the screen on, 3.36 W with the backlight at zero and
nothing else touched. The backlight is worth **0.72 W, about 18 %**. The remaining 3.36 W
is radios, CPU and the RP1/USB tree, which is why the low-power blank switches those off
too rather than stopping at the panel.

## Power figures

Measured on this hardware:

- Idle, screen on: **4.08 W** measured on battery (2026-09-08, `uconsole-power-probe`).
  An earlier ~5–7 W estimate was not measured on this unit.
- Idle, backlight off, nothing else changed: **3.36 W**
- LTE connected but not routed ("hot standby"): ~0.1 W, ~4 MiB/month
- LTE transmit burst: 4.4 A swing, 305 mV rail sag
- Pack: **14.8 Wh nominal** on this unit -- 2x 18650 at 3.7V 2000mAh, wired in
  **parallel** (3.7V x 4000mAh). Parallel is not an assumption: the AXP223 is a
  single-cell PMIC and the pack reads 3.4-4.2V in sysfs, where a series pair would
  read double. An earlier figure of 24.79 Wh came from the defect report and
  described larger cells; it is wrong for this hardware.
  Set `PACK_WH` in `/etc/uconsole/lowpower.conf` if you fit different cells.

The gauge is uncalibrated (`calibrate` reads 0) and its percentage cannot be trusted —
it read 49 % at 3.402 V. Use voltage, which is what `uconsole-battery-guard` does.
