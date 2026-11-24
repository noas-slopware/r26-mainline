# r26-mainline

Mainline Linux on the network streamer inside the Gustard R26 DAC (SigmaStar SSD202D / Infinity2M,
2x Cortex-A7, 128 MiB). The stock kernel is a vendor 4.9.84 with no source released.

Status (stable v7.3.6): the R26 runs it. The stock U-Boot boots the mainline kernel and DTB straight from
the card as `/GustardCore` and `/00`, and the stock Debian 12 comes up with every service, playing through
RoonBridge. See `PORT-STATUS.md` and `re/FINDINGS.md`.

| Part | State |
|---|---|
| EMAC + internal PHY (macb) | works, 100 Mbps |
| USB host (FUSBH200 EHCI) + PHY | works, high speed; the DAC's XMOS enumerates at 480 Mbps |
| SD host (new `sstar-sdio` driver) | works, verified byte-exact reads and writes |
| clocks, pinctrl, GPIO, interrupts, RTC | from linux-chenxing, working |
| uart0 | ns16550a, pins on the board unknown |
| boot via U-Boot | works: plain `zImage` as `/GustardCore`, DTB as `/00` |
| SMP, cpufreq | both cores, fixed 1 GHz like stock |
| watchdog | armed by systemd (`systemd.watchdog_sec=30` on the built-in command line) |

## Layout

| Path | What |
|---|---|
| `kernel/patches/` | the series on top of stable v7.3.6 (`git am`) |
| `config/r26.config` | production fragment (applied on `allnoconfig`, distro-agnostic) |
| `config/r26-test.config` | extra options for loader test kernels only |
| `build.sh` | fetch v7.3.6, apply the series, build `zImage` + DTB (`./build.sh test` for a test kernel) |
| `loader/` (`mktestdtb.sh` derives its test DTB) | `r26kexec`: start a new kernel from the running stock 4.9 kernel through `/dev/mem`, with the hardware watchdog as a hard deadline back to stock |
| `initramfs/` | test initramfs (busybox, dropbear, netconsole/UDP logging, optional switch_root to the SD rootfs) |
| `shim/` | boot shim used for the switch-over: one `/GustardCore` image holding the stock and mainline kernels, picking one per boot from the reset-cause registers so every failure lands on stock |
| `sim/` | QEMU rehearsal of the loader |
| `re/` | reverse-engineering notes and tools: vendor kernel function matching, the SD host and USB init specs, a read-only SPI NAND dumper (`re/tools/spinand-dump`, recipe in `re/spinand-read.md`) |

## Notes

- Never put `CONFIG_EXPERT=y` in the fragment: on `allnoconfig` it switches off every default-y
  EXPERT option, including `ARM_PATCH_PHYS_VIRT`.
- No vendor binaries, dumps or captures are in this repository.
- Kernel commits carry `Assisted-by: Claude:claude-opus-5-5`.

## Installing

Copy `out/zImage` to `/GustardCore` and the DTB to `/00` on the card's first partition (keep the stock
pair beside them). The stock U-Boot loads both by name, replaces the DTB's bootargs with its own
(`panic=3 rootwait root=/dev/mmcblk0p1 rw clk_ignore_unused`) and sets `/memory`; the kernel's built-in
command line adds the console and the watchdog handover.
