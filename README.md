# r26-mainline

Mainline Linux on the network streamer inside the Gustard R26 DAC (SigmaStar SSD202D / Infinity2M,
2x Cortex-A7, 128 MiB). The stock kernel is a vendor 4.9.84 with no source released.

Status (stable v7.3.6): Debian 12 boots on it with every service up, started from the running stock
system by the `r26kexec` loader. The boot shim that lets the stock U-Boot start it is written and tested
through the loader, but not installed yet. See `PORT-STATUS.md`.

| Part | State |
|---|---|
| EMAC + internal PHY (macb) | works, 100 Mbps |
| USB host (FUSBH200 EHCI) + PHY | works, high speed; the DAC's XMOS enumerates at 480 Mbps |
| SD host (new `sstar-sdio` driver) | works, verified byte-exact reads and writes |
| clocks, pinctrl, GPIO, interrupts, RTC | from linux-chenxing, working |
| uart0 | ns16550a, pins on the board unknown |
| boot via U-Boot | `shim/`: tested through the loader, not yet installed in place of `/GustardCore` |

## Layout

| Path | What |
|---|---|
| `kernel/patches/` | the series on top of stable v7.3.6 (`git am`) |
| `config/r26.config` | production fragment (applied on `allnoconfig`, distro-agnostic) |
| `config/r26-test.config` | extra options for loader test kernels only |
| `build.sh` | fetch v7.3.6, apply the series, build `zImage` + DTB (`./build.sh test` for a test kernel) |
| `loader/` | `r26kexec`: start a new kernel from the running stock 4.9 kernel through `/dev/mem`, with the hardware watchdog as a hard deadline back to stock |
| `initramfs/` | test initramfs (busybox, dropbear, netconsole/UDP logging, optional switch_root to the SD rootfs) |
| `shim/` | boot shim: one `/GustardCore` image holding the stock and mainline kernels; picks one per boot from the reset-cause registers, so power-on, a watchdog reset and mainline's own reboot always land on stock |
| `sim/` | QEMU rehearsal of the loader |
| `re/` | reverse-engineering notes and tools: vendor kernel function matching, the SD host and USB init specs, a read-only SPI NAND dumper (`re/tools/spinand-dump`, recipe in `re/spinand-read.md`) |

## Notes

- Never put `CONFIG_EXPERT=y` in the fragment: on `allnoconfig` it switches off every default-y
  EXPERT option, including `ARM_PATCH_PHYS_VIRT`.
- No vendor binaries, dumps or captures are in this repository.
- Kernel commits carry `Assisted-by: Claude:claude-opus-5-5`.
