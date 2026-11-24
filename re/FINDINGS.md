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
- IAID pin applied on the card (2026-11-24): `[DHCPv4] IAID=1837123667` (= `0x6d804853`) appended to `/etc/systemd/network/eth0.network`, original kept as `/root/eth0.network.orig`. Stock still gets .46 with it.

## SPI NAND dump (2026-11-24, read-only, `re/tools/spinand-dump`)
- FSP PIO with opcode `0x03` works as the recipe in `re/spinand-read.md` describes (go/no-go passed on the first try). Only `9F`, `0F A0/B0/C0`, `13`, `03` were ever sent. Watchdog armed for 30 s and re-armed per page during the dump, disarmed after (period regs read back 0, no reset).
- Chip ID `cd eb 11`. Features `a0=00 b0=18 c0=00`. 2048 + 64 byte pages, 64 pages/block, 1024 blocks = 128 MiB, one plane. 0 corrected, 0 uncorrectable pages, no bad-block marks.
- The CIS in block 0 carries a template ID (`c2 12`, not the live one). Page 1 (PNI) is erased, so there is no partition table.
- Layout: block 0 CIS, block 10 `IPL_`, block 16 `IPLC`, blocks 22-1023 UBI (VID hdr 0x800, data 0x1000). One UBI volume, `uboot` (static, 4 LEBs): uImage "U-Boot 2022.07-rc2+ for som2d01", built 2022-06-01, load/entry `0x20001000`. No env volume and no CRC-valid env anywhere, so U-Boot runs on its built-in env:
  - `bootcmd=gpio clear 52; mmc dev 0; ext4load mmc 0:1 ${stage1} ${core}; ext4load mmc 0:1 ${stage2} ${ver}; bootz ${stage1} - ${stage2}`
  - `stage1=0x22000000`, `stage2=0x22800000`, `core=GustardCore`, `ver=00`, `bootargs=panic=3 rootwait root=/dev/mmcblk0p1 rw clk_ignore_unused`
  - So `/GustardCore` may be at most 8 MiB (the `/00` load lands at +8 MiB).
- Files (mode 600 in `re/spinand/`, never publish: they hold the vendor IPL and U-Boot): `nand-oob.bin` (main+spare, 138412032 B), `nand-main.bin`, `ubi/uboot.bin`, `SHA256SUMS`. Blocks 0-127 were read twice, identical.

## Runs 18-21 (13:40-14:03): the boot shim, and a cache bug in the loader
- `shim/shim.S` + `shim/mkshim.py`: one image (shim | stock zImage | mainline zImage | DTB) that goes in place of `/GustardCore`. It reads PM POR reg1 bit0 (stock soft reboot) and WDT reg2 bit0 (watchdog reset), clears both, and picks: mode 0 stock always; mode 1 mainline only after a stock soft reboot without a watchdog reset; mode 2 mainline unless the watchdog fired. Before mainline it arms the watchdog and copies the DTB to `0x27000000`. QEMU-tested both ways (RAM-backed flag registers, through r26kexec).
- Run 18 (shim through r26kexec, DTB copied to `0x27000000`): no output, watchdog back to stock. POR bit0 read 0 afterwards (was 1, a WDT reset doesn't clear it), so the shim ran and consumed the flags.
- Run 19 (same, DTB to `0x21f00000`, inside the loader's copy window): boots.
- Stock keeps mapped file pages at `0x27000000` (`/proc/kpageflags`). Cause: the copies run with the caches off, while CPU1 is parked by the stock kernel with its caches on and can still hold lines for the destination; the next kernel reads it with caches on. Not observed directly, but the fix below is the only change between run 18 and run 20.
- Fix: invalidate the destination by MVA (DCIMVAC, broadcast) before and after every uncached copy, in the shim's DTB copy and in the trampoline's page copy (now 228 bytes). Run 20 (shim fix only, DTB at `0x27000000`): boots. Run 21 (trampoline fix too): boots, DAC at high speed, init ready at 7.6 s.
- LLVM's assembler leaves every `bl` as an `R_ARM_CALL` relocation, even to a `.L` label, so both flat binaries are now linked with `ld.lld` before `objcopy`.
- Not tested on hardware: the shim's stock branch (a plain jump, QEMU only) and the real U-Boot path. A failure there would not self-recover (nothing arms the watchdog before the shim decides), so installing it on the card waits for Noa.

## Runs 22-30 (14:32-15:23): production kernel, cold boot through the stock U-Boot, shim removed
- Mainline already had a restart path: the DT's `syscon-reboot` (PM sleep reg `0xb8` = `0x79`, priority 192), the same soft reset the vendor uses. A soft reset does not set POR bit0, so with the shim in mode 1 a mainline reboot lands on stock.
- Watchdog: the shim arms it; `msc313e_wdt` sees it running (`WDOG_HW_RUNNING`), re-arms 30 s and the kernel feeds it for `CONFIG_WATCHDOG_OPEN_TIMEOUT=120` s (needs `WATCHDOG_HANDLE_BOOT_ENABLED=y`, which allnoconfig turns off). Run 22: without a userspace takeover the box reset exactly at the open deadline (the core times its last ping for that). Run 23: `systemd.watchdog_sec=30` (systemd 252) takes it over; it stays up. The driver now keeps the watchdog running through a restart (stops it only for halt/poweroff).
- U-Boot installs, in order: shim mode 0 (U-Boot accepts the image; POR bit0 consumed, stock boots), shim mode 1 (stock reboot -> mainline). The first mode-1 boot died silently and the watchdog sent it back to stock. With the shim installed the second boot consumes the WDT flag, so the flag can't tell a watchdog reset from a soft one any more; only timing can.
- Breadcrumbs that survive a reset: the upper bits of PM POR reg1 (`0x1F000C04`; only a power-on clears that bank; verified with a WDT reset through the shim). The test kernel counts initcalls there (`re/tools/initcall-at.py` names the n-th one) and adds probe points.
- Cause (run 26, 28): `ehci_fotg210` read the UHC capability register in probe, before the USBC took the UHC out of reset and enabled its XIU path (phy_init, the vendor order). From a cold boot that access stalls the bus. Started from a running stock kernel the bring-up was already done, which hid it. Fixed by mapping the operational registers after phy_init (run 29: boots).
- Also found: the plain 16550 driver on uart0 left the DW APB UART's busy-detect interrupt asserted ("irq 31: nobody cared" on every shutdown, ~50 s shutdowns). uart0 now uses `snps,dw-apb-uart` (8250_dw); shutdown takes 3 s.
- Run 30 (production shim, mode 1) and then plain mainline: both cores, cpufreq-dt at a fixed 1 GHz (as stock), 128 MiB, DAC at high speed, roonbridge/ssh/networkd/chrony/swap active, no failed units.
- Playback on mainline through RoonBridge (driven via the DMS Roon plugin): `hw:CARD=G20`, S32_LE, 2 ch, 44100 Hz for a 44.1 kHz track, async with feedback.
- U-Boot only changes `/chosen/bootargs` (its env) and `/memory` (`0x20000000 0x8000000`) in the DTB it loads, both identical to the mainline DTB, so the shim was taken out: `/GustardCore` + `/00` are now the plain mainline kernel and DTB (15:22). The stock pair is on the card as `/GustardCore.stock` and `/00.stock`; going back is copying those two over and rebooting, from mainline itself or through the card reader.

## Runs 31-44 (17:45-23:25): Alpine, a reboot hang, nowayout, the TX corruption, parity, cutover
- Alpine 3.24.4 (armv7, `alpine/build.sh`) on the card's p2, booted through the shim in mode 2 with the production kernel in the fallback slot. First boot: all services, 13 MB RAM in use (Debian 40, stock 67), the Core reconnected after 19 s, 96 kHz playback.
- **18:12, the first `reboot` from Alpine hung and the box stayed down until a power cycle.** Alpine's watchdog feeder (BusyBox `watchdog`) does a magic close when OpenRC stops it, and `msc313e_wdt` never called `watchdog_set_nowayout()`, so `CONFIG_WATCHDOG_NOWAYOUT` would have done nothing: the hardware watchdog was off for the rest of the shutdown. Debian never hit this because systemd keeps the watchdog armed through a reboot.
- Fix: the driver honours `nowayout` (default `CONFIG_WATCHDOG_NOWAYOUT=y`). Proven on the box: `rc-service hw-watchdog stop` -> "nowayout prevents watchdog being stopped!" -> reset exactly 30 s later -> the shim booted the fallback (Debian).
- The hang itself did not come back: 12 more OpenRC reboots from Alpine (6 in a row on one kernel, then one into each later test kernel and the cutover) and a `reboot -f` all came back in 33-40 s. Netconsole shows the shutdown down to `device_shutdown` (5 s from `reboot` to reset). The cause is unknown; any repeat now ends in a watchdog reset.
- Getting off a kernel without nowayout safely: `kill -STOP` the feeder (the fd stays open, no magic close) and `reboot -f`.
- Alpine's `dmesg` service sets the console loglevel to 1, which also mutes netconsole after init. `dmesg -n 8` before a test.
- In the shim's main slot use `panic=0`: with `panic=3` a panic soft-resets, the shim sees no watchdog flag and boots the same slot again.
- **The MAC was never stable.** U-Boot makes up a random one at every power-on ("using random MAC address" in its strings) and leaves it in the address registers; soft reboots kept it, a cold boot changed `00:00:5e:00:53:01` to `00:00:5e:00:53:02`. The earlier unique-ID patch never fired because it only ran when macb had no valid address. Now the EMAC derives `00:00:5e:00:53:03` from the SoC's 48-bit unique ID (eFuse regs 0x16-0x18) whenever the DT links it to the eFuse bank.
- DHCP: ifupdown-ng runs `udhcpc -R`, which releases the lease at shutdown, and the router then allocates by MAC. With the random MAC the address moved (.46 -> .39); with the UID MAC it settles on 192.0.2.60.
- **TX corruption found and fixed.** Baseline on the old TX code: 300 MiB of random data from the R26 over raw TCP gave +14,814 `TcpInCsumErrors` at the receiver (about 7% of the segments; TCP drops them, the rest are the SSH MAC failures). The completion path took free FIFO slots for finished frames and freed buffers the MAC was still reading. Rewritten after the vendor driver (127-entry TX queue, software room accounting, TAR/TCR through the X32 bank, reclaim from FIFO-used + latched new-queue count, 64-byte aligned or bounce-buffered frames): 3 x 300 MiB TX, 200 MiB over SSH and 300 MiB RX, all with matching sha256 and 0 checksum errors on either side. TX runs at 8.3 MB/s (9.4 before, with the corruption). The statistics counters are read through the X32 bank too and no longer jump in 0x10000 steps.
- Parity reads (`re/tools/r26peek`, read-only, DEVMEM test kernel):

| What | Register | Value | Verdict |
|---|---|---|---|
| UART1_MODE / DMIC_MODE_4 / TEST_IN-OUT (VID pad muxes) | `0x1F203C0C`, `0x1F203C3C`, `0x1F203C48` | 0, 0, 0 | no function on the VID pads |
| `reg_all_pad_in` | `0x1F203D40` | 0 | clear |
| pad 49 (VID bit 0) | `0x1F207868` | `0x0011` | output, high |
| SAR AISEL/OEN, OUT/IN (pad 72, VID bit 1) | `0x1F002844`, `0x1F002848` | `0x3d3d`, `0x0d00` | digital output, low: 900 mV |
| pad GPIO12 | `0x1F207830` | 0 | output, low, as U-Boot leaves it |
| pad TTL0 (SD power in the reference design) | `0x1F207880` | `0x0020` | input, nobody drives it |
| SAR clock gate | `0x1F001C88` bit 5 | 0 | running |
| L3 bridge flush | `0x1F204414` | `0x0001` | bit 4 (AXI exclusive) clear, the vendor sets it |

- Reading the HDMI/DAC ATOP, display LPLL, MIPI D-PHY and SATA banks (`0x1F224C00`, `0x1F224E00`, `0x1F206600`, `0x1F2A5000`, `0x1F2A4A00-4E00`) stalls the bus on mainline; the watchdog reset the box into the fallback. So the vendor's analog power-down of those blocks is not ported: the banks are not even readable here.
- Ported: AXI exclusive access on and the MIU pipe flush under a spinlock (all Infinity vendor kernels do both), the SAR GPIO driver holds the SAR clock, a hog keeps GPIO12 (amp-gpio) low. After: L3 bridge `0x0011`, `sar` clock enable count 1, GPIO12 still low, 0 checksum errors over 300 MiB, playback at 96 kHz.
- **Cutover (23:22): plain U-Boot -> mainline -> Alpine, no shim.** U-Boot forces `root=/dev/mmcblk0p1 rw`; the Alpine kernel (`config/r26-alpine.config`) appends `root=PARTUUID=d13d0903-02 ro` through `CMDLINE_EXTEND`, and the last `root=`/`ro` win. Card p1: `/GustardCore` + `/00` (production), `/GustardCore.debian` (the same kernel with the base command line, boots Debian on p1), `/00.prev`, `/GustardCore.stock` + `/00.stock` (match `stock/SHA256SUMS`), `/GustardCore.prod` (an older mainline build, no local copy). Rebooted twice: back in 34-36 s, the Core connected 11 s after boot.
