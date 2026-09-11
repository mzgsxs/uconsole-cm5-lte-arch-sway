# Upstream reports — drafts, not filed

Kernel and userspace bugs found while making s2idle work on a ClockworkPi uConsole with a
Raspberry Pi CM5 (BCM2712 + RP1). Each is written so it can be filed as it stands. **None has
been filed**; that is the owner's call.

Evidence levels are as elsewhere in this repo:

- **measured** — seen on the device;
- **source** — read in the kernel tree at `ak-rex/ClockworkPi-linux` `84258d9b`, which
  tracks `raspberrypi/linux` `rpi-7.1.y`.

The patches named here are in [`build/patches/`](../build/patches/).

---

## 1. gpio-brcmstb: `suspend_noirq` aborts every suspend on a bank with no parent IRQ

**Where:** `drivers/gpio/gpio-brcmstb.c`, mainline and downstream alike.

`brcmstb_gpio_suspend()` sets `priv->suspended` only when `priv->parent_irq > 0`, but
`brcmstb_gpio_suspend_noirq()` returns `-EBUSY` whenever `!priv->suspended`. A controller
with no parent IRQ therefore fails every system suspend. Nothing is busy, and there is no
wake to catch.

On BCM2712, `gpio@7d517c00` (gio_aon) has no `interrupts` property on purpose. According
to the DT comment, it would clash with the VPU firmware watching the PMIC interrupt. So
s2idle aborts 100% of the time (measured):

```
brcmstb-gpio 107d517c00.gpio: PM: dpm_run_callback(): brcmstb_gpio_suspend_noirq returns -16
brcmstb-gpio 107d517c00.gpio: PM: failed to suspend noirq: error -16
```

**Fix:** make the guard symmetric, `if (priv->parent_irq > 0 && !priv->suspended) return
-EBUSY;` (patch 0001). With it, `pm_test=platform` returns and real s2idle works (measured).

## 2. pinctrl-rp1: GPIO interrupts cannot be armed for wakeup

**Where:** `drivers/pinctrl/pinctrl-rp1.c`, `raspberrypi/linux`.

`rp1_gpio_irq_chip` has no `irq_set_wake` and does not set `IRQCHIP_SKIP_SET_WAKE`, so
`enable_irq_wake()` on any RP1 GPIO interrupt fails with `-ENXIO`. Any device whose
interrupt reaches the SoC through an RP1 GPIO cannot wake the system.

On the uConsole CM5 that includes the power key. The AXP223's interrupt is RP1 GPIO 2.
regmap-irq's propagation of the wake request fails silently, and the resume path then warns
(measured, three per resume):

```
Unbalanced IRQ 189 wake disable
 irq_set_irq_wake <- regmap_irq_sync_unlock <- irq_set_irq_wake <- axp20x_pek_resume
```

**Fix:** there is nothing to program. Each bank's parent is a chained RP1 MSI-X vector,
which `suspend_device_irqs()` never disables, so an armed GPIO interrupt still reaches the
CPU as long as RP1 and its link stay up (see 3). Returning 0 from `irq_set_wake`, or setting
`IRQCHIP_SKIP_SET_WAKE`, is enough. Patch 0003 does the former behind a parameter. With it
and 0004, the power key ends s2idle: `PM: Triggering wakeup from IRQ 174` (measured).

## 3. pcie-brcmstb + RP1: RP1 is reset by every suspend, and nothing restores it

**Where:** `drivers/pci/controller/pcie-brcmstb.c`, `drivers/mfd/rp1.c`, `raspberrypi/linux`.

`brcm_pcie_suspend_noirq()` calls `brcm_pcie_turn_off()`, which asserts PERST# on the link.
On BCM2712's pcie2 that link leads to RP1, the southbridge that owns GPIO, USB, DSI/DPI and
I2C. Earlier in the suspend, the PCI core has already disabled RP1 and cleared its bus
mastering, through `pci_pm_default_suspend()`, because `rp1.c` has no PM ops. No RP1
interrupt can wake the system, and RP1 functions without their own PM ops come back
unconfigured.

Measured with `pm_test=platform`: resume logs a link retrain, `brcm-pcie 1000120000.pcie:
link up, 5.0 GT/s PCIe x4 (!SSC)`, followed within a second by
`[CRTC:37:crtc-0] vblank wait timed out` (a `WARNING` in
`drm_atomic_helper_wait_for_vblanks`), and the compositor stops answering.

**What we carry:** patch 0004 is a stopgap, not a proposed upstream fix. With
`keep_link_in_suspend`, a link that is up is left alone, and the PCI devices behind it are
marked syscore from `->prepare()` to `->complete()`. With it the retrain, the vblank timeouts
and the hang are all gone (measured), and so is the power-key wake of 2. The proper fix is
probably one of two: PM support in `rp1.c` that saves and restores RP1 state (MSI-X
configuration, clocks, and each function's registers), or keeping the link whenever a
downstream device may wake the system. The existing `ep_wakeup_capable` walk only spares the
regulators.

## 4. drm-rp1-dsi: no PM ops; the DMA interrupt is enabled only at probe

**Where:** `drivers/gpu/drm/rp1/rp1-dsi/`, `raspberrypi/linux`. **Source.**

The driver has no `dev_pm_ops`. `rp1dsi_mipicfg_setup()`, which enables the DSI DMA
interrupt (`RPI_MIPICFG_INTE_DSI_DMA_BITS`), is called once, in `rp1dsi_platform_probe()`.
After anything resets RP1 (see 3), every atomic commit waits out its `flip_done` timeout.
A full modeset, forced for example by a VT switch, runs `rp1dsi_dsi_setup()`, which does not
rewrite it.

**Suggested:** PM ops that use `drm_mode_config_helper_suspend()`/`_resume()` and re-run
`rp1dsi_mipicfg_setup()` on resume. Not attempted here: 0004 avoids the reset instead.

## 5. rtc-rpi: an alarm can never wake a running or suspended system

**Where:** `drivers/rtc/rtc-rpi.c`, `raspberrypi/linux`.

The firmware RTC alarm raises no interrupt. It exists to power the board up from halt,
which is why the driver sets `RTC_FEATURE_ALARM_WAKEUP_ONLY`. `rtcwake -m mem` (or
`freeze`) therefore sets an alarm Linux never hears. On a board with no other wake source,
the system sleeps until something else ends it (source, and every early attempt here).

**What we carry:** patch 0005 shadows each armed alarm with a `CLOCK_BOOTTIME` hrtimer that
calls `rtc_update_irq()` and `pm_wakeup_hard_event()`. That works only where timers keep
running through s2idle, which they do on BCM2712 (see 7). With it, sleeps of 121, 301 and
1202 s each ended on their alarm to the second (measured). The better fix is a firmware
notification for the alarm. That question is for the firmware side, not a kernel patch.

## 6. bcm2835_wdt: the watchdog keeps counting through suspend

**Where:** `drivers/watchdog/bcm2835_wdt.c`, mainline. **Source**; consequence measured.

There are no PM ops, and `WDOG_NO_PING_ON_SUSPEND` is not set. With userspace frozen and a
timeout at or below the hardware maximum (~16 s), nothing pings it during a sleep, and the
board resets partway through any suspend longer than that. systemd's
`RuntimeWatchdogSec=15` is exactly that case. Before this work, every s2idle attempt on this
machine ended in a watchdog reset, so "the sleep hung" and "the sleep was fine and the
watchdog fired" could not be told apart.

**Not simply a bug.** On BCM2712, timers run through s2idle (see 7). Raising the userspace
timeout above the hardware maximum makes the watchdog core's worker feed the hardware
throughout the sleep, which keeps hang protection while asleep (measured: 1202 s asleep, no
reset). A driver that stopped the timer in suspend would lose that. What is worth reporting
is that the interaction is undocumented.

## 7. s2idle without a cpuidle driver leaves CLOCK_MONOTONIC running, and systemd kills services for it

**Where:** kernel s2idle path (`kernel/sched/idle.c`, `kernel/power/suspend.c`) and systemd.
**Source**; consequence measured.

Without a cpuidle driver, `cpuidle_idle_call()` takes `default_idle_call()` and never
reaches the s2idle tick freeze. Timekeeping is never suspended, so CLOCK_MONOTONIC counts
the whole sleep. BCM2712 has no cpuidle driver. systemd times `WatchdogSec=` in
CLOCK_MONOTONIC, so on waking from a 20-minute s2idle, PID 1 saw journald and logind silent
past their 3-minute limit and killed both (measured):

```
systemd-logind.service: Watchdog timeout (limit 3min)!
systemd-journald.service: Watchdog timeout (limit 3min)!
Process 222 (systemd-journal) of user 0 dumped core.
```

Our workaround is `systemctl service-watchdogs no` for the sleep, switched back on a few
seconds after waking. With it, PID 1 logged `Watchdog disabled! Ignoring watchdog timeout`
and killed nothing (measured). This belongs with the kernel, as "userspace sees monotonic
time jump across s2idle on platforms without cpuidle", or with systemd, as "service
watchdogs assume monotonic time stops in suspend". Probably both deserve a note.

## 8. panel-cwu50: `unprepare` leaves `prepared` set when its DCS writes fail

**Where:** `drivers/gpu/drm/panel/panel-cwu50.c`, `ak-rex/ClockworkPi-linux`. **Source.**

The CM4/CM5 branch of `cwu50_unprepare()` returns on a DCS failure without clearing
`ctx->prepared`, so `cwu50_prepare()` short-circuits for the rest of the boot. The CM3 branch
of the same function handles this correctly. Patch 0002 mirrors it. This failure has not
been observed to trigger here, and 0002 does not explain the cold-boot `[drm] Receive failed`
black screen (that is a read-back in *prepare*).

## 9. sway cannot re-enable a DSI output it has powered off

**Where:** sway / wlroots (DRM backend). Measured in an earlier session; **not re-measured
here.**

After `swaymsg output DSI-2 power off`, which really does cut the panel's power, battery
current drops 0.70 W. `power on`, `enable` and `mode 720x1280@59.901Hz` each return
`{"success": true}` and leave `"power": false`. Only a VT switch away and back restores it,
by forcing a full modeset. Before filing, capture sway's own log of a failed re-enable.
wlroots reports why it refuses a commit, and nobody has looked at that yet.

## 10. powertop: `wiggle()` can leave the CPU ceiling at its minimum on a shared policy

**Where:** powertop 2.16, `src/cpu/abstract_cpu.cpp`, `abstract_cpu::wiggle()`. **Measured.**

`wiggle()` runs at the start and end of every measurement, once per CPU. It reads
`scaling_max_freq`, writes the value of `scaling_min_freq` to it, then writes back what it
read. Several CPUs can share one cpufreq policy; on BCM2712 all four do. The second CPU's
wiggle then reads the same file straight after the first one's two writes.

The kernel applies limit changes from a work item
(`cpufreq_notifier_max()` → `schedule_work(&policy->update)`). Meanwhile `scaling_max_freq`
shows `policy->max`, the last limit applied. So the read can return the minimum. The wiggle
then restores that as the maximum, and every later wiggle keeps it.

Reproduced with powertop's exact sequence on four CPUs sharing a policy: 81 of 2000 reads
saw the minimum, and the ceiling was left there after 32 of 500 rounds, the first at round
3. With powertop running, the ceiling sat at the minimum for hours and came back within ten
minutes of being raised.

**Suggested:** wiggle each policy once rather than each CPU. Read every ceiling before any
wiggle and restore those values, instead of re-reading between writes.
