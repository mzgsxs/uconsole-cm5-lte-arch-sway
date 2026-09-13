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

**The battery says it is `online` with no charger attached.** On the AXP223,
`axp20x-battery` reports `online=1` whenever a battery is fitted — it means *present*, not
*powered*. AC is the separate `axp22x-ac` supply, `type=Mains`. Asking "is any supply
online?" therefore answers "yes, on AC" while running on battery; the first OTA power guard
did exactly that and never looked at the charge. Tell the supplies apart by `type`, and judge
the battery by voltage rather than the gauge, as `uconsole-battery-guard` does.

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

**The boot-time clock ceiling varies, and a software bug used to latch it.** Two separate
things were tangled together here across three attempts at writing this down; they are
untangled now.

*The bug, which was ours and is fixed.* `uconsole-lowpower down` truncated its state file
and recorded the **current** governor and ceiling as "pre-blank" on every descent. A second
descent — two power-key presses in quick succession is enough — therefore saved the
already-clamped `1500000`/`powersave` as the values to restore, and `up` faithfully put
them back. The machine then ran at 62 % of its clock, in the powersave governor, until the
next reboot, with `up` unable to help because it was doing exactly what it had been told.
Demonstrated directly:

```
start        ceiling=2400000 gov=schedutil
after down#1 ceiling=1500000 gov=powersave     <- correct
after down#2 ceiling=1500000 gov=powersave     <- records the CLAMPED values
after up     ceiling=1500000 gov=powersave     <- restores the clamp, permanently
```

`down` now refuses to re-record while a descent is already active, and `up` treats a saved
ceiling equal to the floor as a stale clamp and restores the hardware maximum instead.
This is the same shape as the audio-mute latch: **saving "what it was" is wrong whenever
"what it was" might already be the state you are about to impose.**

*The firmware behaviour, which is not ours and is not fully characterised.* Independently
of the above, the ceiling at boot is **not consistent**. Two clean boots of the same image,
no low-power script having run in either:

| Boot | Power source | `scaling_max_freq` at boot |
|---|---|---|
| 2026-09-10 02:24 | not recorded | 2400000 |
| 2026-09-10 02:45 | **battery**, 3.675 V, `AC online 0` | 1500000 |

The capped boot stays capped under sustained 4-core load (41 °C, `in0_lcrit_alarm=0`), so
it is neither thermal nor undervoltage throttling. It is also **not enforced**: writing
2400000 raises it and the value holds.

The obvious hypothesis is that the firmware picks a conservative `arm_freq` when it cannot
confirm an adequate supply, and that booting on battery triggers it. **That is untested** —
the power source at the 02:24 boot was not recorded. Confirming it needs one boot on AC and
one on battery, checked immediately. Do not add `arm_freq`/`arm_boost` to `config.txt`
speculatively; measure first.

A note on how this section got written three times: the first version called it a hardware
property, measured on a long-lived test machine carrying hand-copied files. The second
retracted that as "accumulated state, cause unknown". Both were too confident. The cause
was two causes, and only one of them was ours.

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
| 3.2 | 4G power-on broken on CM5: wrong gpiochip, libgpiod v1 syntax, line released on exit, and `ExecStart=-` hiding the failure | **Fixed** — `uconsole-modem-power` detects the chip by label, and the unit no longer masks failures. Its `disable` never worked, though. GPIO 24 is the module's **power key**, not its supply, and GPIO 15 is its reset (measured). Both verbs now press the key and check the USB bus |
| 3.3 | LTE defaults: QMI `raw_ip` off, roaming disallowed, MTU 1500 when the carrier advertises 1280 | **Fixed** — `uconsole-modem-connect` sets all three from the bearer |
| 3.4 | `systemd-networkd` and NetworkManager both enabled: two-minute boot delay, and timesyncd never syncs because it follows networkd's online signal | **Fixed** — networkd disabled, wait-online masked |
| 3.5 | No low-voltage protection; the gauge reads ~71 % about an hour before an undervoltage cut | **Guard shipped** — voltage-based, warns at 3.50 V, clean shutdown at 3.40 V. Root cause of the gauge error now identified — see below |
| 3.6 | No RTC; clock wrong every boot | **Mitigated** — networkd fix lets timesyncd work; NTP servers pinned by IP so a first sync does not need DNS |
| 3.7 | `wireless-regdb` missing — 299 brcmfmac channel errors per boot, 14.5 % of the journal | **Fixed** — `wireless-regdb` and `iw` installed |
| 3.8 | DSI panel never wakes from `dpms off`; presents as a hung machine | **Misdiagnosed, and now used deliberately.** The panel always woke; what failed was sway re-enabling a powered-off DSI output. Each of `power on`, `enable` and `mode` *alone* reports success and leaves it dark — but `power on` **then** `enable` restores it 3/3, no VT switch and no root. The blank now powers the panel down for a measured 0.714 W (`PANEL_OFF_ON_BLANK`, default on) |
| 3.9 | No kernel suspend support (`/sys/power/state` empty) | **Superseded.** The premise was a CM4 observation. On this build both sleep states register — and both are unusable. Suspend is now masked; see below |
| 3.10 | PWM audio picks up LTE transmit bursts as audible static | **Not fixable in software** — see below |
| 3.11 | Missing `usbutils`/`iw`, no swap, sshd defaults | **Partly fixed** — tools and `zram-generator` added; sshd left enabled |

**The fuel gauge reads high near empty, and it is NOT a capacity mismatch.** That was
investigated and ruled out. The device tree declares:

```
/proc/device-tree/battery@0/charge-full-design-microamp-hours   6700000   (6700 mAh)
fitted pack: 2x 18650 3500mAh in parallel                                  7000 mAh
```

Within 4 %, and in the direction that would make the gauge read *low*. The percentage is
wrong because the gauge is simply **uncalibrated** — `calibrate` reads 0 — and the AXP223
derives its number from an internal model that does not match this pack. §3.5 recorded
49 % at 3.402 V; 2026-09-10 saw ~30 % at 3.38 V. Same failure, years apart.

That incident is worth recording in full, because it looks from the outside like the guard
firing early:

```
16:08:19  WARNING:  3490000uV low
16:11:09  CRITICAL: 3380000uV <= 3400000uV, shutting down cleanly
16:30:21  WARNING:  3402000uV low
16:30:56  CRITICAL: 3357000uV <= 3400000uV, shutting down cleanly
```

3.38 V and 3.357 V are genuinely flat for a 18650. **The guard was right and the gauge was
wrong**, which is why the threshold is voltage-based and why lowering it is the wrong
response to this symptom. It was briefly lowered to 3.30 V for exactly that reason and put
back: 3.40 V exists to leave margin for the ~8 s clean shutdown against the 305 mV rail sag
an LTE transmit burst produces (§3.10), and LTE was connected during both events above.

Both `uconsole-battery-guard` messages now print the gauge's claim next to the voltage, so
the journal distinguishes "guard fired early" from "gauge is lying" without a second
investigation.

**The battery driver never reports `status=Full`.** Measured 2026-09-10 with the pack at
**4.213 V** (above the 4.200 V design maximum), gauge at **100 %**, and charge current
tapered to **4–19 mA**, `status` still read `Charging` — indefinitely.

Anything that waits for that string waits forever. `uconsole-battery-calibrate` did exactly
that and hung in phase 1 on a pack that was already charged. It now terminates on the
physics instead — at the voltage ceiling with the current fallen to a trickle, which is how
a CV charger finishes anyway — requires the condition to hold across three samples, and
gives up after four hours rather than hanging silently.

The device tree battery node is also patched at kernel build time to describe the fitted
cells rather than ClockworkPi's stock pack; see `BATTERY_MAH` in `build/build-kernel.sh`.
That does **not** fix the gauge, which is uncalibrated — it only makes
`charge_full_design` honest.

**After a low-voltage shutdown, charge before powering on again.** The same incident shows
why: three boots of ~620 journal lines each, seconds apart, then a fourth that survived
three minutes before the guard fired again. Each attempt that dies mid-boot leaves the FAT
boot partition dirty — one such marker is present on the current boot, and two journal
files have been rotated as corrupted.

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
- **Blanked with the panel powered down: 2.632 W, against 4.082 W screen-on** — **1.450 W,
  a 36 % saving**, measured on battery through the real power-key path. The panel and its
  controller are **0.714 W** of that, measured separately with the backlight already off in
  both states and repeatable to 0.018 W.
- LTE connected but not routed ("hot standby"): ~0.1 W, ~4 MiB/month
- LTE transmit burst: 4.4 A swing, 305 mV rail sag
- Pack, **measured**: **4.47 Ah / 16.5 Wh** down to 3.50 V resting, **4.9 Ah / ~18 Wh** down
  to the 3.40 V the guard cuts at. The second figure is optimistic: it extrapolates in a
  straight line below the lowest voltage the run reached, where the curve was already
  steepening, and the guard reads *loaded* voltage, so it fires above 3.40 V resting.
  Expect about **6 h** at the 2.632 W blank. That is the energy this machine can use, and it
  is **not** comparable to the 2× 18650 3500 mAh nameplate: an 18650's rated capacity is
  measured down to a ~2.7 V cutoff, and this device never goes below 3.40 V. The charge
  between those two voltages is real and simply out of reach here. Parallel is not an
  assumption: the AXP223 is a single-cell PMIC and the pack reads 3.4–4.2 V in sysfs, where
  a series pair would read double.

The gauge is uncalibrated (`calibrate` reads 0) and its percentage cannot be trusted —
it read 49 % at 3.402 V. Use voltage, which is what `uconsole-battery-guard` does.

### Where the draw actually goes

Measured 2026-09-12 with `uconsole-power-budget`, on battery, in the 3.87–3.85 V part of the
curve the pack is characterised over. Each row brackets the changed state between two
unchanged windows and compares against their mean, because the pack is emptying while we
measure. **Idle baseline: 3.64 W** with the backlight off, the panel on, the modem
registered and Wi-Fi associated.

Ranked by what they are worth, which is not the order anyone here had assumed:

| Lever | Worth | Notes |
|---|---|---|
| **Backlight, off → maximum** | **1.964 W** | The most expensive component on the machine. Convex: see below |
| **DSI panel + controller** | **0.714 W** | Already taken on blank (`PANEL_OFF_ON_BLANK`) |
| **Modem powered down** | **0.325 W** | Against a registered, connected modem, with the power-key `uconsole-modem-power disable`. On the blank it is `MODEM_RAIL_OFF_ON_BLANK`, off by default: what it saves over the blank's radio low-power is not yet measured |
| USB autosuspend | ~0.1 W | −98 mW on every device; −73 mW of that is the modem, −10 mW the keyboard. Not worth taking; see below |
| CPU ceiling pinned to 1.5 GHz | **0.064 W** | At idle. Already taken on blank (`CPU_CLAMP_ON_BLANK`) |
| Wi-Fi 802.11 power save | not resolved | −61 mW, but the two reference windows disagreed by 298 mW |
| Ethernet PHY (`end0`) down | **0.009 W** | Nothing. Already effectively off with no carrier |
| Parking 3 of 4 CPU cores | **0.008 W** | Nothing — and it is a one-way door; see below |

**The backlight curve is convex, and that is the practical finding.** 10 s per level, swept
up and then back down so drift cancels:

| level | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| mW over off | +0 | +0 | +159 | +253 | +455 | +703 | +1125 | +1652 | +1853 | +1964 |

One notch through the middle costs up to **527 mW** (6→7) while the top notch costs **111 mW**
(8→9). So **dropping from 9 to 6 saves 839 mW** and gives up three notches of a nine-notch
scale — the single largest thing a user can do about battery life on this machine. Against
the measured 18 Wh usable pack, brightness alone moves idle runtime between roughly **3.3 h
at level 9 and 5.0 h with the backlight off**.

**Levels 0 and 1 measured identical, to the milliwatt.** PWM duty is zero below 2, so level 1
is *off*, not dim. Do not read "brightness 1" on a running machine as a lit screen, and do
not set `DIM_LEVEL=1` expecting a faint glow — `verify-image` refuses it.

**The CPU's dynamic range is 4.44 W** — four cores busy measured 8.30 W against a 3.86 W
idle. That is the largest number in this document, and the only lever for it is not doing
the work; there is no idle state to exploit (below).

**USB autosuspend is not worth taking, and the first two numbers said otherwise.** Runs of
−171 mW and −237 mW came from a helper that globbed port numbers and half-failed, with
reference windows 155 mW apart. With the helper fixed and the windows agreeing to 5 mW, every
non-root-hub device together is **−98 mW**, and split by device the **keyboard is −10 mW** —
nothing — while the **modem is −73 mW**. So the only real saving sits on the one device where
USB autosuspend is known to break data connections, for a tenth of a watt, while powering the
modem down entirely is worth 0.325 W. It is not enabled, and there is no longer any reason to
test whether a keypress wakes a suspended keyboard.

**The 0.325 W modem figure is against a registered, connected modem.** It was measured with
the power-key `uconsole-modem-power disable`, which is now what ships: the old `disable` killed
the process holding GPIO 24 and reported success while the SIM7600 stayed registered. The
blank's default (`MODEM_OFF_ON_BLANK`) still only asks ModemManager for radio low-power, and
what powering the module off saves *over that* has not been priced.
`MODEM_RAIL_OFF_ON_BLANK=1` makes the blank power it off.

### There is no cpuidle here, and the firmware is why

`/sys/devices/system/cpu/cpuidle/current_driver` reads **`none`**. `CONFIG_CPU_IDLE` is on —
the framework and its governors are present — but there is no driver behind it, so
`cpuidle_idle_call()` falls through to `default_idle_call()` and the cores idle in plain WFI.
Confirmed on 7.1.4: no `psci_cpuidle` or `dt_idle_states` symbols in `/proc/kallsyms`, and no
`cpus/idle-states` node in the device tree. Enabling it would need both a kernel rebuild and
a DT change.

It is not worth doing, and the firmware source says why in plain code.

**The firmware does not refuse the call** — that is the first thing to know, because it rules
out the cheap answer. `/sys/kernel/debug/psci` reads `OSI is not supported` and `Original
StateID format is used`, and the kernel prints those two lines only when
`PSCI_FEATURES(CPU_SUSPEND)` succeeds. So `CPU_SUSPEND` is advertised, in platform-coordinated
mode.

What stands behind it is Raspberry Pi's own TF-A fork — `raspberrypi/arm-trusted-firmware`,
branch `bcm2712`, `plat/rpi/rpi5/rpi5_pm.c` — not upstream TF-A's Pi 5 port. Upstream's
`psci_setup.c` only advertises `CPU_SUSPEND` when a platform provides `pwr_domain_suspend` and
`pwr_domain_suspend_finish`, and upstream's Pi code provides neither, so the device cannot be
running it. The fork's file accepts three states, and none saves power over what the kernel
already does:

| State | What the firmware does | Worth |
|---|---|---|
| Core retention (standby) | `dsb(); wfi();` | Exactly the WFI `default_idle_call()` already does, plus an SMC round trip |
| Core power-down | `pwr_down_wfi`: `write_cpupwrctlr_el1(0x1)`, then WFI | The same path as `CPU_OFF` — measured **−8 mW** for three cores |
| Cluster power-down | The above on every core | Only reachable with every core idle |

**And on the `bcm2712` branch the power-down states are worse than useless.**
`rpi5_pwr_domain_suspend` writes `MBOX_CHAN_SUSPEND` to VideoCore *unconditionally* — for any
power-down `CPU_SUSPEND`, so a single idle core would ask for system suspend — and
`rpi5_pwr_domain_suspend_finish` is an `#if 0` block of leftover Rockchip code. The
`bcm2712-s2ram` branch fixes exactly that ("The VC powers the ARM cluster off as soon as it
handles this message"; it now returns early unless the request is a system suspend), which
confirms the reading. Which branch built the bl31 in this unit's EEPROM is not visible from
Linux; on either, a cpuidle driver would offer the governor one state that ties WFI and one
that saves nothing measurable — and, on `bcm2712`, can take the machine down.

The measurement agrees with the source. `CPU_OFF` sets the A76's core power-down request and
parks the core in WFI; three of four cores parked that way measured **−8 mW** against ±180 mW
of noise. Either BCM2712 does not switch per-core power on that request, or per-core leakage
is below what this pack can resolve. Either way, there is nothing for an idle state to reach.

**And `CPU_OFF` is a one-way door on this board.** After offlining, `CPU_ON` refuses:

```
psci: failed to boot CPU1 (-22)
CPU1: failed to boot: -22
CPU2: failed to come online
CPU2: failed in unknown state : 0x0
```

The cores do not come back without a reboot. That is the same failure `lowpower.conf`
records for `CPU_OFFLINE_CORES_ON_BLANK` (default 0, 2026-09-08); this run adds the cause —
the firmware's own error — and the number that makes the option pointless even if bring-up
were fixed.

### What a full discharge showed

`uconsole-battery-calibrate run`, from full to 3.50 V under 0.8–3.3 A (mean 2.6 A):

| | |
|---|---|
| delivered to the 3.50 V stop | 3828 mAh / 14.22 Wh |
| pack resistance | **68 mΩ**, median of 48 load steps in the run (quartiles 66–72) |
| voltage at the stop, corrected for that | **3.65 V**, not 3.50 — at 2.3 A the load hid 0.16 V |
| still left at the stop | ~640 mAh to 3.50 V resting, ~1070 mAh to 3.40 V |

68 mΩ is measured at the gauge's terminals, so it covers the whole path — cells, welds,
wiring, connector — rather than the cells alone, and it is exactly what the load correction
needs. **A run that ends under load stops early**: that is what the correction is for, and
why the discharge should be idle by the end.

**The gauge reads far too high, and now by how much.** Against the charge actually counted
out of the pack it is 10 points high at 82 % charge, 24 high at 43 % and 35 high at 15 % —
still claiming 49 % minutes before the guard fired. It cannot be corrected from here:
`calibrate` and `charge_full_design` are both read-only on this kernel.

`report` derives all of that from the run and writes
`/var/lib/uconsole/battery-calibration/table.tsv`, a voltage → charge table which
`uconsole-battery-calibrate soc <µV> [µA]` then interpolates — correcting a loaded voltage
to an open-circuit one first, since at 0.9 A this pack reads 61 mV low. The slope is not
constant, so a single Wh-per-volt is wrong by up to 1.6× depending only on where you sit:

| OCV | Wh per volt | |
|---|---|---|
| above 4.15 V | ~16 | near vertical; 50 mV is worth 9 mAh |
| 4.05–4.00 V | 47 | thin, crossed under load — read with suspicion |
| 3.95–3.80 V | 36–37 | dense and consistent — **measure here** |
| below 3.75 V | 30 and falling | |

The 4.05–4.00 V band is the weakest: the calibration discharge crosses it quickly under
~2 A while surface charge from the just-finished charge still holds the voltage up, and
pricing a drop there against independently sampled power came out **20 % low**. Take
measurements in 3.95–3.80 V.
