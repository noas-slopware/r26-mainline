# R26 mainline port status

> Early working log, kept for history. Current state: `README.md` and `re/FINDINGS.md`.

Plan: `~/.claude/plans/read-handover-md-and-plan-snuggly-lerdorf.md`. RE results: `re/FINDINGS.md`.

## Tree
- `~/r26-mainline/linux`, branch `r26/port` (from `senpai` = stable **v7.3.6**). Remotes: stable, chenxing, slop. Nothing is committed yet; the work sits in the index plus the working tree.
- Build: `make O=~/r26-mainline/build/r26 ARCH=arm LLVM=1 CC="ccache clang" KCONFIG_ALLCONFIG=~/r26-mainline/config/r26.config allnoconfig`, then `zImage`.
  - `allnoconfig` drops `MMU`, so the fragment sets it.
  - The fragment deliberately has **no watchdog driver** (hard deadline for the test loader).

## Ported from chenxing `mstar_v6_7_rebase` (final state of the files, not its commit history)
- **Builds clean on 7.3.6:**
  - pinctrl (`drivers/pinctrl/mstar/*`), gpio-msc313 (irq + lock);
  - irqchips: `irq-ssd20xd-gpi`, `irq-msc313-pm-intc`, `irq-msc313-pm-wakeup`;
  - clk (`drivers/clk/mstar/*`), clocksource divider fix, syscon `use-raw-spinlock`;
  - USB PHY (`phy-msc313-usb`) + EHCI glue (`ehci-fotg210.c`, symbol renamed to `USB_EHCI_FUSBH200` to dodge 7.3's fotg210) + `ehci.h`/hcd hooks;
  - MSC313 internal PHY (`drivers/net/phy/msc313.c`);
  - headers `include/soc/mstar/{riuxiu,pmsleep}.h`, `include/linux/usb/{mstar_usbc,mstar_utmi}.h`, dt-bindings.
- **7.3 API fixes:**
  - `irq_domain_create_linear(dev_fwnode())`;
  - pinctrl `group_desc.grp`, const `function_desc`;
  - `platform_device.h` includes;
  - EHCI `.remove` now returns void;
  - error paths fixed: an uninitialized `retval` in the EHCI probe, an unchecked `request_irq`, an unchecked `regulator_enable`.
- **macb: hand port onto 7.3** (not chenxing's code as-is):
  - RIU split-register accessors;
  - the at91ether TX ring generalized to 2 (RM9200) or 4 (MStar) entries, with MStar's TSR queue-free decode;
  - TX-ring reset on open (chenxing lacked it);
  - correct ring index math;
  - caps on free bits `BIT(29)`/`BIT(30)` (chenxing's collided with `MIIONRGMII`/`NEED_TSUCLK`);
  - `msc313_init` magic regs, `mstar,msc313{,e}-emac`.
  - Not taken: XIU mapping, the "diet" that hides the other compatibles.
- **Left out on purpose:**
  - chenxing `arch/arm/mach-mstar` WIP (PM/suspend, other SoCs);
  - the `8250_dw` msc313 quirk (only for UART DMA; mainline's pm_uart is `ns16550a`);
  - display, SATA, SSD210, SSC8336.

## Next
1. **DTS: DONE (emac, uhc2, CMA reserve; SD node pending the driver).** The chenxing dtsi stack (clkgen, sc_gp muxes, eth_buf, pinctrl groups, MIU `dma-ranges` via `interconnects = <&miu 0>` "dma-mem") is tightly interlinked. Port the I2M subset of it plus `mstar-infinity2m-ssd202d-gustard-r26.dts`.
   - Check against `stock/00.dts` and `stock/live/live.dts`.
   - emac0 internal PHY, `uhc2@285000` + `usbphy2` (the XMOS), SD with CD gpio 58.
   - Reserve `0x27e00000+2M` (stock CMA) for the kexec tests.
2. **SD driver:** new `drivers/mmc/host/sstar-sdio.c` from `vendor-tky/drivers/sstar/sdmmc` (ground truth, see `re/FINDINGS.md`).
3. **Test initramfs: DONE** (busybox 1.38.0 + dropbear 2026.94 static, key-only, static IP, netconsole + dmesg push).
4. **devmem-kexec loader: DONE** (rehearsed in QEMU, T1 passed, run 1 booted 7.3.6 on the R26: see re/FINDINGS.md)
5. **T1: DONE** (watchdog reset recovers to stock)
6. Clean commits per driver with `Assisted-by: Claude:claude-opus-5-5`.

## 2026-11-24 13:17 milestone
- **Debian 12 boots on mainline 7.3.6** via r26kexec (run 17): systemd running, 0 failed units, roonbridge/ssh/networkd/chrony/swap active, DAC at 480 Mbps.
- **New:**
  - `drivers/mmc/host/sstar-sdio.c` (SD, verified byte-exact reads and writes);
  - the vendor-exact USB PHY init (`sstar,ssd20xd-usb-phy`) + EHCI `port_reset_hook` (HS chirp);
  - the macb xmit lock fix;
  - `pm_uart` on ns16550a.
- **Config:** `config/r26.config` (production, distro-agnostic) + `config/r26-test.config` (test only), built by `build-test.sh`. Never put CONFIG_EXPERT in the fragment.
- **Open:**
  1. First boot through U-Boot (real `/GustardCore` replacement). It's blind and unrecoverable without someone at the box, unless a reset-flag shim is built, and that needs U-Boot's load addresses (SPI NAND dump).
  2. Production DTS/config: full 128 MiB, SMP, watchdog driver, cpufreq; no test bootargs.
  3. Clean per-driver commits (`Assisted-by`). Nothing is committed yet.
  4. Rootfs: `[DHCPv4] IAID=0x6d804853` in `eth0.network` to keep .46 (Noa's call).
  5. RAAT: capture the Core's Lua script (Noa's call).
  6. Netconsole to a second target (configfs) still gets 0 lines (minor).
