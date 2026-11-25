# r26-mainline

Mainline Linux on the network streamer inside the Gustard R26 DAC. It's a SigmaStar SSD202D
(Infinity2M, 2x Cortex-A7 at 1 GHz, 128 MiB). Gustard ships a vendor 4.9.84 kernel and never
released its source. Of course they didn't.
Port by Noa Himesaka. Not affiliated with Gustard.

With this series, the R26 runs stable **v7.3.6**. The stock U-Boot boots it straight from the SD
card, with no shim and nothing written to the on-board flash. Alpine Linux plays to Roon through
[raat-endpoint](https://github.com/noas-slopware/raat-endpoint), a native RAAT endpoint replacing
RoonBridge. There are Alpine packages in a signed apk repository, plus a card image.
Check [`STATUS.md`](STATUS.md) for what works and what's still open.

## Quickstart: Alpine on the R26

1. Connect the USB-C service port on the back of the R26 to a Linux machine. The streamer's microSD
   card shows up as a USB drive.
2. Write `alpine-gustard-r26-<date>.img.zst` from the
   [latest release](https://github.com/noas-slopware/r26-mainline/releases/latest) to it.
3. Put your SSH public key in `/root/.ssh/authorized_keys` on the card.
4. Boot, `ssh root@<its address>` (hostname `gustard-r26`), and enable the DAC in Roon's audio settings.

See [`docs/install.md`](https://github.com/noas-slopware/r26-mainline/blob/docs/docs/install.md)
for the full guide (growing the partition, updates, recovery, and going back).
It replaces Gustard's own system on the card and is Roon only. Tidal Connect, Spotify Connect,
AirPlay, and NAA aren't in it.

## Packages

The apk repository is `https://noas-slopware.github.io/r26-mainline/alpine/v3.24/gustard-r26`
(armv7, Alpine 3.24), mirrored at
`https://mirror.funami.tech/r26-mainline/alpine/v3.24/gustard-r26`, and signed with
`r26-mainline-1cc0db58.rsa.pub`. If your R26 already runs Alpine:

```sh
wget -O /etc/apk/keys/r26-mainline-1cc0db58.rsa.pub \
    https://noas-slopware.github.io/r26-mainline/alpine/r26-mainline-1cc0db58.rsa.pub
apk add -X https://noas-slopware.github.io/r26-mainline/alpine/v3.24/gustard-r26 device-gustard-r26-repo
apk add device-gustard-r26 raat-endpoint
```

| package | what |
|---|---|
| `linux-gustard-r26` | the kernel: stable 7.3.6 + `patches/linux` + `config/r26.config` |
| `device-gustard-r26` | puts the kernel where U-Boot loads it (`r26-boot-deploy`), plus the watchdog feeder service (`-repo` is this repository and its key) |
| `raat-endpoint` | the native RAAT (Roon Ready) endpoint, with `raat-endpoint-openrc` |

## Branches

| branch | contents |
|---|---|
| `senpai` | this README, `STATUS.md`, `patches/linux/`, `config/`, `userspace/`, `tools/`, `LICENSES/` |
| `docs` | the install guide, the reverse-engineering notes and tools |
| `alpine` | the APKBUILDs, the package build and the image build |
| `ci` | the workflow that builds the packages and publishes the repository on GitHub Pages |

The branches are independent histories. Check them out side by side with `git worktree`.

### `senpai`

- `patches/linux/`: 26-patch series on stable `v7.3.6` (`git am`). Patches 0014 and 0018 add
  test-only boot breadcrumb drivers, which the production config leaves off.
- `config/r26.config`: the distro-agnostic production fragment, applied on `allnoconfig`.
  `config/r26-alpine.config` puts root on the card's second partition so Gustard's system can stay
  on the first, and `config/r26-test.config` is for loader test kernels.
- `build.sh`: fetches v7.3.6, applies the series, and builds `zImage` and the DTB (`./build.sh`,
  `./build.sh alpine`, `./build.sh test`) using LLVM (`clang`, `ld.lld`).
- `userspace/`: distro-neutral sources for what the device package installs
  (`boot-deploy/r26-boot-deploy`, `openrc/hw-watchdog`).
- `tools/bringup/`: what brought the port up. `loader/` (`r26kexec`, which boots a new kernel from
  the running stock 4.9 kernel through `/dev/mem`, using the watchdog as a deadline back to stock),
  `shim/` (one `/GustardCore` image holding two kernels, picking one per boot from the reset cause),
  `initramfs/` (busybox, dropbear, netconsole), and `sim/` (QEMU rehearsal of the loader).
  The network addresses in them are documentation placeholders (`192.0.2.x`), so put in your own.
- `tools/alpine-from-debian/`: builds an Alpine root from a running stock Debian, keeping its SSH
  keys, DHCP client id, and Roon identity (for the Alpine-on-p2 layout).

## Building the kernel

```sh
./build.sh          # root on the card's first partition
./build.sh alpine   # root on the second partition (set its PARTUUID in config/r26-alpine.config)
```

Output goes to `out/build-<variant>/arch/arm/boot/zImage` and
`out/build-<variant>/arch/arm/boot/dts/sigmastar/mstar-infinity2m-ssd202d-gustard-r26.dtb`. The
stock U-Boot loads them as `/GustardCore` and `/00` from the card's first partition, replaces the
DTB's bootargs with `panic=3 rootwait root=/dev/mmcblk0p1 rw clk_ignore_unused`, and appends
nothing. The kernel's built-in command line goes after that. And never put `CONFIG_EXPERT=y` in
the fragment. On `allnoconfig` it switches off every default-y EXPERT option, `ARM_PATCH_PHYS_VIRT`
included.

## Authors and credits

- Noa Himesaka: the port, the R26 device tree, the SD host driver, the EMAC, watchdog, regulator and
  SAR GPIO work, the boot tools, the Alpine packaging. Kernel commits carry
  `Assisted-by: Claude:claude-opus-5-5`.
- Daniel Palmer and the [linux-chenxing](https://github.com/linux-chenxing/linux) project: the
  MStar/SigmaStar clock, pinctrl, GPIO, interrupt, USB, PHY and EMAC drivers and the Infinity2M
  device tree that this series forward-ports from its `mstar_v6_7_rebase` branch. Their copyright
  lines are kept in the files, and each such commit says where it comes from.
- Daniel Palmer and Romain Perier: the mainline MStar watchdog driver the series extends.

No vendor binaries, dumps or captures are in this repository.

## License

Licenses vary by directory (details in [`LICENSES/README.md`](LICENSES/README.md)). `patches/linux`
and `config` are GPL-2.0-only, `userspace` is MIT, and the APKBUILDs are per package.
