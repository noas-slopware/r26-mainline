# SSD202D (Infinity2M) SPI NAND read-only recipe via FSP over /dev/mem

Read-only. Allowed opcodes only: 0x9F, 0x0F, 0x13, 0x03 (or 0x0B). Never 0xFF, 0x06, 0x04, 0x1F, 0x02/0x32/0x10/0x84, 0xD8, 0xC2.

Abbreviations (paths are relative to the RE workspace, which held the vendor sources):
- `UB` = `uboot-vendor/drivers/mstar/spinand`
- `UBH` = `UB/hal/common/drvSPINAND_common_hal.c` (shared HAL, used by infinity2m)
- `UBI2M` = `UB/hal/infinity2m/drvSPINAND_hal.c`
- `UBR` = `UB/inc/config/drvSPINAND_reg.h`
- `VK` = `vendor-tky/drivers/sstar/spinand`
- `CHX` = `git show chenxing/mstar_v6_7_rebase:...` in `linux/`

Everything below is from source only. Nothing was run on the device. Items I could not confirm are in section 5.

---

## 1. Which block, where, and every register

### 1.1 Block

The SPI NAND commands go through the **FSP** ("flash serial port"/"FSP command engine") block in the PM domain, one trigger = one complete SPI transaction (CS low, up to 10 write bytes out, up to 10 bytes in, CS high). The QSPI block (next bank) is the memory-mapped/XIU fast-read engine and BDMA reads through it. Neither "BDMA" nor "ISP" is needed for commands. Command traffic never uses QSPI/BDMA (UBH:118-150, 152-169, 658-697).

Vendor evidence that it is the same on I2M: U-Boot HAL base table UBH:70-81 (FSP = `RIU_PM_BASE + BK_FSP`), values in `UB/inc/config/infinity2m/drvSPINAND_uboot.h:49-64` (`RIU_PM_BASE 0x1F000000`, `RIU_BASE 0x1F200000`, `BK_FSP 0x2C00`, `BK_QSPI 0x2E00`, `BK_PMSLP 0x1C00`, `BK_CLK0 0x1600`, `BK_BDMA 0x0400`, `BK_CHIP 0x3C00`, `BK_CLKGEN 0x7000`, `BK_ISP 0x1000`). The kernel driver uses the same offsets and the same register file (`VK/hal/infinity2m/reg_spinand.h:40-51,93-126`; `VK/hal/mhal_spinand.c:64-73`, virt `0xFD000000` = phys `0x1F000000`).

Cross-check from linux-chenxing (independent): `CHX arch/arm/boot/dts/sigmastar/mstar-v7.dtsi:260-268` gives `isp@1f001000` with reg `0x1f001000` (ISP), `0x1f002c00` (FSP), `0x1f002e00` (QSPI), `0x14000000` (XIP window). `CHX drivers/spi/spi-msc313-isp.c:72-77` uses QSPI regs at byte offsets `0x1c0/0x1c8/0x1f4` = reg `0x70/0x72/0x7D` on a 4-byte stride, identical to the vendor `REG_SPI_CKG_SPI 0x70`, `REG_SPI_MODE_SEL 0x72`, `REG_SPI_FUNC_SET 0x7D` (UBR:120,125,134). That confirms the 4-byte stride and the base addresses.

Bank-number arithmetic: vendor `BK_*` are already byte offsets (bank_id << 1). FSP bank_id 0x1600 -> 0x2C00; QSPI 0x1700 -> 0x2E00; PM-sleep 0x0E00 -> 0x1C00 (`PMSLEEP_BANK 0x000E00` in `vendor-tky/drivers/sstar/gpio/infinity2m/pmsleep_reg.h:20`); non-PM bank 0x1E00 (chiptop) -> 0x3C00 off `0x1F200000`.

### 1.2 Physical addresses

All registers are 16 bit, at a 4-byte stride: `phys = bank_base + reg*4`. Use only 16-bit (halfword) loads/stores. The vendor does byte stores into the write buffer (UBH:126), but a 16-bit write of two bytes is also vendor-proven (UBH:604, `FSP_WRITE(REG_FSP_WRITE_BUFF, GF | STAT<<8)`), so use halfwords everywhere and avoid unaligned byte tricks.

| Block | base (phys) | page to mmap (4 KiB) |
|---|---|---|
| FSP | 0x1F002C00 | 0x1F002000 (also holds QSPI at 0x1F002E00) |
| QSPI | 0x1F002E00 | 0x1F002000 |
| PM-sleep | 0x1F001C00 | 0x1F001000 |
| CHIPTOP (non-PM) | 0x1F203C00 | 0x1F203000 |
| BDMA (only if DMA) | 0x1F200400 | 0x1F200000 |
| CLKGEN (only if DMA) | 0x1F207000 | 0x1F207000 |

`/dev/mem` mmap of RIU already works on this stock kernel: `re/FINDINGS.md:42-45` (the `riuread` tool, read-only mmap, read `0x1F000C04`, `0x1F006008`, `0x1F0071C0`). Use `O_SYNC` (uncached).

FSP registers (offsets in `UBR:56-97`, the `*2` in the macros is because the HAL indexes a `U16*`, so byte offset is reg*4; proven by the accessors UBH:126-149):

| Name | reg | phys | meaning / values | cite |
|---|---|---|---|---|
| WRITE_BUFF | 0x60..0x64 | 0x1F002D80..0x1F002D90 | bytes 0..9 of the outgoing frame. byte k lives in reg `0x60 + k/2`, low byte = even k, high byte = odd k | UBR:56, UBH:126 |
| WRITE_BUFF2 | 0x70..0x74 | 0x1F002DC0.. | bytes 10..19 (continuation, only used for writes) | UBR:81-82 |
| READ_BUFF | 0x65..0x69 | 0x1F002D94..0x1F002DA4 | up to **10** incoming bytes, byte j in reg `0x65 + j/2`, low byte = even j | UBR:69, 97 (`MAX_READ_BUF_CNT 10`), UBH:171-179 |
| WRITE_SIZE | 0x6A | 0x1F002DA8 | number of bytes to send (cmd+addr+dummy), single-command mode: plain count | UBR:70, UBH:228,194 |
| READ_SIZE | 0x6B | 0x1F002DAC | number of bytes to receive, 0..10 | UBR:71, UBH:230 |
| CTRL | 0x6C | 0x1F002DB0 | `0x0007` = ENABLE(1) \| RESET(2) \| INT(4). Bits 15/14 (`ENABLE_SEC_CMD 0x8000`, `ENABLE_THR_CMD 0x4000`) chain 2nd/3rd command with per-command size nibbles. Not needed, keep them 0 | UBR:72, 99-104; UBH:220 |
| TRIGGER | 0x6D | 0x1F002DB4 | write 1 to start | UBR:73-74 |
| DONE | 0x6E | 0x1F002DB8 | bit0 = done, bit1 = auto-check error (unused) | UBR:75-78 |
| CLEAR_DONE | 0x6F | 0x1F002DBC | write 1 to clear done | UBR:79-80 |
| CTRL2 | 0x75 | 0x1F002DD4 | bit0 = quad. Write 0 | UBR:83-85 |
| CTRL4 | 0x76 | 0x1F002DD8 | write 0 | UBR:86 |

Chip-select: by default FSP asserts CS for one trigger and deasserts at the end. A CS-hold mechanism does exist: QSPI reg 0x0A (`REG_SPI_BURST_WRITE`, bit0 `ENABLE_BURST`, bit1 `DISABLE_BURST`, `UBR:114-116`, phys `0x1F002E28`) is set to ENABLE between FSP triggers of a program sequence and to DISABLE at the end (`UBH:964,973`; quad path `UBH:810,829,874`). The vendor uses it only on the program path, it is unproven for reads, and enabling it needs a QSPI write. The recipe therefore does not use it: long reads are a series of independent `0x03` commands with an advancing column (the vendor's own PIO design, UBH:398-457). One consequence: if a previous program path timed out with burst left enabled (`UBH:959-963` returns before the disable at 973), every later FSP command would be corrupted, so the tool must check `QSPI[0x0A]` bit0 == 0 first (3.3). Pad mux/CS select registers: section 3.

Clock/mode: FSP runs on the PM SPI clock, `PM_REG[0x20]` (phys 0x1F001C80): bits [13:10] select the rate (0 = xtal 12 MHz ... 7 = 108 MHz). Bit 14 is a deglitch mux, not a gate: `SWITCH_OFF` = "run @ 12M", `SWITCH_ON` = "run @ ckg_spi" (`UBR:37-50`, comments at `UBH:1467-1470,1490-1493`, dump logic `UBI2M:108-136`). Bit 14 = 0 is therefore a normal, working state (the clock is only reprogrammed by the `nand clk` command, not at init, 3.1). Log the register, never write it. Single lane, SPI mode defaults of the engine. Nothing to program for PIO reads.

---

## 2. Register-level sequences

Notation: `W(reg,val)` = 16-bit store to `0x1F002C00 + reg*4`, `R(reg)` = 16-bit load. All sequences use the helper below.

### 2.0 Helper `fsp_xfer(tx[0..wn-1], wn <= 10, rn <= 10) -> rx[0..rn-1]`

This is the sequence every vendor function repeats: UBH:219-245 (U-Boot `_HAL_FSP_SendOneCmd`), UBH:1588-1621 (`HAL_SPINAND_ReadStatusRegister`), UBH:1272-1319 (`ReadID`), kernel `VK/hal/mhal_spinand.c:187-269`.

0. If `R(0x6E) & 1` (stale done): `W(0x6F,1)`. (Not in vendor; cheap guard.)
1. `W(0x6C, 0x0007)`
2. `W(0x75, 0)` ; `W(0x76, 0)`
3. for i in 0..ceil(wn/2)-1: `W(0x60+i, tx[2i] | (tx[2i+1] << 8))` (pad the odd tail with 0)
4. `W(0x6A, wn)` ; `W(0x6B, rn)`
5. `W(0x6D, 1)`
6. Poll `R(0x6E) & 1` until set. Vendor loops 60000 reads with no delay (`UBR:53`, UBH:152-169) or 20000 reads with `udelay(1)` (kernel `VK/hal/infinity2m/reg_spinand.h:90`, `VK/hal/mhal_spinand.c:187-207`). A 14-byte frame at 12 MHz is about 10 us. Sensible: spin up to 2 ms total; on timeout abort the whole dump (do not retry-blast).
7. for j in 0..rn-1: `rx[j] = (R(0x65 + j/2) >> (8*(j&1))) & 0xFF`
8. `W(0x6F, 1)`

Do this in exactly this order. Read-then-clear is the U-Boot order (UBH:446-449, 1312-1315, 1615-1618). The kernel's status helper clears first and also works (`VK/hal/mhal_spinand.c:237-266`; U-Boot `HAL_FSP_GET_SPINAND_STATUS` does too, UBH:615-617).

### 2.a Read JEDEC ID (0x9F)

`tx = {0x9F, 0x00}`, `wn = 2`, `rn = 3` (UBH:1283-1287, 1289-1316; SPINAND_ID_SIZE = 3, `UB/inc/common/drvSPINAND.h:144`).
Result: `rx[0]` = MID, `rx[1]` = DID, `rx[2]` = third byte. The 0x00 is the dummy byte that SPI NAND needs after 0x9F. Vendor rule for the third byte: if `rx[2] == rx[0] || rx[2] == 0xFF || rx[2] == 0x7F` treat the ID as 2 bytes, else 3 bytes (`UB/drvSPINAND.c:148-160`). Known MIDs: GD 0xC8, Micron 0x2C, ATO 0x9B, Winbond 0xEF, MXIC 0xC2, Toshiba 0x98, XTX 0x0B (`UB/inc/common/drvSPINAND.h:30-36`).
Abort if MID is 0x00 or 0xFF (nothing answering).

### 2.b Get feature (0x0F)

`tx = {0x0F, addr}`, `wn = 2`, `rn = 1` (UBH:1588-1621, 597-619). `addr`: 0xA0 protection, 0xB0 config, 0xC0 status (`UB/inc/common/drvSPINAND.h:162-176`).
Result `rx[0]` is the register.
- 0xC0: bit0 OIP, bit2 E_FAIL, bit3 P_FAIL, bits[6:4] ECC status (`UB/inc/common/drvSPINAND.h:175-183`).
- 0xB0: bit6 `NAND_OTP_EN (0x40)`, bit4 `ECC_ENABLE`, bit0 `QUAD_ENABLE` (`UB/inc/common/drvSPINAND.h:169-173`); other bits are chip specific.

### 2.c Page read to cache (0x13) then poll OIP

1. `fsp_xfer({0x13, row>>16, row>>8, row}, 4, 0)`. This is the vendor's `HAL_SPINAND_RFC` first half: WRITE_SIZE = 4, READ_SIZE = 0 (UBH:658-697, bytes 0x13 then 3 address bytes MSB first, `SPI_NAND_ADDR_LEN 3`). `row` = page index = `block * BlkPageCnt + page_in_block` (UB/drvSPINAND.c:316).
2. Poll status: repeat `fsp_xfer({0x0F, 0xC0}, 2, 1)` until `rx[0] & 0x01 == 0`. Vendor: UBH:181-215 (each iteration re-writes CTRL/BUF/SIZES, triggers, waits, clears; `udelay(1)` between, max 60000 iterations). Use a 20 ms overall timeout (page read is typically 25 to 120 us). On timeout abort.
3. `ecc = rx[0] & 0x70`. Vendor classification (`UB/drvSPINAND.c:351-360`, `UB/inc/common/drvSPINAND.h:177-181`): 0x00 clean, 0x10 1-3 bits corrected, 0x20 uncorrectable, 0x30 4-6 corrected, 0x50 7-8 corrected. Vendor compares the whole status byte for equality, so P_FAIL/E_FAIL bits would hide a match. Mask with 0x70 and also log the raw byte.

The kernel merges 0x13 and 0x0F into one FSP trigger using `ENABLE_SEC_CMD` and size nibbles (`VK/hal/mhal_spinand.c:601-648`: CTRL `0x8007`, WRITE_SIZE `0x024`, READ_SIZE `0x010`). Do **not** use that. The U-Boot variant is the plain two-trigger form above and does not need the chained-command bits.

Multi-plane / big-block caveats are in 2.d and section 5.

### 2.d Read from cache (0x03 + col16 + dummy), main + spare

The FSP read buffer holds 10 bytes, so a long read = N independent commands. This is what the vendor's RIU path does (`_HAL_SPINAND_RIU_READ`, UBH:398-457; kernel copy `VK/hal/mhal_spinand.c:301-355`):

```
total = PageByteCnt + SpareByteCnt            # e.g. 2048 + 64 = 2112
col0  = ((PlaneCnt != 0 && (block & 1)) ? 0x1000 : 0)    # plane bit, see below
for off in range(0, total, 10):
    n   = min(10, total - off)
    col = col0 | off                           # off < 0x1000 so no overlap
    fsp_xfer({0x03, col >> 8, col & 0xFF, 0x00}, 4, n)  # tx[3] = dummy byte
    append rx[0..n-1]
```

Details that matter:
- `WRITE_SIZE = 4` = command + 2 column bytes + 1 dummy byte (UBH:416, 425-433, `SPI_NAND_PAGE_ADDR_LEN 2`).
- The column is a 16-bit big-endian value (`UBH:425-430`). Main area is `col 0 .. PageByteCnt-1`, spare is `col PageByteCnt ..` (UB/drvSPINAND.c:336, 347). Reading straight through is fine and gives spare without a second page read. The vendor splits it into two calls only because it keeps buffers separate.
- Plane bit (bit 12 of the column) on 2-plane parts (Micron, some MXIC): vendor sets `u16ColumnAddr = 1<<12` when `u8PlaneCnt != 0` and the block index (`page / BlkPageCnt`) is odd (UB/drvSPINAND.c:327-331; write side UBH:1176-1179). `PlaneCnt` comes from the SNI (section 4.1). Without it, odd blocks read the wrong plane on those chips.
- `0x0B` alternative: same frame layout (cmd, col16, 1 dummy byte). This is what the vendor's fast path actually emits when it goes through QSPI/BDMA: `REG_SPI_MODE_SEL = REG_SPI_FAST_READ(1)`, `REG_SPI_FUNC_SET = ADDR2_EN | DUMMY_EN` (2 address bytes + dummy) (UBH:1254-1262; `UBR:125-127,134-138`). The U-Boot/kernel PIO path with `0x03` was dead code in the SDK (`RIU_FLAG FALSE`: `UB/inc/common/drvSPINAND.h:146`, `VK/hal/infinity2m/mhal_spinand.h:58`), so it is unproven on real silicon. If a first test with `0x03` returns garbage but 0x0F works, switch the opcode byte to `0x0B` (same frame). Both are allowed.
- Optimisation after the first validated run: the vendor RIU loop writes CTRL/CTRL2/CTRL4/sizes once (UBH:407-420) and then per chunk only updates the two address bytes, triggers, polls, reads, clears. Per chunk touching only `W(0x60), W(0x61), W(0x6D)`, poll, reads of `0x65..0x69`, `W(0x6F)` cuts MMIO traffic about 3x. Start with the full-reinit form; rough cost ~212 triggers/page, a few ms per page, minutes for a 128 MB part (estimate, unmeasured).
- After the last chunk, the cache content stays valid; do not re-issue `0x13` for the same page.
- The returned data is **on-die-ECC corrected main + spare as the chip exposes them** because the vendor never touches the config register (section 2.e).

### 2.e Does the vendor read path need any set-feature?

No. Checked every writer of `SPI_NAND_CMD_SF (0x1F)` in the HAL (UBH `HAL_SPINAND_WriteStatusRegister` 1623-1655, WriteProtect 1321-1363, OTP 1088-1158, PreHandle 568-596) and its callers:
- CIS read (`UB/drvSPINAND.c:94-172`), normal page read (`UB/drvSPINAND.c:300-363`), and `ReadID` use only `0x9F`, `0x13`, `0x0F C0`, and the 0x0B/BDMA or 0x03/FSP read. No set-feature.
- On-die ECC: `ECC_ENABLE` (`(1<<4)` in `UB/inc/common/drvSPINAND.h:171`) is **defined but never used** anywhere under `uboot-vendor/drivers/mstar` or `common` or the kernel driver. The vendor relies on the chip's power-up default (ECC on for GD/Micron/Winbond etc.). So skipping set-feature gives exactly the same data the vendor sees: ECC-corrected. A raw (ECC-off) read would need `0x1F B0` and is **not allowed here**. If you need to know the state, read 0xB0 bit4 (2.b) and log it.
- Quad: `SUPPORT_SPINAND_QUAD` is forced to `(0)` for the I2M U-Boot (`UB/inc/config/infinity2m/drvSPINAND_uboot.h:33-35`), so `HAL_SPINAND_PreHandle` quad toggling on GD (`UBH:568-596`) and `SetMode` (UBH:1365-1413) never run in the read path. We never touch it.
- Exceptions, init-time only: (1) `HAL_SPINAND_Init` sends **reset 0xFF** (`UBI2M:56-63`), forbidden here, skip it. (2) XTX (MID 0x0B) QE-bit clear at init (`UB/drvSPINAND.c:270-283`, set-feature 0xB0). If the chip is XTX and 0xB0 bit0 reads 1, single-lane reads may misbehave and we cannot fix it. Report only.
- The die-select 0xC2 for Winbond `EF AB 21` (`UB/drvSPINAND.c:307-313`, `UBH:1728-1756`) is forbidden. For that chip only the die selected at handoff is readable (see 5.).

### 2.f Optional: DMA instead of PIO (not recommended)

Only if PIO is far too slow. It needs: the same 2.c page-read + OIP first, then the QSPI engine and BDMA programmed with a physical DRAM buffer. From `UBH:1254-1262, 460-524` and kernel `VK/hal/mhal_spinand.c:361-405`:

1. QSPI (phys 0x1F002E00, reg*4): `W(0x7D, 0x1800)` (ADDR2_EN|DUMMY_EN; the U-Boot SDK additionally ORs `WRAP_EN 0x2000` = `0x3800` for 2-plane parts), `W(0x70, 0x17)` (USER_DUMMY_EN|7 dummy cycles), `W(0x72, 0x01)` (read mode fast read = 0x0B). These are sticky QSPI settings but identical to what U-Boot leaves anyway (U-Boot did the same for its last read), so read them first and write only on mismatch.
2. BDMA (phys 0x1F200400, reg*4): if `R(0)&1`: `W(0,0x10)`, if `R(0)&0x10`: `W(0,0)`. Then `W(0,0)`, `W(2,0x4035)` (src = SPI/QSPI, 8B width; dst = channel0 MIU, 16B width), `W(3,0)`, `W(4, col & 0xFFFF)`, `W(5, col >> 16)` (source address = the **column**, not a flash address), `W(6, dst_miu & 0xFFFF)`, `W(7, dst_miu >> 16)`, `W(8, size & 0xFFFF)`, `W(9, size >> 16)`, `W(0, 1)`, poll `R(1) & 8`, then `W(1, 8)`. `dst_miu` = physical DRAM address minus 0x20000000 (U-Boot masks with 0x1FFFFFFF, `UBH:491`; kernel `Chip_Phys_to_MIU`). Size and dst must be 8-byte aligned (`UB/inc/config/infinity2m/drvSPINAND_uboot.h:30` note). Size at most one page+spare (2112) per transaction: QSPI "address continue" keeps CS low and would keep clocking past the cache end otherwise (`CHX spi-msc313-isp.c:361-387`).
3. Requirements that make it risky here: BDMA clock must be on (stock DT: `spinandflash` clock phandle 0x66 = `CLK_bdma`, reg `0x1F207180`, `stock/00.dts:1052-1063`, `HAL_SPINAND_SetCKG` writes CLKGEN `0x60`, UBH:1480-1482), BDMA channel 0 may be in use by the stock `bdma` driver, and a DRAM buffer that Linux does not own must be found (stock `LX_MEM=0xFE00000`, `stock/00.dts:10`). PIO avoids all three.

---

## 3. Init before first use, and what can be assumed at handoff

### 3.1 What the vendor does

`HAL_SPINAND_Init` for I2M (`UBI2M:46-64`):
1. `CHIP[0x50] = 0x0000` ("disable all pad in"; bit 15 of chiptop reg 0x50 is `reg_all_pad_in`, `vendor-tky/drivers/sstar/emmc/*/eMMC_*_linux.h:159-160`, `vendor-tky/drivers/sstar/emac/hal/infinity2m/mhal_emac.c:1596`). Phys `0x1F203C00 + 0x50*4 = 0x1F203D40`.
2. `QSPI[0x7A] = 0x0000` ("CS use SPI#1"). Phys `0x1F002E00 + 0x7A*4 = 0x1F002FE8`.
3. `PM[0x35] = 0x0008`. Phys `0x1F001C00 + 0x35*4 = 0x1F001CD4`. Bits (`vendor-tky/drivers/sstar/gpio/infinity2m/pmsleep_reg.h:62-68`): bit0 PM_SPI pads-as-GPIO, bit2 CSZ1 gpio, bit3 CSZ2 gpio, bit4 WPN gpio, bits[7:6] HOLDN mode. 0x08 = SPI pads functional, CSZ1 functional, only CSZ2 (the second chip select) released to GPIO.
4. Reset 0xFF + OIP wait (forbidden here).

No clock setup in `HAL_SPINAND_Init`. Clock gating is separate: `HAL_SPINAND_SetCKG` (UBH:1424-1496) is only called from the `nand clk` U-Boot command (`uboot-vendor/common/cmd_nand.c:694`), not at init.

### 3.2 What can be assumed

- The board is booted from this flash: ROM/IPL read it over these same PM_SPI pads, so the pads are in SPI mode and CS1 is the active chip select. U-Boot (vendor SDK) runs `board_nand_init -> MDrv_SPINAND_Init -> HAL_SPINAND_Init` during its own NAND init (`UB/spinand.c:474`, `UB/drvSPINAND.c:188`, `uboot-vendor/common/board_r.c:372-392`) (`initr_nand` calls `nand_init()` unconditionally, board_r.c:372-392; `ms_devinfo_boot_type()` returns `SPINAND_INT_ECC` for the I2M strap, `arch/arm/cpu/armv7/infinity2m/infinity2m.c:196-209`) and U-Boot reads its env from this NAND (`common/env_nand.c:444-480`), so steps 1 to 3 have been executed if U-Boot's NAND init ran, and it also issued a reset 0xFF, so the chip is in power-up default config (ECC on, BUF/continuous per chip default, OTP off, protection default). The stock kernel has no MTD/spinand driver (per the task statement; I did not verify the shipped binary), and even where the vendor driver exists it only probes after the storage-type check (`VK/drv/mdrv_spinand.c:949-951`); the NOR `mtd-flashisp` probe returns early unless storage is NOR (`vendor-tky/drivers/sstar/flash_isp/mtd_serflash.c:479`). So nothing is expected to have touched these registers after U-Boot.
- The FSP command registers are re-initialised by every command (steps 1,2 of the helper), so any stale FSP state from IPL/U-Boot is overwritten. This includes leftover `ENABLE_SEC_CMD` from `HAL_SPINAND_BLOCKERASE` (UBH:1039) or the kernel's chained RFC.

### 3.3 Recommended handling in the tool: verify, do not write

The vendor writes whole registers (`CHIP[0x50]`, `PM[0x35]`) which may hold bits of other, live peripherals (the stock box runs ethernet and SD). Overwriting them from userspace is not necessary and could break them. Instead read:

| check | expect | on mismatch |
|---|---|---|
| `R16(0x1F203D40) & 0x8000` | 0 (all_pad_in off) | stop and report. If you must fix: read-modify-write only bit 15 |
| `R16(0x1F002FE8)` (QSPI 0x7A) | 0 | stop and report |
| `R16(0x1F001CD4) & 0x0005` (bit0, bit2) | 0 | stop and report. Vendor's intent is only these two clear; RMW only those bits. Also log the full value: vendor leaves exactly `0x0008`, and bits 4 and 6-7 (WP#/HOLD# pads) differing from that is worth a warning, not an abort |
| `R16(0x1F002E28) & 0x0001` (QSPI burst-write enable) | 0 (vendor leaves 0x0002) | stop and report; a leftover burst-enable would corrupt FSP commands |
| `R16(0x1F001C80)` (PM SPI clock) | log only | never abort, never write (bit 14 = 0 is a normal state, see 1.2) |

Do not clear/reset anything else. If all four pass, go straight to 2.a.

### 3.4 Sticky changes caused by this recipe

Only FSP registers (CTRL, CTRL2, CTRL4, sizes, write/read buffers, done flag), which every vendor stack re-initialises before use. After a reboot/reset IPL re-inits everything. No QSPI/chiptop/PM/clock bit is written by the PIO path. (DMA option 2.f touches QSPI 0x70/0x72/0x7D, 0x7D differs between U-Boot (`0x3800`) and kernel (`0x1800`) versions, so even those are vendor-agnostic.)

---

## 4. Partition table, geometry, U-Boot env

### 4.1 CIS = geometry ("SNI"), and the partition table ("PNI")

Location: both are stored in the first pages of the **CIS blocks**. Search pattern (U-Boot `board_nand_init`, `UB/spinand.c:469-519`; kernel `VK/drv/mdrv_spinand.c:1002-1036`; writer `UB/drvSPINAND_api.c:78-134`): blocks `0, 2, 4, 6, 8` (`CIS_MAX_BACKUP 5` x stride 2; the default write makes `CIS_DEFAULT_BACKUP 3` copies = blocks 0, 2, 4, `UB/inc/common/spinand.h:78-79`). In each CIS block:
- **page 0** (`row = blk * BlkPageCnt`, bootstrap value `BlkPageCnt = 64` if unknown, `UB/drvSPINAND.c:110`): main bytes 0..511. Bytes 0..15 are the tag `"MSTARSEMIUSFDCIS"` (`u8MagicData`, `UB/drvSPINAND.c:58,137`; `UB/inc/common/spinand.h:137`). Bytes 16.. are `SPINAND_FLASH_INFO_t` (`UB/drvSPINAND.c:143-144`), 0x200 bytes total per entry (`UB/drvSPINAND_api.c:402-430`).
- **page 1**: `PARTITION_INFO_t`, 0x200 bytes (`UB/spinand.c:471,501`, `UB/drvSPINAND_api.c:117-121`).

The vendor's bootstrap read uses `HAL_SPINAND_RFC(row)` then `HAL_SPINAND_Read(col 0, 512)`, and reads the spare from column 2048 (`UB/drvSPINAND.c:122,130`), i.e. it assumes 2048-byte pages for the first read. So read page 0 of block 0 with a 512-byte read first, check the tag, parse the geometry, then use the real page size for everything else.

`SPINAND_FLASH_INFO_t` byte layout, file offset = 16 + this (`UB/inc/common/drvSPINAND.h:67-86`; `BOOL` is `unsigned char`, `UB/inc/MsTypes.h:220`; natural alignment; offsets of the last three confirmed by `uboot-vendor/common/cmd_mstar.c:1278-1282`: `auInfo[0x1e]=UBOOTPBA, [0x1f]=BL0PBA, [0x20]=BL1PBA`):

| off | field |
|---|---|
| 0 | u8 IDByteCnt |
| 1..15 | u8 ID[15] |
| 16 | u16 SpareByteCnt (LE) |
| 18 | u16 PageByteCnt |
| 20 | u16 BlkPageCnt (pages per block) |
| 22 | u16 BlkCnt |
| 24 | u16 SectorByteCnt |
| 26 | u8 PlaneCnt |
| 27 | u8 WrapConfig |
| 28 | u8 bRIURead |
| 29 | u8 CLKConfig |
| 30 | u8 UBOOTPBA |
| 31 | u8 BL0PBA |
| 32 | u8 BL1PBA |
| 33..38 | u8 HashPBA[3][2] |
| 39 | u8 ReadMode |
| 40 | u8 WriteMode |

Worked example from the shipped sample `UB/cis/SPINANDINFO.sni`: `4D5354415253454D4955534644434953 | 02 2C 12 ...` -> IDByteCnt 2, ID `2C 12`, spare 0x40, page 0x800, 64 pages/block, 1024 blocks, sector 0x200, PlaneCnt 2, CLK 0x32. (Checked by hex dump of the file.)

Cross-check: the SNI ID is overwritten with the live `0x9F` read after parse (`UB/drvSPINAND.c:148`), so compare our own 2.a result with `ID[]` in the SNI. A mismatch means the CIS belongs to a different chip variant.

Total size = `BlkCnt * BlkPageCnt * PageByteCnt`. Block size = `BlkPageCnt * PageByteCnt`. Row = `blk * BlkPageCnt + pg`.

If no CIS is found in blocks 0,2,4,6,8, the vendor falls back to its (disabled, `#if 0`) ID table, `UB/drvSPINAND.c:64-84`: GD F4/F1/10/D1/D5/D2, Micron 12/22/32, ATO 12, Winbond AA, MXIC 12/22, Toshiba CB; all 2048+64, 64 pages/block; plane count 2 for Micron and MXIC 22 and Toshiba CB. Treat that table only as a hint.

### 4.2 `PARTITION_INFO_t` (PNI), 0x200 bytes

From `UB/inc/common/spinand.h:88-108` (all little endian):

| off | field |
|---|---|
| 0 | u32 ChkSum |
| 4 | u16 SpareByteCnt |
| 6 | u16 PageByteCnt |
| 8 | u16 BlkPageCnt |
| 10 | u16 BlkCnt |
| 12 | u16 PartCnt |
| 14 | u16 UnitByteCnt |
| 16 + 8*i | record i, i < 62: u16 StartBlk, u16 BlkCnt, u16 PartType, u16 BackupBlkCnt |

Checksum: 32-bit sum of the bytes `[4 .. 0x1FF]` (`UB/drvSPINAND_api.c:136-143, 451`; `UB/spinand.c:502`; kernel `VK/drv/mdrv_spinand.c:619-627,1018`). I verified the six shipped samples in `UB/cis/PARTITION_v2_default.pni` satisfy this (e.g. first record sum 0x116 = stored 0x116).

Partition semantics (`UB/drvSPINAND_api.c:206-380`, kernel `VK/drv/mdrv_spinand.c:629-771`):
- Offset = `StartBlk * BlkPageCnt * PageByteCnt`. Size = `(BlkCnt + BackupBlkCnt) * block_size`.
- `PartType & 0x8000` = logical (wear-leveled), `& 0x4000` = hidden (skipped in the mtd list), `& 0x0FFF` = type. A type exactly `0xC000` as the last record means "UBI to end of flash" (`UB/inc/common/spinand.h:74`).
- Types (`UB/inc/common/spinand.h:44-70`): 1 IPL_CUST, 2 BOOTLOGO, 3 IPL, 4 OS, 5 CUS, 6 UBOOT, 7 SECINFO, 8 OTP, 9 RECOVERY, 0xA E2PBAK, 0xB NVRAMBAK, 0xC NPT, 0xD ENV, 0xE MISC, 0xF rootfs, 0x10 RTOS, 0x11 RTOS_BAK, 0x12 KERNEL, 0x13 KERNEL_BAK, 0x20 CIS, 0x21 UBI, 0x30..0x3F CUSTn.
- Sample (`UB/cis/PARTITION_v2_default.pni`, 1st table): 2 records, `{start 0x0A, cnt 0x25, type 6 (UBOOT), backup 3}`, `{start 0x32, cnt 0x0E, type 2 (BOOTLOGO), backup 2}`. This is only the SDK default, **not** this device's table.
- The stock DT default bootargs carry `ubi.mtd=9` (`stock/00.dts:10`; the live test boot instead uses `root=/dev/mmcblk0p1`, `stock/live/dump.txt`, and `re/FINDINGS.md:47-49` says U-Boot loads `/GustardCore` and `/00` from somewhere). Under the stock NAND layout, mtd numbering would come from this table (kernel `_addSstarPartition`, skipping hidden records) **or** from a `mtdparts=` string that U-Boot builds from the same table (`UB/drvSPINAND_api.c:473-497`, `common/cmd_mstar.c:1325-1330` `setenv("mtdparts", ...)`; kernel prefers `cmdlinepart` if present, `VK/drv/mdrv_spinand.c:947,1104-1121`). The dump will show which.

IPL/ROM: the ROM and IPL are not in these sources, so their search rules are **not verified**. The only evidence in-tree: the ROM-facing CIS holds `BL0PBA`, `BL1PBA`, `UBOOTPBA`, `HashPBA` (SNI offsets 30..38), and the writer is literally named `WriteCIS_for_ROM` (`UB/drvSPINAND_api.c:78`, `common/cmd_mstar.c:1223-1286`). The default (no PNI) mtdparts layout is `CIS` blocks 0,2,4, IPL x3, IPL_CUST x3 (1 block each), UBOOT x2 (3 blocks each), ENV (1 block) (`UB/drvSPINAND_api.c:146-203`); that string's offsets overlap the CIS copies, so I could not derive an exact block map from source and I am not claiming one.

### 4.3 U-Boot environment

Which U-Boot: `infinity2m_spinand_defconfig` (`CONFIG_MS_SPINAND=y`, `CONFIG_MS_SAVE_ENV_IN_NAND_FLASH=y`, `CONFIG_MS_SPINAND_QUAD_READ=y`, `uboot-vendor/configs/infinity2m_spinand_defconfig:369,379-381`) with `uboot-vendor/include/configs/infinity2m.h:190-196`: `CONFIG_ENV_IS_IN_NAND`, `CONFIG_ENV_OFFSET = ms_nand_env_offset`, `CONFIG_ENV_SIZE 0x20000`. The stock binary was not built from source we have, so treat what follows as expected, and confirm by scanning (4.4).

Offset (`UB/drvSPINAND_api.c:516-552`, called from `uboot-vendor/common/env_nand.c:244,461`):
1. If `SNI.UBOOTPBA != 0` -> block `(3 + 3 + 3)*1 + 2*3 = 15` (`CIS_DEFAULT_BACKUP + IPL_BACKUP + IPL_CUST_BACKUP` x `SBOOT_MAXBLOCK` + `UBOOT_BACKUP * UBOOT_MAXBLOCK`), offset `15 * block_size` (`:522-527`).
2. Else if a valid PNI was found: first record whose `PartType == 0x0D` exactly (`UB/drvSPINAND_api.c:499-514`, equality at :507, so a 0x8000/0x4000-flagged ENV record is not matched), offset `StartBlk * BlkPageCnt * PageByteCnt` (`:528-541`).
3. Else block 15 again (`:542-548`).

Hint from the SDK header: the commented-out layout at `uboot-vendor/include/configs/infinity2m.h:195,206-207` is `IPL0 0x60000@0x140000, IPL1, IPL_CUST0, IPL_CUST1 (0x60000 each), UBOOT0, UBOOT1 (0xC0000 each), ENV 0x60000, KERNEL 0x340000, RECOVERY 0x340000, -(UBI)`. Summing gives ENV at **0x440000** (block 34 at 128 KiB blocks; the commented `0x440000` at :195 agrees) with size 0x60000, and UBI as mtd index 9, which matches the stock `ubi.mtd=9`. So expect the env at 0x440000 if the stock image uses that layout (it is also what the `.pni` sample's first record start 0x0A = 0x140000 implies for the bootloader area). The block-15 fallback below is the code path when there is no usable PNI. Treat 0x440000 as the first thing to check, still confirm with 4.4. Size and format: `CONFIG_ENV_SIZE = 0x20000`. No redundancy (no `CONFIG_ENV_OFFSET_REDUND`/`CONFIG_SYS_REDUNDAND_ENVIRONMENT` anywhere in `include/configs/infinity2m.h` or the defconfig), so `ENV_HEADER_SIZE = 4` and the env_t is (`uboot-vendor/include/environment.h:137-162`):

```
u32 crc (LE)             # crc32(0, data, 0x20000 - 4), standard zlib CRC-32
u8  data[0x1FFFC]        # "k=v\0k=v\0...\0\0", rest zero
```
(`ENV_SIZE = CONFIG_ENV_SIZE - 4`, no AES, `environment.h:151-153`; CRC is checked inside `env_import(buf, 1)`, called at `common/env_nand.c:480`.)

Read details (`env_nand.c:290-321`): `readenv` reads `min(blocksize, ENV_SIZE)` bytes starting at `offset` and skips a block for which `nand_block_isbad()` is true only while `offset < offset + CONFIG_ENV_RANGE`. `CONFIG_ENV_RANGE` defaults to `CONFIG_ENV_SIZE` (`env_nand.c:50-52`; the 0x60000 value at `include/configs/infinity2m.h:286` is in the `ENV_IS_NOWHERE` branch), so there is no spare block: a bad env block makes `readenv` fail (amount_loaded != ENV_SIZE) and U-Boot falls back to default env. With 2048-byte pages and 64 pages/block that is exactly one block's main area (64 x 2048 = 0x20000), no OOB inside the env image. Stitch the 64 main areas.

Bad-block information to dump too: the vendor marks a block bad when `spare[0] != 0xFF` on page 0 (`UB/drvSPINAND_api.c:61-76`), and keeps a flash BBT in the last 4 blocks, tags `Bbt0` / `1tbB` at spare offset 1 (len 3), version at spare offset 4 (`UB/spinand.c:45-89`, `NAND_BBT_LASTBLOCK`, `maxblocks 4`). Dump the whole device including bad blocks and those last blocks.

### 4.4 Robust offline env finder (use on the dump)

For every block: take the first `0x20000` bytes of main data (concatenate pages), `crc = LE32(data[0:4])`, `ok = crc32(data[4:0x20000]) == crc`. Any ok block is an env copy. The text `bootargs=`, `mtdparts=` in it also gives the real partition list. Do not rely on the computed offset above.

---

## 5. Risks and unknowns

1. **0x03 over FSP is unproven.** The only FSP read-from-cache code (`_HAL_SPINAND_RIU_READ`, UBH:398-457; kernel :301-355) is dead in the SDK (`RIU_FLAG FALSE`); the vendor actually reads via QSPI/BDMA with 0x0B. Frame layout is the same as the vendor's fast read and standard SPI NAND, but chip-specific dummy counts are not checked. Go/no-go test right after the first CIS page read (`fsp_xfer 0x03` at col 0 gives the 16-byte tag `MSTARSEMIUSFDCIS`): also read col 8 with n=10 (expect bytes `49 55 53 46 44 43 49 53` = `IUSFDCIS`, then 2 bytes of SNI), and a span that crosses a 10-byte chunk boundary (e.g. col 5, n=10, compare with the bytes already read at cols 0..14). That catches a wrong dummy count or an ignored column. If it fails, swap 0x03 for 0x0B and repeat. If both fail, stop; the PIO path does not work and only the DMA path remains.
2. **Done polling is unverified against real timing**, and the vendor spins without delay. My suggested timeouts (2 ms per trigger, 20 ms OIP) are judgments, not from source (source: 60000 un-delayed polls U-Boot, 20000 x 1 us kernel).
3. **FSP clock**. If the clock were gated by something I did not find, `DONE` never sets. The FSP's PM SPI clock is not a Linux clk-framework gate in the stock DT (the `spinandflash`/`flashisp` `clocks` phandle 0x66 is `CLK_bdma`, `stock/00.dts:1052-1063`), so I assume the IPL/U-Boot state persists. I did not find proof, though. The tool logs `PM[0x20]` and aborts only on a done-timeout; it must not write the clock register (bit 14 is a source mux, writing it would switch the FSP clock source unverified).
4. **Interrupts.** `CTRL = 0x7` includes `INT_FSP` (bit 2). If that line is routed and unmasked in the stock kernel it could raise a spurious IRQ. The vendor sets it always (UBH:220), and without a driver it should be masked. I did not verify. Dropping to `0x3` would deviate from vendor and I do not know if DONE depends on INT.
5. **Concurrent users.** No stock driver in use for FSP/QSPI, but anything else that reprograms PM-sleep/chiptop registers in parallel is outside this recipe. The BDMA option is more exposed (shared BDMA channel 0, DRAM ownership).
6. **Chip unknown until the ID is read.** Variants that change the recipe: (a) **2-plane parts** (Micron, MXIC 22, Toshiba CB per the disabled table): column bit 12 on odd blocks, from `SNI.PlaneCnt` (offset 26). Without it, half the blocks are wrong. (b) **Winbond `EF AB 21`** (2 dies): die select (0xC2) is forbidden, so only whichever die is currently selected is readable, and the selection at handoff is unknowable. (c) **XTX (0x0B) with QE=1**. (d) **Status bit meanings** for ECC differ slightly per vendor; log the raw 0xC0 byte per page. (e) **Page > 2048** (4K pages): the vendor bootstrap and the PNI-based tools assume 2048 until the CIS is parsed; the first CIS read is 512 bytes at column 0 so that is safe.
7. **On-die ECC state is not changed, so data is ECC-corrected; "raw" (ECC-off) is impossible without 0x1F.** Uncorrectable pages (`ecc == 0x20`) still return data; flag them. Spare bytes: what the chip exposes for ECC parity differs per chip and per ECC mode; the spare may be partly masked by the on-die ECC. Not verifiable without the chip.
8. **Config assumptions at handoff.** Any of: OTP bit (0xB0 bit6) set, protection bits, buffer/continuous mode unusual, would make reads differ. Read 0xA0/0xB0/0xC0 up front and log. If 0xB0 bit6 (OTP) is set, stop: reads would return OTP pages.
9. **The stock U-Boot may not match this SDK.** Offsets, env size/location, redundancy, even the CIS layout can differ. Use 4.1 to find the CIS, 4.4 to find env copies; do not trust 4.3.
10. **IPL/ROM partition discovery is closed-source and not documented here.** Only the CIS fields (BL0PBA etc.) are visible.
11. **Throughput** numbers are my estimate only.
12. **Storage-type strap.** U-Boot decides SPI NAND from PM_SLEEP reg 0x1F bits 14,13,10 (`(reg >> 10) & (BIT4|BIT3|BIT0)`, `arch/arm/cpu/armv7/infinity2m/infinity2m.c:20-33,196-209`), which differs from the `DIDKEY 0x1F0071C0 & 0x3C == BIT2` check in `re/FINDINGS.md:45`. I did not reconcile the two. A wrong storage assumption is harmless here: the ID read (2.a) and the CIS tag check would simply fail and the tool would stop.
13. **Alternative path (not recommended):** the ISP byte interface (`CHX spi-msc313-isp.c:25-46,133-146,148-176,256-284`, password `0xAAAA` at ISP reg 0, trigger mode `0x3333` at 0xA8, per-byte WDATA/RDATA, CS held until `CECLR`) would allow arbitrary-length single reads per CS assertion, but it needs ISP unlock/trigger-mode writes into a shared bank (0x1F001000), is not what the vendor uses for NAND, and I found no I2M NAND use of it. Avoid.
14. `/dev/mem` accesses to 0x1F203C00 etc. need `CONFIG_STRICT_DEVMEM` off or an exempt range; RIU reads already work on this kernel (`re/FINDINGS.md:42-45`), but I did not confirm that writes to FSP at 0x1F002Dxx are also permitted. The tool should fail loudly on EPERM, never fall back to another interface.

---

## Appendix: minimal tool flow

```
map 0x1F001000, 0x1F002000, 0x1F203000 (O_SYNC, 4 KiB each)
verify 3.3 (reads only); abort on mismatch
id   = xfer(9F 00 ;3)               # abort if MID is 00/FF
a0   = get(A0); b0 = get(B0); c0 = get(C0)    # log; abort if b0 & 0x40 (OTP)
cis  = read_page(row=0, 512 bytes) # via 2.c + 2.d, col 0..511
parse SNI at +16 (tag at 0..15); if no tag try blocks 2,4,6,8
geometry = SNI; compare SNI.ID to id
for blk in 0..BlkCnt-1: for pg in 0..BlkPageCnt-1:
    row = blk*BlkPageCnt + pg
    xfer(13 row24); poll get(C0) OIP==0 (20 ms)
    read (PageByteCnt+SpareByteCnt) via 10-byte 0x03 chunks (plane bit if PlaneCnt and blk odd)
    write page + spare to the output; log c0 & 0x70 per page
unmap
```
