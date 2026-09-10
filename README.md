# uConsole CM5 — Arch Linux ARM + Sway

A build system that produces a bootable **Arch Linux ARM** image with a
**Sway** desktop for the [ClockworkPi uConsole](https://www.clockworkpi.com/uconsole)
fitted with a **Raspberry Pi Compute Module 5**.

The kernel is compiled from source; the image is assembled and then checked by an
automated verification suite — **406 checks** for the runtime image, **410** for the dev
image, all passing.

Inputs are pinned where upstream allows it: the kernel commit, the upstream builder, and
the tmux plugins. Arch Linux ARM publishes only a rolling `latest` rootfs tarball, so
builds are not bit-for-bit reproducible across a rootfs refresh; the build records the
tarball's SHA-256 and says so when it differs.

> **Read [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) before your first boot.**
> A CM5 Lite will very likely *not* boot from SD until its bootloader EEPROM is
> reconfigured. This is a firmware defect, not an image problem, and no amount of
> reflashing fixes it.

> **Do not use suspend on this hardware.** `/sys/power/state` reads `freeze mem`, so it
> looks available; it is not. Both states hang the machine hard enough to need a battery
> pull, and this image masks them deliberately. See
> [`docs/HARDWARE.md`](docs/HARDWARE.md) §3.9.
>
> Because suspend is unreachable and a blanked machine still draws ~3.2 W that userspace
> cannot switch off, this image **powers off and restores your session** instead of
> sleeping. Hold the power key ~2 s; log back in and your applications return to the
> workspaces they were on.

---

## What you get

| | |
|---|---|
| **Base** | Arch Linux ARM, aarch64, rolling |
| **Kernel** | `linux-uconsole-cm5-4k-git` built from [`ak-rex/ClockworkPi-linux`](https://github.com/ak-rex/ClockworkPi-linux), 4K pages, with Landlock and suspend enabled |
| **Desktop** | Sway, waybar, foot, fuzzel — black/green theme, tuned for a 1280×720 5″ panel |
| **Audio** | PipeWire + WirePlumber |
| **Network** | NetworkManager with a patched `wpa_supplicant` (fixes WPA2 on Broadcom) |
| **LTE** | SIM7600G-H support: power-on, auto-connect, and a WAN routing switch |
| **VPN** | Tailscale pre-installed, daemon enabled — unauthenticated, no key baked in |
| **Terminal** | tmux with TPM, resurrect and continuum — sessions survive reboots |
| **Security** | Login required at boot and on wake; firewall limits SSH to LAN/tailnet |
| **Power** | Tap blanks, locks and switches off radios, modem and clock headroom; ~2 s hold is a clean poweroff |
| **Session** | Powers off and comes back where you left it — apps, workspaces, fullscreen, tmux |
| **Recovery** | `Ctrl`+`Alt`+`F2` → `uconsole-unstick` — works with the network off |
| **First boot** | Prompts for a username and password; expands the root filesystem to fill the card |

## Quick start

The image build fetches the upstream builder and rootfs itself, so a fresh clone works.

```bash
# 1. Fetch the third-party tmux plugins into the overlay
./build/fetch-tmux-plugins.sh

# 2. Build the kernel package (~30 min, native aarch64 in Docker)
docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work \
  -e KERNEL_COMMIT=84258d9b0b918966b495f84389959abfdcec77e4 \
  -e PKGDIR=linux-uconsole-cm5-4k-git \
  alarm-base:latest /bin/bash /work/build/build-kernel.sh

# 3. Build the image. BUILD_PROFILE=runtime (default) or dev -- see below.
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  -e BUILD_PROFILE=runtime \
  alarm-base:latest /bin/bash /work/build/build-image-full.sh

# 4. Verify it. The profile must match, or the wrong assertions run.
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  alarm-base:latest /bin/bash /work/build/verify-image.sh \
  /work/out/uconsole-arch-cm5-sway.img runtime

# 5. Flash (macOS)
sudo ./flash-to-sd.sh disk4
```

Full instructions, including how to create the `alarm-base` container, are in
[`docs/BUILDING.md`](docs/BUILDING.md).

## Two images from one source

| | |
|---|---|
| `BUILD_PROFILE=runtime` | `uconsole-arch-cm5-sway.img` — the machine you use |
| `BUILD_PROFILE=dev` | `uconsole-arch-cm5-sway-dev.img` — plus test tools, a browser, media apps, and a pre-provisioned network |

The difference is **additive only**. Dev is runtime plus `overlay-dev/` plus extra
packages; no shipped file has a dev-only variant, so a fix cannot land in one tree and
miss the other.

The dev image adds `firefox`, `mpv`, `imv`, `neovim`, `powertop`, `strace`, `tcpdump`, and
`uconsole-selftest` — an on-device harness that checks what image verification cannot:
that the machine actually behaves. Every check in it exists because the corresponding bug
shipped once and looked correct from the outside.

```bash
uconsole-selftest            # read-only; safe any time, SSH included
uconsole-selftest --cycle    # also run a real blank/wake cycle and assert the restore
```

**Wi-Fi for the dev image comes from `secrets/wifi.env`, which is gitignored:**

```bash
printf 'WIFI_SSID=your-ssid\nWIFI_PSK=your-psk\n' > secrets/wifi.env
chmod 600 secrets/wifi.env
```

The build reads it at assembly time and writes a `0600` NetworkManager profile into the
dev image only. Nothing is echoed to the build log, the runtime image ships no connection
profile at all, and verification asserts both. This repository is public — a PSK committed
here would stay in the history after any later removal.

## Repository layout

```
build/         Build pipeline: kernel, image assembly, customisation, verification
overlay/       Files copied into the image root (configs, scripts, systemd units)
overlay-dev/   Additional files for the dev profile only
secrets/       Untracked build-time credentials (dev Wi-Fi); never committed
profiles/      Boot configuration — config.txt and cmdline.txt
flash-to-sd.sh Write an image to an SD card (macOS)
verify-card.sh Verify a flashed card against the image it came from
docs/          Detailed documentation
```

Build artifacts (`out/`, `cache/`, `stock/`, `repo/`) and fetched third-party sources
are deliberately untracked — see `.gitignore`.

## Documentation

| Document | Contents |
|---|---|
| [`docs/BUILDING.md`](docs/BUILDING.md) | The build pipeline in detail, and how to modify it |
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | uConsole + CM5 hardware notes and known defects |
| [`docs/USAGE.md`](docs/USAGE.md) | Operator commands: LTE, WAN routing, Tailscale, battery, tmux |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Problems hit during development and their fixes |
| [`docs/CHANGELOG.md`](docs/CHANGELOG.md) | What changed and why |

## Verification

Every build is checked before it reaches a card. The suite asserts partition geometry,
filesystem integrity, kernel and device-tree contents, boot configuration consistency
(`cmdline.txt`'s `root=LABEL=` against the actual filesystem label), the presence and
enablement of every service, and that configuration files actually parse — `sway
--validate` and `foot --check-config` both run against the shipped configs.

It also verifies that the built system can **install packages after boot**, which is a
different question from "packages installed during the build" and caught two real defects
that structural checks alone had missed.

Many checks exist because a specific bug got through. The suite asserts that the wake path
restores the backlight *to the same value* it had before, that the sudoers drop-in is
root-owned and `0440` (sudo silently ignores it otherwise), and that no script probes
privilege with a command different from the one it intends to run — each of which was a
real defect found by measuring the machine rather than reading the code.

```
RESULT: 406 passed, 0 failed
```

Structural verification is not a boot test. Nothing here has been validated by an
automated boot on real hardware.

## Credits

This work stands on:

- **[ak-rex/ClockworkPi-linux](https://github.com/ak-rex/ClockworkPi-linux)** — the kernel tree with uConsole panel, keyboard and PMIC support
- **[wdkdot/uconsole-arch](https://github.com/wdkdot/uconsole-arch)** — image build script and kernel PKGBUILDs this pipeline builds on
- **[clockworkpi/uConsole](https://github.com/clockworkpi/uConsole)** — hardware schematics and the CM5 4G scripts
- **[ak-rex images](https://images.ak-rex.com)** — the reference Debian images used to cross-check boot configuration
- **[tmux-plugins](https://github.com/tmux-plugins)** — TPM, resurrect, continuum

Several fixes in `overlay/usr/local/bin/` derive from an on-device defect report
covering LTE integration, boot behaviour and power measurements; the reasoning is
preserved in the script comments and in [`docs/HARDWARE.md`](docs/HARDWARE.md).

## License

The build scripts and configuration in this repository are provided as-is. Third-party
components retain their own licenses — the kernel is GPL-2.0, and the tmux plugins and
ClockworkPi scripts carry their upstream licenses. No license has been chosen for this
repository yet; add one before reusing this work.
