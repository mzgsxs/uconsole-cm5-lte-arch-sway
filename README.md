# uConsole CM5 — Arch Linux ARM + Sway

A reproducible build system that produces a bootable **Arch Linux ARM** image with a
**Sway** desktop for the [ClockworkPi uConsole](https://www.clockworkpi.com/uconsole)
fitted with a **Raspberry Pi Compute Module 5**.

The kernel is compiled from source; the image is assembled and then checked by an
automated verification suite — currently **212 checks**, all passing.

> **Read [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) before your first boot.**
> A CM5 Lite will very likely *not* boot from SD until its bootloader EEPROM is
> reconfigured. This is a firmware defect, not an image problem, and no amount of
> reflashing fixes it.

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
| **First boot** | Prompts for a username and password; expands the root filesystem to fill the card |

## Quick start

```bash
# 1. Fetch the third-party tmux plugins into the overlay
./build/fetch-tmux-plugins.sh

# 2. Build the kernel package (~30 min, native aarch64 in Docker)
docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work \
  -e KERNEL_COMMIT=84258d9b0b918966b495f84389959abfdcec77e4 \
  -e PKGDIR=linux-uconsole-cm5-4k-git \
  alarm-base:latest /bin/bash /work/build/build-kernel.sh

# 3. Build the image
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  alarm-base:latest /bin/bash /work/build/build-image-full.sh

# 4. Verify it
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  alarm-base:latest /bin/bash /work/build/verify-image.sh /work/out/uconsole-arch-cm5-sway.img

# 5. Flash (macOS)
sudo ./flash-to-sd.sh disk4
```

Full instructions, including how to create the `alarm-base` container, are in
[`docs/BUILDING.md`](docs/BUILDING.md).

## Repository layout

```
build/         Build pipeline: kernel, image assembly, customisation, verification
overlay/       Files copied into the image root (configs, scripts, systemd units)
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

```
RESULT: 212 passed, 0 failed
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
