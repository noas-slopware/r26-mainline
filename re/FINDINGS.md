# R26 kernel RE findings

Shipped: `stock/GustardCore.Image` (4.9.84 #30, 2022-12-02), base 0xc0008000. It is a **Thumb-2 kernel** (`CONFIG_THUMB2_KERNEL=y`, `-Os`); the head is `add r9, pc, #1; bx r9`.

## Closest vendor source
- Branch `linux-chenxing-vendor-slop` **`takoyaki_dls00v050`** (2022-01-03), an Infinity2M-only SDK tree. It covers 53/55 of the shipped sdmmc strings.
  - Other branches cover less: ikayaki 52, pudding 50, myzr-gateway 49, ispahan 48, v4.9.84-sigmastar 32, Pcupid 21.
  - The 2 misses are a mmc-core path string and the irq name `ms_sdmmc_mie`.
- Rebuild: worktree `~/r26-mainline/vendor-tky`.
  - Defconfig `infinity2m_ssc010a_s01a_defconfig` (matches the DT model `SSC010A-S01A-S`).
  - Changes: all `=m` set to `=y`, `MODULES` off, `MS_SDMMC`/`MS_PADMUX`/`MS_WATCHDOG`/`USB_EHCI_HCD` on, LZ4, kallsyms + DEBUG_INFO.
  - Toolchain: Arm GNU 8.2-2018.08 arm-linux-gnueabihf, which gives the exact version string of the shipped kernel.
  - One local fix: Python 3 `print()` in `scripts/ms_gen_mvxv_h.py`. The zImage post-processing script (`ms_bin_option_update_int.py`) is also Python 2, but `vmlinux` builds and that's all RE needs.

## Function matching (`tools/fnmatch.py`, output `match-tky.tsv`)
- The signature masks Thumb-2 BL/BLX/B.W, MOVW/MOVT immediates, and LDR-literal pool words.
- Result: 9035 unique, 862 multi, 8774 none (of 18671 FUNC symbols, each >= 16 bytes).
- Ghidra project: `ghidra-proj/` (program `shipped`, raw ARM:LE:32:v7 with TMode over 0xc0008000..0xc02b3020, 9034 names applied; program `vendor-tky`).
- `tools/ghidra/R26Decomp.java` applies names and decompiles a list of functions. `tools/norm.sh` normalizes the output for diffing.

## SD (`drivers/sstar/sdmmc`): shipped == takoyaki source
- `Hal_SDMMC_*` / `Hal_CARD_*`, i.e. all register access, are **byte-identical** after masking. A few small ones (`Hal_CARD_PowerOn`, `Hal_CARD_INT_MIE`, `Hal_CARD_SetGPIOIntAttr`) only differ in pool addresses and callee names.
- The Linux glue (`ms_sdmmc_probe`, `_dts_init`, `_request`, `_set_ios`, `_hotplug`, `_get_cd`, `_get_ro`, `_init_card`, `_enable_sdio_irq`) is **identical logic**. The decompiled diffs only show three things:
  - struct offsets +0x80 in `struct mmc_host` and `struct device`, i.e. a Gustard config with extra fields;
  - `struct scatterlist` 0x14 instead of 0x10 (`dma_length` present: `NEED_SG_DMA_LENGTH`);
  - `__udivsi3` vs `__aeabi_uidiv` naming, plus unnamed callees.
- **Ground truth for the new mainline driver:**
  - `vendor-tky/drivers/sstar/sdmmc/src/hal_sdmmc_v5.c`
  - `src/infinity2m/hal_card_platform.c`
  - `src/hal_card_intr_v5.c`
  - `ms_sdmmc_lnx.c`
  - plus the shipped DT params (`stock/00.dts` node `sdmmc`).
- Layout note: Gustard's code after `ms_sdmmc_probe` is 196 bytes shorter, and `ms_sdmmc_request` is 4 bytes longer. Both come from the config and inlining, as above.

## Still to check
- emac, padmux, wdt: the same diff pass. The first numbers look like the same offset story, but they're not verified yet.
- The restart path (which register a stock `reboot` hits) and what `infinity-wdt` does at probe. Both feed the fallback shim design.
- What sets gpio 49/72.

## Reset cause, flash type, RAM retention (live, 2026-11-24)
- **T0 = one stock soft reboot** (`systemctl reboot` at 10:28:22 KST). It was back on SSH 27 s later, same IP (the DHCP client ID is a DUID, so the random MAC doesn't matter). roonbridge and ssh were active, no failed units.
- `riuread` (`tools/riuread/`, static nolibc, read-only mmap of /dev/mem) results:
  - **PM POR reg1 `0x1F000C04`**: `0000` after the cold boot, `0001` after the soft reboot. The vendor's `global_reset` -> `msys_set_rebootType(SW_RST)` sets bit0, and per the vendor comment it's only cleared by a HW reset or power-on.
  - **WDT reg2 `0x1F006008`**: `0900` both times, so bit0 (the watchdog-reset flag) is clear. It's write-1-to-clear (the vendor does `SETREG16(..., BIT0)` to clear it). WDT period regs `0x1F006010/14` = 0, so stock never arms the watchdog.
  - **DIDKEY `0x1F0071C0`** = `0a04`, and `& 0x3C` = BIT2, which is **STORAGE_SPI_NAND**. So IPL, U-Boot and env are on SPI NAND. No memory-mapped NOR window exists, so never read `0x14000000`.
- **DRAM is not retained across a reboot.** 0 of 71,919 copies of a random tmpfs marker survived. Any DRAM-based flag for a boot shim would silently fail.
- No leftover copy of the zImage or the original `/00` was found after the reboot, only U-Boot's relocated FDT at `0x26f7e000` (totalsize `0x9000`). U-Boot's load addresses for `/GustardCore` and `/00` are still unknown, so the safe shim size is unknown too (only 2,653,760 bytes is proven).
- Vendor U-Boot SDK (`uboot_msc313e` `ssd20x_sdk`): `CONFIG_HW_WATCHDOG` is off, and nothing reads the reboot type.
- RAM dumps: `ramdumps/` (mode 700; they hold keys, never share them).

## Test loader: "devmem kexec" from stock (design, not built yet)
The card is never modified. Every failure, and every finished session, ends in a watchdog reset into an untouched stock boot.

Shipped image addresses, from `machine_restart` @ `0xc000eaa8`:
- `arm_pm_restart` var: **`0xc03b5114`** (phys `0x203b5114`). It's reached as literal `0xc03b5090` + 0x84 and normally points to `global_reset` `0xc0018f08`.
- `reboot_mode` var: **`0xc03956b4`** (phys `0x203956b4`).
- `_soft_restart(addr, disable_l2)`: `0xc000ea44` (Thumb, so call `0xc000ea45`). Same as vendor source `arch/arm/kernel/reboot.c:60`.
- `machine_restart` = `cpsid i; smp_send_stop(); if (arm_pm_restart) arm_pm_restart(reboot_mode, cmd); mdelay(1000); printk; b .`, so it spins forever with IRQs off if the call returns.

Sequence (stock userspace, root):
1. A holder process (mlock'd pages, PFNs via `/proc/self/pagemap`, only pages outside the copy destination) holds the trampoline, page list, mainline zImage and DTB.
2. Unbind the vendor wdt driver. It has `.shutdown = infinity_wdt_shutdown` (which stops the timer) and its remove also stops it, so it must be gone before arming.
3. Arm the hardware watchdog by direct register writes, period per test (about 90 s). It stays armed through everything after this point.
4. Through `/dev/mem`: `arm_pm_restart = 0xc000ea45`, `reboot_mode = trampoline phys`. That's data only, and no new code runs under stock's MMU.
5. `sync`, then `reboot -ff` (reboot(2) straight away; processes, holder included, stay alive). `device_shutdown()` quiesces the drivers that have a shutdown hook, then `machine_restart` -> `_soft_restart(tramp)` -> `cpu_v7_reset` with the MMU off.
6. The trampoline (MMU off): gather the zImage pages to the destination, copy the DTB to a fixed high address, then `r0=0, r1=~0, r2=dtb; bx zImage`.

Caveats:
- No sysrq (`CONFIG_MAGIC_SYSRQ` is off).
- No CPU hotplug: CPU1 stays in `ipi_cpu_stop`'s loop under stock's page tables. First tests boot `nosmp`.
- The test DTB reserves stock's CMA `0x27e00000-0x27ffffff`, against stray DMA.
- **A watchdog reset has never been seen on this box (T1).** It's the first step of the first real test.
- This only proves drivers, because stock has already set up padmux, clocks and PHYs. A boot through U-Boot is a separate, later step.
- **Rehearse first** under QEMU: 4.9 `v4.9.84-vanilla`, Thumb-2, SMP, gcc 8.2, 2 CPUs, the whole mechanism end to end.

## Unverified
- What causes the 196-byte layout difference after `ms_sdmmc_probe`.
- Whether the sdmmc `.rodata` tables (clock and pad) match. The matcher only compared code.

## Loader rehearsal in QEMU: PASS (2026-11-24)
- Setup:
  - "stock" = `slop/v4.9.84-vanilla` + the vendor's `__ret_fast_syscall` fix (vanilla 4.9.84 Thumb-2 breaks with binutils >= 2.29, and the vendor tree carries the fix).
  - Built with Arm GNU 8.2, Thumb-2, SMP, no DEBUG_RODATA (like stock).
  - `qemu-system-arm -M vexpress-a15 -smp 2 -m 128M`. Script: `sim/rehearse.sh`.
- Result:
  - `r26kexec` (sim build: `NO_WDT`, vexpress addresses) -> `reboot(2)` -> `device_shutdown` -> `machine_restart` -> patched `arm_pm_restart = _soft_restart` -> MMU off -> trampoline gathers 918 + 4 pages -> **payload kernel boots**: cmdline `R26KEXEC_PAYLOAD_OK`, 128 MiB, runs to "VFS: Unable to mount root" (expected, no rootfs).
  - The payload can't wake CPU1 (`failed to boot: -38`, parked in stage 1's `ipi_cpu_stop`) and carries on with 1 CPU.
- Bugs it caught and fixed:
  - `params` was `.globl`, so `adr` was left unrelocated in the flat binary. Now `.Lparams`.
  - 32-bit `off_t` broke `/dev/mem` above 2 GiB. Now `_FILE_OFFSET_BITS 64`.
  - (sim only) the payload DTB still had vexpress' 1 GiB `/memory`.

## T1: watchdog reset from stock: PASS (2026-11-24)
- `r26kexec --arm-wdt-only 120` at 11:39:25 KST (vendor driver unbound, period `0x55d4a800` = 120 s x 12 MHz, written H then L).
- Down at 11:41:32, back on SSH at 11:41:51, same IP. roonbridge and ssh active, no failed units.
- After the reset: `0x1F006008` = `0901` (bit0, the WDT-reset flag, now set; it was `0900` after the cold and soft boots), and the period regs `0x1F006010/14` read 0 (the reset cleared them).
- PM POR reg1 bit0 stays 1. A WDT reset doesn't clear it; only power-on does.
- IPL and U-Boot boot normally after a watchdog reset. **The hard-deadline recovery path works on real hardware.**

## Rehearsal 2 (different payload): PASS
- The payload is mainline 7.3.6 vexpress (VMSPLIT_3G, like the R26 config) with `/memory` starting at `0x80800000`, above stage 1's image.
- It boots fully through the loader. CPU1 is still in stage 1's `ipi_cpu_stop` afterwards, so protecting stock's region keeps CPU1 harmless.
- Pitfalls found:
  - `linux,usable-memory-range` kills 7.3 ARM silently. Use a shifted `/memory` instead.
  - VMSPLIT_2G + shifted base breaks (idmap vs linear map), so it's sim-only.
- R26 test DTB: `/memory = <0x20400000 0x07a00000>`, bootargs `nosmp`, static `ip=192.0.2.46`, netconsole to Gorakubu `:6666`.

## Run 1: first mainline boot on the R26 (2026-11-24 11:45 KST): PASS
- Launched 11:45:04 via `setsid sh /tmp/r26go.sh 180` (dry run -> arm WDT -> `ip link set eth0 down` -> r26kexec).
- **7.3.6 answered SSH at 11:45:16.** Userspace at 4.55 s. Back on stock by watchdog at 11:48:29, roonbridge active.
- Netconsole delivered 284 lines to Gorakubu. Logs: `re/run1/` (`session1.txt`, `udp-*.log`).
- **Working:**
  - macb EMAC + msc313e PHY (100/Full, static IP, SSH);
  - USB PHY (`usbphy2`, calibration) + FUSBH200 EHCI `uhc2@285000` -> XMOS `20b1:3033` -> snd-usb-audio card `G20`;
  - clkgen / sc_gp muxes, pinctrl, RTC;
  - memory exactly `[0x20400000, 0x27dfffff]`, with stock CMA reserved no-map.
- **Bugs:**
  1. The XMOS enumerates at **full speed** (stock: high speed). The HS chirp fails in the USB PHY or EHCI path. Blocks hi-res UAC2.
  2. **No ttyS0.** chenxing's dtsi uses `mstar,msc313-uart` (needs the 8250_dw quirk I left out).
- **Not in this kernel:** SD (the new driver isn't written yet). The test never touched the card.

## Runs 2-8 (2026-11-24 11:58-12:24): USB high speed FIXED; the "hangs" were dropbear
- **USB high speed root cause:** SigmaStar patches `drivers/usb/core/hub.c` (`_USB_HS_CHIRP_PATCH`) around every root port reset:
  1. before the reset: eye `0x2C..0x2F = 10/00/00/00` and UTMI `0x2A = 0x80` (chirp K detect 400 mV);
  2. at the first status poll: `0x2A = 0x62`;
  3. after the reset: eye `10/02/00/81`.
  - Ported as `ehci->port_reset_hook` (BEGIN/PROGRESS/END) in `ehci-hub.c` plus `ssd20xd_port_reset_hook` in `ehci-fotg210.c`.
  - Also ported: the vendor `Titania3_series_start_ehc` for I2M, byte-exact (preprocessed: `re/usb-start-ehc-i2m.{c,txt}`; matches the Gustard binary), as `sstar,ssd20xd-usb-phy` `phy_init`/`phy_power_on` plus UHC ECO bytes in the glue (`sstar,ssd20xd-ehci`).
  - Result: `usb 1-1: new high-speed USB device`, ALSA `G20 ... high speed`.
- **"Hang" misdiagnosis:** runs 2-6 looked like hangs (an SSH banner timeout after one good connection). A UDP heartbeat (run 7) showed the kernel healthy for 70 s+ with ping working.
  - The real cause: `dropbear -R` generates its host key lazily on first connect, early in boot, which took longer than ssh's 5 s timeout.
  - Fixed with a pre-generated host key in the initramfs (fingerprint `SHA256:Anc5xZYlfadgXcL+MdPeE2MVokAHxArjvNWiBWdJ+8I`).
  - The bisect flag `CONFIG_R26_BISECT_NO_UHC_ECO` is unused again (normal builds keep the ECO writes).
- **Netconsole** goes silent once userspace starts, in every run including run 1. Not yet understood. Init's `nc` pushes (ports 6668/6669) work.
- **Real fix kept from this:** never printk under `bp->lock` in macb xmit (netconsole re-enters through netpoll). Errors are now rate-limited after unlock.
- **Diagnostics left in the test config:** `DEBUG_KERNEL`, `SOFTLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` (not in `config/r26.config`), and the init heartbeat to `:6669`.

## Runs 9-17 (12:28-13:17): SD driver works; Debian 12 boots on mainline 7.3.6
- **New SD driver `drivers/mmc/host/sstar-sdio.c`** (from `re/sdmmc-hw.md`, vendor-exact sequences: ADMA; read = one job, write = cmd job + data job; manual CMD12; R1b via BUSY_DET_ON; R3 CRC quirk; ERR_STS never enabled; `wmb()` = MIU pipe flush on MStar v7).
  - Run 9: SDXC SK64G detected high speed. `/GustardCore` and `/00` sha256 match `stock/SHA256SUMS` through an ro,noload mount.
  - Run 11: the MBR area matches `c85d810c...`. A 32 MiB write+readback at 8 GiB (unallocated) matches, as do 8 single-block 512 B writes. Write 15.5 MB/s, no errors.
- **Config bugs found and fixed (the cause of every silent early death):**
  1. `COMPAT_32BIT_TIME` and `VDSO` off (glibc-2.28 static busybox `clock_gettime` failed).
  2. `CONFIG_EXPERT=y` made allnoconfig switch off every default-y EXPERT option. Above all `ARM_PATCH_PHYS_VIRT` (so `PHYS_OFFSET=0`, an instant death with RAM at `0x20400000`), but also `SND_PCM_TIMER`, `SND_PROC_FS`, `INPUT`, ... Never set EXPERT in the fragment.
  3. The 7.3 symbol names: `SYSCTL` (not `PROC_SYSCTL`), `COREDUMP` (for `ELF_CORE`); `BASE_FULL` is gone.
  - Test-only options now live in `config/r26-test.config`, merged by `build-test.sh`.
- **Netconsole blind spot fixed:** it died at "unable to open an initial console" because there was no ttyS0. The R26 DTS now puts `pm_uart` on `ns16550a` (mainline binding, pinctrl untouched).
- The WDT dummy reg `0x1F006004` is cleared by a watchdog reset, so it can't hold breadcrumbs.
- The go-script now refuses unless stock is `running|degraded` with uptime >= 60 s (run 10 jumped from a booting stock and died).
- **Run 17: Debian rootfs on mainline** (init `r26root` -> mount rw -> switch_root):
  - systemd `running`, 0 failed units; roonbridge, ssh, networkd, chrony, dphys-swapfile, journald, udevd all active;
  - `/var/swap` on, DAC G20 at 480 Mbps;
  - DHCP got .155, because the IAID differs (`0xcda7926` vs stock `0x6d804853`). Fix at cutover: `[DHCPv4] IAID=0x6d804853` in `eth0.network`.
  - Harmless: `alsactl restore` exit 99, modules-load f/g_taudio2 missing, RTC not set (chrony steps the clock).
