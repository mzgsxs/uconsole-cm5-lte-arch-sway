# Building

The whole pipeline runs in Docker on a native **aarch64** host (an Apple Silicon Mac, or
any arm64 Linux machine). No emulation is involved, which is why a full kernel build takes
around 30 minutes rather than most of a day.

## Prerequisites

- Docker with `linux/arm64` support
- ~25 GB free disk (an 8 GB image, an 800 MB rootfs tarball, a ~5 GB kernel tree)
- `git` and `curl` on the host

## Step 0 — the base container

Everything builds inside an Arch Linux ARM container created from the official rootfs
tarball, rather than a third-party image from Docker Hub:

```bash
curl -LO http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
docker import --platform linux/arm64 ArchLinuxARM-aarch64-latest.tar.gz alarm-base:latest
```

Keep the tarball in `cache/` — the image build reuses it rather than re-downloading.

## Step 1 — tmux plugins

```bash
./build/fetch-tmux-plugins.sh
```

Clones TPM, tmux-resurrect and tmux-continuum into `overlay/etc/skel/.tmux/plugins` at
pinned commits. They are fetched rather than vendored so this repository stays free of
nested git repositories.

## Step 2 — the kernel

```bash
docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work \
  -e KERNEL_COMMIT=84258d9b0b918966b495f84389959abfdcec77e4 \
  -e PKGDIR=linux-uconsole-cm5-4k-git \
  alarm-base:latest /bin/bash /work/build/build-kernel.sh
```

`build/build-kernel.sh` clones `ak-rex/ClockworkPi-linux` at the pinned commit, then
patches the upstream PKGBUILD in three ways before building:

1. **Native compilation.** The PKGBUILD uses `${KERNEL_CROSS_COMPILE:-aarch64-linux-gnu-}`,
   which falls back to a cross prefix even when the variable is set empty. On a native
   aarch64 host no `aarch64-linux-gnu-*` binaries exist, so the fallback is changed to
   `${VAR-default}` (unset-only).
2. **Landlock** (`CONFIG_SECURITY_LANDLOCK`). `bcm2712_defconfig` leaves it off, but
   pacman 7 sandboxes its downloader with it and hard-fails without it.
3. **Suspend** (`CONFIG_SUSPEND`, `CONFIG_PM_SLEEP`). The stock defconfig registers no
   sleep states at all, leaving `/sys/power/state` empty.

Output lands in `out/` as a `.pkg.tar.xz`.

### Choosing 4K vs 16K pages

`PKGDIR=linux-uconsole-cm5-4k-git` selects 4K pages. The 16K variant
(`linux-uconsole-cm5-git`) is marginally faster and uses less memory, but breaks box64,
some Electron builds and various prebuilt binaries. Both install into the *same* boot slot
(`vmlinuz-linux-uconsole-cm5-git`), so `config.txt` needs no change when switching.

### Battery capacity in the device tree

The uConsole CM5 overlay hardcodes ClockworkPi's stock 6700 mAh pack, and that value is
what the driver reports as `charge_full_design`. `build-kernel.sh` patches it to match the
cells actually fitted:

```bash
-e BATTERY_MAH=7000     # 2x 3500mAh 18650 in parallel; use 4000 for the 2x2000 pair
```

The patch is asserted, not assumed — if the property moves or upstream changes the value,
the build fails rather than silently shipping the stock figure. It does not fix the fuel
gauge, which reads high because it is uncalibrated.

## Step 3 — the image

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  -e BUILD_PROFILE=runtime \
  alarm-base:latest /bin/bash /work/build/build-image-full.sh
```

**Build the two profiles one at a time.** Step 2 does `rm -rf /work/repo/aarch64` to
rebuild the local package repository, and that path is shared through the bind mount — two
concurrent builds race over it and one fails partway with the image already deleted.

`BUILD_PROFILE` selects which of the two trees is assembled:

| Profile | Output | Adds |
|---|---|---|
| `runtime` (default) | `uconsole-arch-cm5-sway.img` | — |
| `dev` | `uconsole-arch-cm5-sway-dev.img` | `overlay-dev/`, `PKGS_DEV`, Wi-Fi from `secrets/wifi.env` |

**The split is additive, deliberately.** `dev` is `runtime` plus extra files and extra
packages — no shipped file has a dev-only variant. The alternative, two overlays that both
contain the same script, means a fix can land in one and miss the other, and the tree that
gets tested is usually not the tree that ships.

Dev-only Wi-Fi credentials live in `secrets/wifi.env` (gitignored, `0600`):

```bash
printf 'WIFI_SSID=your-ssid\nWIFI_PSK=your-psk\n' > secrets/wifi.env
```

`customize-image.sh` reads it and writes a `0600` root-owned `.nmconnection` into the dev
image. It deliberately logs neither value — build logs get pasted into issues. Without the
file, the dev build proceeds and says it provisioned no network.

`--privileged` is required for loop devices. The script:

1. Builds a local pacman repository from the packages in `out/` and serves it over
   `127.0.0.1:8089`. `arch-chroot` shares the network namespace, so the chroot can reach
   it — no bind-mounting needed.
2. Clones `wdkdot/uconsole-arch` and patches its `build-image.sh`: selects the 4K kernel
   package, and renames the filesystem labels to `UCONSOLE` / `uconsole-root`
   consistently across `mkfs`, `fstab` and `cmdline.txt`.
3. Installs `profiles/config.txt` and `profiles/cmdline.txt` over the upstream ones.
4. Installs the `partprobe` shim (see below).
5. Runs the upstream build, then applies `build/customize-image.sh`.

### The partprobe shim

Docker Desktop's `/dev` is a plain tmpfs and no in-container udev can populate it. `losetup
-P` registers partitions with the kernel — they appear in sysfs — but `/dev/loopNpM` nodes
are never created, so the upstream script fails at its first partition access.

`build/install-partprobe-shim.sh` wraps `partprobe` so that every rescan also creates the
missing device nodes with `mknod`, reading major/minor from sysfs. This leaves the upstream
script untouched.

## Step 4 — customisation

`build/customize-image.sh` mounts the built image and, in a chroot:

- Removes the stock `linux-aarch64` kernel (~60 MB of unusable `/boot`, and a future
  `-Syu` could have it rewrite files there)
- Strips the build-time `[uconsole-arch]` pacman repository, whose `127.0.0.1` address is
  dead on a real device
- Sets the locale, sudo for `wheel`, and user groups
- Copies **all** of `/etc/skel` into the `alarm` home
- Enables services and disables `systemd-networkd`
- Verifies pacman can sync and resolve packages from the real repositories

## Step 5 — verification

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD":/work -w /work \
  alarm-base:latest /bin/bash /work/build/verify-image.sh \
  /work/out/uconsole-arch-cm5-sway.img runtime
```

The second argument is the profile, and it is cross-checked against what is actually
inside the image — verifying a dev image as `runtime` fails loudly rather than quietly
running the wrong assertions. Counts: **413** for runtime, **417** for dev.

Structural verification cannot prove behaviour. The dev image carries
`uconsole-selftest` for that, and it must be run on the device:

```bash
uconsole-selftest --cycle
```

See [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for why several checks are written the
way they are — a few exist specifically because an earlier, more obvious formulation gave
false results.

## Modifying the image

Most changes belong in `overlay/`, which is copied verbatim into the image root. Add a file
there, add a check to `build/verify-image.sh`, rebuild.

Boot-level changes go in `profiles/config.txt` or `profiles/cmdline.txt`.

Package changes go in the `PKGS` array in `build/build-image-full.sh`.

Service enablement goes in `build/customize-image.sh`.

**Add a verification check for anything you add.** The suite is the only thing standing
between a build and a card that does not boot.
