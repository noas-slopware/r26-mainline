# r26-mainline

Mainline Linux on the network streamer inside the Gustard R26 DAC: a SigmaStar SSD202D (Infinity2M,
2x Cortex-A7 at 1 GHz, 128 MiB). Gustard ships a vendor 4.9.84 kernel and never released its source.

The R26 now runs stable **v7.3.6** with this series. The stock U-Boot boots the kernel and DTB straight
from the SD card, with no shim and nothing written to the on-board flash. The userland is Alpine 3.24,
and the DAC plays through [raat-endpoint](https://github.com/noas-slopware/raat-endpoint), a native
RAAT endpoint that replaces RoonBridge. The stock Debian 12 still boots from the same card with the base
kernel. Current state and open items: [`STATUS.md`](STATUS.md). The full lab log: [`re/FINDINGS.md`](re/FINDINGS.md).

## Hardware support

| Block | Driver | State |
|---|---|---|
| Ethernet: EMAC + internal 10/100 PHY | `macb` (MStar path), `msc313` PHY | 100 Mbps full duplex, no corrupted frames (TX queue run as the vendor driver does), counters read through the X32 bank |
| MAC address | `macb` | derived from the SoC's unique ID; U-Boot makes up a random one at every power-on |
| USB host + PHY | `ehci-fotg210` (FUSBH200 glue), `phy-msc313-usb` | high speed; the DAC's XMOS (`20b1:3033`) enumerates at 480 Mbps |
| USB audio | `snd-usb-audio` | bit-perfect, 44.1 to 96 kHz verified |
| SD card | `sstar-sdio` (new) | high speed, byte-exact reads and writes verified |
| CPU | SMP, `cpufreq-dt` | both cores, 1 GHz at 900 mV as stock; the core voltage is a GPIO VID regulator, one bit of it a SAR pad (`gpio-msc313-sar`, new) |
| Watchdog | `msc313e_wdt` | `nowayout`: once userspace opens it, nothing switches it off; it keeps running through a restart |
| Clocks, pinctrl, GPIO, interrupts, RTC | from linux-chenxing, forward-ported | working |
| UART0 | `8250_dw` | bound as the console; its pins on the board are unknown, so the output is unverified |
| Display, SATA, MIPI, audio codec | none | not used on the R26 |

## Layout

| Path | What |
|---|---|
| `kernel/patches/` | the series on top of stable v7.3.6 (`git am`); 0014 and 0018 are test-only breadcrumb drivers, off in the production config |
| `config/r26.config` | production fragment, applied on `allnoconfig`, distro-agnostic |
| `config/r26-alpine.config` | Alpine add-on: the root on the card's second partition |
| `config/r26-test.config` | extras for loader test kernels only |
| `build.sh` | fetch v7.3.6, apply the series, build `zImage` and the DTB |
| `alpine/` | builds the Alpine root filesystem for the R26 |
| `shim/` | the boot shim used for bring-up and kernel experiments: one `/GustardCore` image with two kernels, picking one per boot from the reset cause, so any failure lands on a known-good kernel |
| `loader/` | `r26kexec`: start a new kernel from the running stock 4.9 kernel through `/dev/mem`, with the watchdog as a hard deadline back to stock (how the first boots were done) |
| `initramfs/` | test initramfs: busybox, dropbear, netconsole and UDP logging |
| `sim/` | QEMU rehearsal of the loader |
| `re/` | reverse-engineering notes and tools: vendor kernel function matching, the SD host and USB init specs, a read-only SPI NAND dumper, a read-only register peek |

## Building

```sh
./build.sh          # production kernel, root on the card's first partition (stock Debian)
./build.sh alpine   # production kernel, root on the second partition (set its PARTUUID in config/r26-alpine.config)
./build.sh test     # loader test kernel (adds config/r26-test.config and the initramfs)
```

The output is `out/build-<variant>/arch/arm/boot/zImage` and
`out/build-<variant>/arch/arm/boot/dts/sigmastar/mstar-infinity2m-ssd202d-gustard-r26.dtb`.
Builds use LLVM (`clang`, `ld.lld`).

## Installing

The stock U-Boot loads `/GustardCore` (a plain `zImage`) and `/00` (the DTB) by name from the card's
first partition. It replaces the DTB's bootargs with its own, `panic=3 rootwait root=/dev/mmcblk0p1 rw
clk_ignore_unused`, and sets `/memory`. The kernel's built-in command line is appended after that:
the console and, for Alpine, `root=PARTUUID=... ro`, which wins over U-Boot's `root=`.

1. Keep the stock pair: copy `/GustardCore` and `/00` to `/GustardCore.stock` and `/00.stock`.
2. Copy the new `zImage` to `/GustardCore` and the DTB to `/00`, `sync`, reboot.

Going back is the same with the stock pair, from the running system or through a card reader.
The on-board SPI NAND (IPL and U-Boot) is never written by anything here.

## Notes

- Never put `CONFIG_EXPERT=y` in the fragment: on `allnoconfig` it switches off every default-y
  EXPERT option, including `ARM_PATCH_PHYS_VIRT`.
- No vendor binaries, dumps or captures are in this repository.
- Kernel commits carry `Assisted-by: Claude:claude-opus-5-5`.
