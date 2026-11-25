# SigmaStar SSD202D (Infinity2M) SD host ("SDIO v5" / FCIE5-lite): hardware programming spec

Extracted from the vendor tree `vendor-tky` (branch takoyaki_dls00v050, Linux 4.9.84).
Configuration covered: infinity2m, IP index 0 (`IP_ORDER_0`, type `IP_TYPE_SDIO`), pad index 0 (`PAD_SD`, "SDIO_MODE_1"), slot 0, 4-bit bus, no SDIO card, ADMA, interrupt mode, stock DT node `sstar,sdmmc` (`stock/00.dts:1997-2014`).

Citation shorthand (all under `vendor-tky/drivers/sstar/sdmmc/` unless a full path is given):
- `HAL` = `src/hal_sdmmc_v5.c`, `INT` = `src/hal_card_intr_v5.c`, `PLAT` = `src/infinity2m/hal_card_platform.c`, `LNX` = `ms_sdmmc_lnx.c`
- `REGS_V5` = `inc/hal_card_regs_v5.h`, `PLAT_REGS` = `inc/infinity2m/hal_card_platform_regs.h`, `PLAT_CFG` = `inc/infinity2m/hal_card_platform_config.h`

---------------------------------------------------------------------------------------------------

## 0. Addressing conventions (read first)

- RIU base is physical `0x1F000000` (`PLAT_REGS:18`, `drivers/sstar/include/infinity2m/registers.h:34,66`). The vendor kernel maps it to virtual `0xFD000000` (`MS_IO_OFFSET 0xDE000000`, `drivers/sstar/include/ms_platform.h:23-25`). Every "physical" address below is the CPU physical address.
- Register macro: `GET_CARD_REG_ADDR(x,y) = x + (y << 2)` (`inc/hal_card_regs.h:107-108`). Every register is **16 bits wide on a 4-byte stride**: register index `N` lives at `bank_base + 4*N`. The driver does 16-bit volatile accesses (`CARD_REG`, `inc/hal_card_regs.h:110`). Read-modify-write macros `CARD_REG_SETBIT/CLRBIT` are plain 16-bit RMW (`:114-115`). The only 8-bit accesses are the CFIFO response byte reads (see section 5).
- Bank address macro for other blocks: `bank_base = 0x1F000000 + (bank_number * 0x200)`, i.e. the "bank" in the vendor GPIO code `GET_BASE_ADDR_BY_BANK(x,y) = x + (y<<1)` where y is the byte-addressed bank id (`ms_platform.h:29`). Both agree.
- RAM: CPU physical `0x20000000` (stock DT `memory`: `reg = <0x20000000 0xfe00000>`, 254 MB). MIU address = CPU physical - `0x20000000` (`PLAT:843-846` `Hal_CARD_TransMIUAddr`; `registers.h:23 ARM_MIU0_BUS_BASE 0x20000000`).

---------------------------------------------------------------------------------------------------

## 1. Register map

### 1.1 SDIO/FCIE5 IP, IP0 (this is the only IP used)

Bank bases (`PLAT_REGS:21-23`; the HAL picks them in `src/hal_card_regs.c:22-45`):

| Bank | RIU bank id | Physical base | Use |
|---|---|---|---|
| SDIO0_0 | 0x1410 | **0x1F282000** | main register file (all regs below) and CFIFO (regs 0x20..0x3F region used as the command/response FIFO) |
| SDIO0_1 | 0x1411 | 0x1F282200 | CIFD buffers (`A_SD_CIFD_POS`, `HAL:93-96`); only used by the CIF/R2N path, which this config never uses (see 6.5) |
| SDIO0_2 | 0x1412 | 0x1F282400 | listed in the table, never referenced by the SD flow |

Offsets below are register indices (`HAL:98-130`); byte offset = 4 x index; absolute = 0x1F282000 + 4 x index. Bit positions from `REGS_V5`.

| Idx | Byte off | Abs. phys | Name | Bits / notes |
|---|---|---|---|---|
| 0x00 | 0x000 | 0x1F282000 | MIE_EVENT | W1C event flags. b0 DATA_END, b1 CMD_END, b2 ERR_STS, b3 SDIO_INT, b4 BUSY_END_INT, b5 R2N_RDY_INT, b6 CARD_CHANGE, b7 CARD2_CHANGE (`REGS_V5:26-33`). Vendor's `M_SD_MIEEVENT` = b0,1,2,4,5 = 0x0037 (`HAL:77`). |
| 0x01 | 0x004 | 0x1F282004 | MIE_INT_EN | same bit positions as MIE_EVENT (`_IEN` names, `REGS_V5:40-47`). Interrupt line = events enabled here. |
| 0x02 | 0x008 | 0x1F282008 | MMA_PRI_REG | b0 MIU_R_PRIORITY, b1 MIU_W_PRIORITY, b3:2 MIU select (0 = MIU0), b5:4 MIU burst (11b = burst 8) (`REGS_V5:53-63`). Vendor value 0x0033 (`HAL:64`, written `HAL:810`). |
| 0x03 | 0x00C | 0x1F28200C | DMA_ADDR[15:0] | MIU address (CPU phys - 0x20000000) of data buffer (DMA) or of the ADMA descriptor table (ADMA). |
| 0x04 | 0x010 | 0x1F282010 | DMA_ADDR[31:16] | |
| 0x05 | 0x014 | 0x1F282014 | DMA_LEN[15:0] | DMA byte count; **fixed 0x0010 in ADMA mode** (`HAL:748`). |
| 0x06 | 0x018 | 0x1F282018 | DMA_LEN[31:16] | 0 in ADMA mode (`HAL:749`). |
| 0x07 | 0x01C | 0x1F28201C | MIE_FUNC_CTL | b0 EMMC_EN, b1 SD_EN, b2 SDIO_MODE. Vendor writes 0x0004 (SDIO_MODE) because `IP_0_TYPE == IP_TYPE_SDIO` (`HAL:168-176,802,990`, `PLAT_CFG:22`). |
| 0x08 | 0x020 | 0x1F282020 | JOB_BLK_CNT | block count (DMA) or 1 (ADMA, `HAL:747,753`). |
| 0x09 | 0x024 | 0x1F282024 | BLK_SIZE | block size in bytes (512). Written for every data cmd (`HAL:743`). |
| 0x0A | 0x028 | 0x1F282028 | CMD_RSP_SIZE | b15:8 = command size (5), b7:0 = response size in bytes (0 none, 5 for R1/R1b/R3/R6/R7, 0x10 for R2). Value = 0x0500 \| rspsize (`HAL:67,801`). |
| 0x0B | 0x02C | 0x1F28202C | SD_MODE | b0 CLK_EN, b1 BUS_WIDTH_4, b2 BUS_WIDTH_8, b4 DEST_R2N, b5 DATASYNC, b7 DMA_RD_CLK_STOP, b8 DIS_WR_BUSY_CHK, b9 STOP_BLK (`REGS_V5:68-77`). Vendor uses only b0, b1 (and b4/b7 in unused paths). |
| 0x0C | 0x030 | 0x1F282030 | SD_CTL | b0 RSPR2_EN, b1 RSP_EN, b2 CMD_EN, b3 DTRX_EN, b4 JOB_DIR (1 = write), b5 ADMA_EN, b6 JOB_START, b7 CHK_CMD, b8 BUSY_DET_ON, b9 ERR_DET_ON (`REGS_V5:83-94`). |
| 0x0D | 0x034 | 0x1F282034 | SD_STS | b0 DAT_RD_CERR, b1 DAT_WR_CERR, b2 DAT_WR_TOUT, b3 CMD_NORSP, b4 CMDRSP_CERR, b5 DAT_RD_TOUT, b6 CARD_BUSY, b8..b15 live DAT0..DAT7 pin levels (`REGS_V5:101-114`). b0..b5 are write-1-to-clear (vendor clears with `\|= 0x3F`, `HAL:185`). Error mask `M_SD_ERRSTS` = 0x003F (`HAL:76`). |
| 0x0E | 0x038 | 0x1F282038 | BOOT_MOD | b2 BOOT_MODE; vendor clears b2 before each cmd (`HAL:807`). |
| 0x0F | 0x03C | 0x1F28203C | DDR_MOD | b0 PAD_IN_BYPASS, b1 PAD_IN_RDY_SEL, b2/b3 PRE_FULL_SEL0/1, b7 DDR_MACRO_EN, b8 DDR_EN, b10 PAD_CLK_SEL, b11 PAD_IN_SEL_IP, b12 DDR_MACRO32_EN, b13 PAD_IN_SEL, b14 FALL_LATCH, b15 PAD_IN_MASK (`REGS_V5:121-135`). Vendor value for all speeds: 0x6400 = b10\|b13\|b14 (`HAL:598,811`). |
| 0x10 | 0x040 | 0x1F282040 | DDR_TOGGLE_CNT | never written. |
| 0x11 | 0x044 | 0x1F282044 | SDIO_MOD | vendor writes 0x0008 = b3 (R_SDIO_DET_INT_SRC, "Low level trigger from Joe's email") \| SDIO int mode bits (always 0 for non-SDIO) (`HAL:70,805`, `REGS_V5:152-166`). |
| 0x15 | 0x054 | 0x1F282054 | TEST_MOD | debug only. |
| 0x17 | 0x05C | 0x1F28205C | WR_SBIT_TIMER | defined (b15 enable) but **never written** by the vendor. |
| 0x18 | 0x060 | 0x1F282060 | RD_SBIT_TIMER | defined (b15 enable) but **never written**. |
| 0x20.. | 0x080.. | 0x1F282080.. | **CFIFO** (command out / response in) | `A_SD_CFIFO_POS = bank0 + 0x20 regs` (`HAL:92`). Halfword `k` at 0x1F282080 + 4k. 0x10 response bytes max, 5 command bytes. See sections 5. |
| 0x2F | 0x0BC | 0x1F2820BC | SDIO_DET_ON | b0; SDIO only. Not touched in this config. |
| 0x30 | 0x0C0 | 0x1F2820C0 | CIFD_EVENT | b0 WBUF_FULL, b1 WBUF_EMPTY_TRIG, b2 RBUF_FULL_TRIG, b3 RBUF_EMPTY. Only used by the CIF/R2N path (unused). |
| 0x31 | 0x0C4 | 0x1F2820C4 | CIFD_INT_EN | unused. |
| 0x37 | 0x0DC | 0x1F2820DC | BOOT | b0 NAND_BOOT_EN, b1 BOOTSRAM_ACCESS_SEL, b2 IMI_SEL; vendor clears b2:0 before each cmd (`HAL:808`). |
| 0x38,0x39 | | | DBG_BUS0/1 | debug dump only (`HAL:483-501`). |
| 0x3F | 0x0FC | 0x1F2820FC | FCIE_RST | b0 FCIE_SOFT_RST, b1 RST_MIU_STS, b2 RST_MIE_STS, b3 RST_MCU_STS, b4 RST_ECC_STS (`REGS_V5:233-238`). Reset status mask `M_RST_STS` = b1\|b2\|b3 = 0x000E (`HAL:78`). |

Cross-check against the community wiki: SD_CTL at byte offset 0x30 = index 0x0C (matches).

All register accesses are plain MMIO; no locking inside the HAL (the Linux glue serializes with a per-slot mutex, `LNX:206-232`).

### 1.2 Non-IP registers the SD driver touches (physical addresses)

| Block | Bank id | Base phys | Reg idx | Phys addr | Bit(s) | Purpose |
|---|---|---|---|---|---|---|
| CLKGEN | 0x1038 | 0x1F207000 | 0x45 | **0x1F207114** | b4:2 clock source mux, b1 (cleared; invert), b0 gate (1 = off, `CLK_GATE_SET_TO_DISABLE`) | SDIO clock (`PLAT:52,116,495-523`; stock DT `CLK_sdio` `reg = <0x1f207114 0x04>`, `mux-shift 2`, `mux-width 3`, `gate-shift 0`, `stock/00.dts:1442-1451`; `drivers/sstar/clk/ms_composite_clk.c:322`) |
| SC_GP_CTRL | 0x1133 | 0x1F226600 | 0x25 | **0x1F226694** | b3 | set to 1 = FCIE/SPI clock source selected (vendor comment says "[7] boot clock source (glitch free), 0: 12 MHz xtal, 1: FCIE/SPI clock source" but the code sets BIT03) (`PLAT:59,141,495`) |
| CHIPTOP | 0x101E | 0x1F203C00 | 0x08 | **0x1F203C20** | b9:8 `reg_sdio_mode` | 0 = SD pads are GPIO, **1 = SDIO_MODE_1 (PAD_SD_CLK/CMD/D0..D3, the dedicated SD pads)**, 2 = SDIO_MODE_2 (GPIO4..9) (`drivers/sstar/gpio/infinity2m/chiptop_reg.h:38-39`, `padmux_tables.c:62-93,693-725`) |
| CHIPTOP | 0x101E | 0x1F203C00 | 0x32 | **0x1F203CC8** | b5:0 drive, b12:8 pull | b5..b0 = drive strength of CLK, D3, D2, D1, D0, CMD (1 = high; vendor sets all six, `PLAT:156`). b12..b8 = pull enable for D3, D2, D1, D0, CMD (CLK has none) (`PLAT:326,372`) |
| CHIPTOP | 0x101E | 0x1F203C00 | 0x50 | 0x1F203D40 | b15 `reg_all_pad_in` | must be 0. Cleared at boot by the GPIO driver (`mhal_gpio.c:MHal_GPIO_Init`, byte addr 0xA1 bit7). The SD driver clears it itself only if `FORCE_SWITCH_PAD` (false on Linux, `pri_config.h:32`; code `PLAT:133-136`). |
| PADTOP | 0x103C | 0x1F207800 | per-pad (see 3.3) | | b5 OEN (1 = input), b4 OUT, b0 IN | GPIO function of each pad (`gpio_table.c`) |
| PM_SLEEP | 0x0E | 0x1F001C00 | 0x28 | **0x1F001CA0** | b14 `reg_pm_sd_cdz_mode` | 1 = pad 58 routed as "SD_CDZ" to the interrupt path (`pmsleep_reg.h:59-60`, `padmux_tables.c:733`) |
| PM_GPIO | 0x0F | 0x1F001E00 | 0x47 | **0x1F001F1C** | b0 OEN, b1 OUT, b2 IN | PAD_PM_SD_CDZ (pad 58) GPIO (`gpio_table.c:312-315`, byte addr 0xF8E; `PLAT:766,808`) |
| MIU flush | 0x1022 | 0x1F204400 | 0x05 / 0x10 | **0x1F204414**, **0x1F204440** | see 10.1 | `Chip_Flush_MIU_Pipe` (`arch/arm/mach-sstar/infinity2m/soc.c:143-162`) |
| INTRCTL (main intc, FIQ #23 = SD CDZ) | 0x1009 (byte id 0x100900) | 0x1F201200 | 0x44/0x48/0x4C (+4 for fiq word 1) | 0x1F201314 (mask), 0x1F201324 (polarity), 0x1F201334 (ack) | bit 7 of each | CDZ interrupt controller bits, see 3.5 (`drivers/sstar/irqchip/infinity2m/irqchip.c:70-215`) |

Pad GPIO register addresses actually used (derived from `gpio_table.c` byte addresses via `phys = 0x1F000000 + (addr<<1)`; these are the registers the stock kernel touches because `PADMUX_SET`/`GPIO_SET` = `*_BY_FUNC` on Linux, `pri_config.h:29-30`):

| Pad | Name | OEN (b5) / OUT (b4) / IN (b0) register phys |
|---|---|---|
| 19 | PAD_TTL0 (SDIO0_PWR per stock padmux) | 0x1F207880 |
| 51 | PAD_SD_CLK | 0x1F207954 |
| 52 | PAD_SD_CMD | 0x1F207950 |
| 53 | PAD_SD_D0 | 0x1F207940 |
| 54 | PAD_SD_D1 | 0x1F207944 |
| 55 | PAD_SD_D2 | 0x1F207948 |
| 56 | PAD_SD_D3 | 0x1F20794C |
| 58 | PAD_PM_SD_CDZ | 0x1F001F1C, bits are OEN b0, OUT b1, IN b2 (different layout) |

(The `BY_REG` branch of `PLAT` uses a *different* PADTOP numbering for the SD pads (0x50..0x55 = CLK,CMD,D0..D3, `PLAT:350-366`). That branch is not compiled on Linux and disagrees with `gpio_table.c` (CLK=0x55, CMD=0x54, D0=0x50, D1=0x51, D2=0x52, D3=0x53). Ignore it.)

---------------------------------------------------------------------------------------------------

## 2. Clocks

### 2.1 Clock selection (what is used on Linux)

`FORCE_HAL_CLK` is 1 (`LNX:74`), so the Linux `clk_set_rate()` path is compiled out and the HAL writes CLKGEN directly (`LNX:309-313,839-843`). The DT clock (`CLK_sdio`, phandle 0x14) is only `clk_prepare_enable`'d once at probe (`LNX:1378-1386`), which clears the gate bit (b0 of 0x1F207114).

`Hal_CARD_FindClockSetting(eIP, reqHz)` (`PLAT:559-578`): walk the table from fastest to slowest and take the first entry `<= request` (`reqHz >= table[lv]`; the table ends at the first 0 entry):

| mux idx (b4:2 of 0x1F207114) | Value written to 0x1F207114 (after clearing b4:0) | Real clock | Parent (stock DT `CLK_sdio` `clocks = <0x39 0x3a 0x3b 0x3c 0x3d 0x3e 0x0c 0x3f>`) | `PLAT` lines |
|---|---|---|---|---|
| 0 | 0x00 | 48,000,000 | utmi_192m_div4 | 500-501 |
| 1 | 0x04 | 43,200,000 | mpll_86m_div2 | 502-504 |
| 2 | 0x08 | 40,000,000 | utmi_160m_div4 | 505-507 |
| 3 | 0x0C | 36,000,000 | mpll_288m_div8 | 508-510 |
| 4 | 0x10 | 32,000,000 | utmi_160m_div5 | 511-513 |
| 5 | 0x14 | 20,000,000 | utmi_160m_div8 | 514-516 |
| 6 | 0x18 | 12,000,000 | xtali_12m | 517-519 |
| 7 | 0x1C | 300,000 | xtali_12m_div40 | 520-522 |

Parent frequencies are inferred from the clock node names/factors in the stock DT; the vendor table comments give the same Hz figures (`PLAT:63-70,500-521`). The lowest entry is 300 kHz (there is no 400 kHz): a 400 kHz request from the MMC core resolves to **300 kHz** (the vendor also sets `f_min = FindClockSetting(400000) = 300000`, `LNX:1512,1529`). 25 MHz resolves to 20 MHz, 26 MHz to 20 MHz, 50 MHz to 48 MHz. `f_max` = DT `slot-max-clks` = 0x02DC6C00 = 48,000,000 (`LNX:1531`).

Writes in order (`Hal_CARD_SetClock`, `PLAT:489-525`):
1. `SC_GP_CTRL[0x25] |= BIT3` (0x1F226694).
2. `CLKGEN[0x45] &= ~0x1F` (0x1F207114; this also un-gates the clock).
3. `CLKGEN[0x45] |= (idx << 2)` for the selected entry. For the 48 MHz entry nothing is set (idx 0).

`Hal_CARD_IPOnceSetting` at probe does steps 1 and 2 only (`PLAT:129-144`, called `LNX:1563`).

### 2.2 When the vendor changes the clock

- `ms_sdmmc_set_ios()` when `ios->clock` changed (`LNX:994-1019`): `_SetClock()` (`LNX:299-320`):
  1. `FindClockSetting`.
  2. `Hal_SDMMC_ClkCtrl(FALSE)`: writes MIE_FUNC_CTL = 0x0004, clears SD_MODE.CLK_EN (`HAL:988-999`) (comment: "disable clock first to avoid unexpected clock rate output").
  3. `Hal_CARD_SetClock` (above).
  4. `Hal_SDMMC_ClkCtrl(TRUE)`: MIE_FUNC_CTL = 0x0004, SD_MODE |= CLK_EN.
  5. `Hal_SDMMC_SetNrcDelay(realclk)`.
- `ms_sdmmc_request()` re-runs `Hal_CARD_SetClock(currRealClk)` at the start of **every** request (`LNX:839-843`). Redundant but harmless; it assumes `currRealClk != 0`.
- If the clock request is nonzero but resolves to 0 (can't happen with this table) the vendor prints an error.

### 2.3 Gating / enables

- CLKGEN 0x1F207114 b0: block clock gate (0 = running).
- SD_MODE b0 `CLK_EN` (card clock out). **The vendor gates the SD clock after every command**: `_SDMMC_EndProcess()` clears `CLK_EN | DMA_RD_CLK_STOP` when `bCloseClk` is true (`HAL:538-540`), and each new command rewrites SD_MODE with CLK_EN set (`HAL:803`, `V_SD_MODE_INIT = R_CLK_EN`). `bCloseClk` = TRUE for non-data commands and for data commands with no stop command; FALSE for data commands that will be followed by a stop command (CMD12) (`LNX:864`, `LNX:853,956`). Result: the card clock only runs during a command (and across a multi-block transfer up to and including the stop command). A new driver may keep the clock running if it prefers, but this is what the vendor does and is known to work with cards.
- `MMC_POWER_OFF` also clears CLK_EN via `Hal_SDMMC_ClkCtrl(FALSE)` (`LNX:264`); `MMC_POWER_ON` sets it (`LNX:289`).

### 2.4 NRC delay (command to command wait after register setup)

`Hal_SDMMC_SetNrcDelay(real)` (`HAL:633-653`) stores a microsecond delay used right after the register programming and before clearing status / starting a job (`Hal_Timer_uDelay(gu16_WT_NRC)`, `HAL:813`):

| real clock | delay (us) |
|---|---|
| >= 8 MHz | 1 |
| >= 4 MHz | 2 |
| >= 2 MHz | 4 |
| >= 1 MHz | 8 |
| >= 400 kHz | 20 |
| >= 300 kHz | 27 (this is the 300 kHz init clock) |
| >= 100 kHz | 81 |
| 0 | 100 |

(Initial value 0 until the first clock set.)

---------------------------------------------------------------------------------------------------

## 3. Pads, power, card detect

### 3.1 How pad setup is split on this board

`PADMUX_SET`/`GPIO_SET` = `*_BY_FUNC` on Linux (`inc/infinity2m/hal_card_platform_pri_config.h:29-30`) so the HAL calls the generic GPIO/padmux layer (`MDrv_GPIO_*` in `drivers/sstar/gpio/`), which writes the registers listed in 1.2.

The stock DT contains a `padmux` node with `schematic` entries (`stock/00.dts:2192-2196`; each entry is {pad, mode, puse}). Because this node exists, `mdrv_padmux_active() == 1` (`drivers/sstar/padmux/mdrv_padmux.c:61-64`), which changes the SD driver in three ways:
1. `Hal_CARD_ConfigSdPad` does **nothing** (`PLAT:222`).
2. The CDZ and power pad numbers come from the schematic, not from the SD DT node (`LNX:1260-1273,1304-1317`; the DT `slot-cdzs-gpios`/`slot-pwr-gpios` are not even read).
3. `padmux` itself, at `postcore_initcall`, calls `MDrv_GPIO_PadVal_Set(pad, mode)` for every schematic entry (`mdrv_padmux.c:119-120`).

Relevant schematic entries (decoded from `stock/00.dts:2194`; mode `0x30` = `PINMUX_FOR_SDIO_MODE_1`, `drivers/sstar/include/infinity2m/padmux.h:69`; puse ids `drivers/sstar/include/mdrv_puse.h:45-52`):

| Pad | Name | Mode | Puse |
|---|---|---|---|
| 0x13 = 19 | PAD_TTL0 | SDIO_MODE_1 (0x30) | MDRV_PUSE_SDIO0_PWR (0x20000) |
| 0x3a = 58 | PAD_PM_SD_CDZ | SDIO_MODE_1 (0x30) | MDRV_PUSE_SDIO0_CDZ (0x20001) |
| 0x33..0x38 = 51..56 | PAD_SD_CLK, CMD, D0, D1, D2, D3 | SDIO_MODE_1 (0x30) | SDIO0_CLK/CMD/D0..D3 (0x20002..0x20007) |

`HalPadSetMode_General(pad, mode)` (`mhal_pinmux.c:62-107`) behaviour: for pads 51..56 mode 0x30 matches a table row and sets CHIPTOP[0x08] (0x1F203C20) b9:8 = 01b (preserving other bits: `val = (old & ~mask) | BIT8`). For pads 19 and 58 there is no SDIO_MODE_1 row, so the call just **resets any other mux function currently active on that pad to GPIO** (clears the matching mux field to 0, logging `[Padmux]reset Pad_N(reg 0x... mask ...) to SDIO_MODE_1(org: ...)`) and returns -1 (ignored). The stock log line "[Padmux]reset Pad_51(reg 0x101e08; mask0x300) to GPIO(org: SDIO_MODE_1)" is produced by the SD driver's pull-down step (`PullPADPin`, below) calling `PadVal_Set(PAD_SD_CLK, GPIO)`, which clears CHIPTOP[0x08] b9:8 (the field value 01b equals the SDIO_MODE_1 row's `val`).

### 3.2 Probe-time pad sequence (`_SwitchPAD`, `LNX:237-252`, called from `LNX:1567`)

For slot 0 (IP 0, pad order 0):
1. `Hal_CARD_ConfigSdPad(0, PAD_SD)`: no-op because padmux active (`PLAT:215-254`). On a system without padmux it would do `PadGroupMode_Set(SDIO_MODE_1)` = CHIPTOP[0x08] b9:8 := 01b.
2. `Hal_CARD_ConfigPowerPad(0, 19)` (`PLAT:256-312`): padmux active so no mux write; stores pad 19 as the power pad and calls `Hal_CARD_PowerOff(0, 0)` immediately = **drives GPIO 19 low (output) because `slot-en-pwr-high-valid[0]=1`** (see 3.4).
3. `Hal_CARD_ConfigCdzPad(0, 58)` (`PLAT:702-779`): `PadVal_Set(58, PINMUX_FOR_PM_SD_CDZ_MODE = 0x76)` => PM_SLEEP[0x28] (0x1F001CA0) |= BIT14 (and any conflicting mux on pad 58 is cleared); then `MDrv_GPIO_Pad_Oen(58)` (see the polarity caveat in 3.5). Stores 58 as the CDZ pad.
4. `Hal_CARD_InitPADPin(0, PAD_SD)` (`PLAT:149-165`): CHIPTOP[0x32] (0x1F203CC8) |= 0x003F (all six drive bits high); then `PullPADPin(PULLDOWN)`.

`PullPADPin(PULLDOWN)` (`PLAT:323-368`): CHIPTOP[0x32] &= ~0x1F00 (pull enable off for D3..D0,CMD); `PadVal_Set` of pads 51..56 to GPIO (clears SDIO_MODE field); `MDrv_GPIO_Set_Low` for pads 51..56 (OEN bit cleared = output, OUT bit cleared = low). I.e. all SD pins are actively driven low while powered off.

`PullPADPin(PULLUP)` (`PLAT:369-403`): CHIPTOP[0x32] |= 0x1F00 (pulls on for D3..D0,CMD); `MDrv_GPIO_Pad_Odn` on pads 51..56 (OEN bit set = input); `MDrv_GPIO_PadGroupMode_Set(SDIO_MODE_1)` = CHIPTOP[0x08] b9:8 := 01b (via `HalPadSetMode`, loops all rows of mode 0x30, `mhal_pinmux.c:406-417`).

### 3.3 Power on/off sequence (`_SetPower`, `LNX:256-295`, driven by `ios->power_mode`, `LNX:1022-1033`)

DT delays for slot 0: `slot-pwr-on-delay = 1` ms, `slot-pwr-off-delay = 0x1e = 30` ms (`stock/00.dts:2008-2009`; `WT_POWERUP` 1 ms in `PLAT_CFG:44`).

- `MMC_POWER_UP`: `Hal_CARD_PowerOn(0,0)` (power pad high), `udelay(10)`, `PullPADPin(PULLUP)`, `msleep(WT_POWERUP = 1)`.
- `MMC_POWER_ON`: `Hal_SDMMC_ClkCtrl(TRUE,0)` (MIE_FUNC_CTL = 0x0004, SD_MODE |= CLK_EN), `Hal_SDMMC_Reset()` (soft reset, section 8.2), `msleep(slot-pwr-on-delay = 1)`.
- `MMC_POWER_OFF`: `Hal_SDMMC_ClkCtrl(FALSE,0)` (clears CLK_EN), `Hal_CARD_PowerOff(0,0)` (power pad low), `PullPADPin(PULLDOWN)`, `msleep(slot-pwr-off-delay = 30)`. On POWER_OFF the vendor also zeroes `initFlag`/`sdioFlag` so bus width and timing are reapplied on the next set_ios (`LNX:1028-1032`).
- The driver sets `MMC_CAP2_NO_PRESCAN_POWERUP` (`LNX:1620`), so the core does not power the card at registration.

### 3.4 Power pin: this contradicts "no power-enable GPIO"

`DEF_PWR_PAD_SLOT0 = PAD_TTL0 = 19` (`PLAT_CFG:56`, `gpio.h:39`) and the stock padmux schematic assigns `MDRV_PUSE_SDIO0_PWR` to pad 19 (3.1). Since padmux is active, `gu32_PwrNoSlot[0] = 19`, which is **not** `PAD_UNKNOWN`, so the stock kernel does drive GPIO19: `PowerOn` = `Set_High(19)` (OEN b5 cleared, OUT b4 set at 0x1F207880), `PowerOff` = `Set_Low(19)` (OEN cleared, OUT cleared), because `slot-en-pwr-high-valid[0] = 1` (`PLAT:602-608,660-666`; `LNX:1275`; `stock/00.dts:2007`). If the board really has nothing on TTL0, this is harmless (it merely toggles an unconnected/other pin) but a new driver should not claim GPIO19 unless the schematic says so. Open question 2 below.

### 3.5 Card detect (CD)

- CDZ pad: pad 58 `PAD_PM_SD_CDZ`, `slot-cdzs-gpios = <0x3a ...>` (= 58) agrees with the schematic.
- Level: `Hal_CARD_GetCdzState` reads `MDrv_GPIO_Pad_Read(58)` = PM_GPIO[0x47] (0x1F001F1C) **bit 2**; **low = card inserted** ("Low Active", `PLAT:801-822`; BY_REG branch confirms `& BIT2`, `PLAT:808`).
- `revcdz = 0` in the DT (`stock/00.dts:1999`): `_GetCardDetect()` returns the above unchanged (`LNX:378-395`). If `revcdz` were 1 the result would be inverted. `slot-fakecdzs = 0` (real CD).
- `ms_sdmmc_get_cd()` returns `_GetCardDetect()` (`LNX:1108-1120`). `get_ro` always 0 (no WP, `LNX:397-400`).
- Interrupt: `slot-intcdzs[0] = 1` so CD is interrupt driven and `MMC_CAP_NEEDS_POLL` is not set (`LNX:1542-1545`). DT interrupt `cdz_slot0_irq` = `<0x02 0x00 0x77 0x04>` = `ms_main_intc` (phandle 2, 3 cells) hwirq 0x77 = 119 = `INT_FIQ_SD_CDZ` (`GIC_SPI_MS_FIQ_START + 23`, `irqs.h:140`; FIQ #23 of the main intc, DT flags 4). The SD IRQ is `mie0_irq` = `<0x02 0x00 0x33 0x04>` = hwirq 0x33 = 51 = `INT_IRQ_SDIO` (`irqs.h:67`), level-high. `mie1_irq` has the same value but is not used with IP0 (`LNX:123,1348`).
- Edge arming (`Hal_CARD_SetGPIOIntAttr`, `LNX:180-202`): the CD IRQ is armed as an **edge** interrupt on the "opposite" level: if a card is present, `IRQ_TYPE_EDGE_RISING` (to catch removal, "OPT3"); if absent, `IRQ_TYPE_EDGE_FALLING` (to catch insertion, "OPT4"); then `irq_ack`. With `revcdz = 1` these are swapped (`LNX:755-763`). The main intc implements FIQ polarity as: `INTRCTL REG_ID_48 + (fiq/16)*4`, bit `fiq%16` set = falling edge, clear = rising edge; ack = write 1 to `REG_ID_4C + ...`; mask bit in `REG_ID_44 + ...` (1 = masked) (`irqchip.c:70-215`). For FIQ #23: word 1, bit 7: polarity 0x1F201324, mask 0x1F201314, ack 0x1F201334.
- Handler flow (`ms_sdmmc_cdzint` / `ms_sdmmc_hotplug`, `LNX:726-800`): the hard IRQ calls `disable_irq_nosync(irq)` and schedules a tasklet. The tasklet:
  - loops until the state is stable: **insert** needs the CD level to stay "present" for `WT_DB_PLUG` = 30 ms (1 ms `mdelay` polling, restart on any flip), then `mmc_detect_change(mmc, 300 ms)`, ack, re-arm for rising edge, `enable_irq`;
  - **remove** needs "absent" for `WT_DB_UNPLUG` = 30 ms, then `mmc_card_set_removed(card)`, `Hal_SDMMC_StopProcessCtrl(eIP, TRUE)` (aborts any in-flight wait; see section 8), `mmc_detect_change(mmc, 0)`, ack, re-arm for falling edge, `enable_irq`.
  - The abort flag is cleared again at the start of the next request when there is no card (`LNX:836-837`).
- Caveat on the pad direction: `Hal_CARD_ConfigCdzPad` calls `MDrv_GPIO_Pad_Oen(58)` (`PLAT:757`, comment "set it to input mode"; "Harry test"). `MHal_GPIO_Pad_Oen` does `reg &= ~m_oen` (`mhal_gpio.c`), which, going by the `BY_REG` branch (`PLAT:766` sets BIT0 for "input mode") and the PADTOP convention (b5 set = input), looks like it would *clear* the output-disable bit, i.e. enable the output. The code path shipped on the board is this one, and CD evidently works, so either the reset/bootloader state keeps the pad effectively input, or the naming is inverted. A new driver should simply treat 0x1F001F1C b2 as the input level, and make sure b0 (OEN) is 1 (input). **Verify on the device** (read 0x1F001F1C with a card in/out). Open question 1.

---------------------------------------------------------------------------------------------------

## 4. Controller init / reset sequence

There is no explicit "controller enable" in the HAL: all registers are rewritten for every command, except the one-time/probe items below.

### 4.1 Probe order (`ms_sdmmc_init_slot`, `LNX:1421-1648`; DT parse `LNX:1199-1406`)

1. DT parse (slotnum, revcdz, ip/pad orders, max clk, intcdz, fakecdz, pad numbers (from padmux), power-high-valid, pwr on/off delays, sdio-use) and `of_clk_get(np, ipidx*3)` + `clk_prepare_enable` (`LNX:1378-1386`).
2. Allocate the ADMA descriptor buffer: `dma_alloc_coherent(NULL, sizeof(AdmaDescStruct)*MAX_SEG_CNT = 16*128 = 2048 bytes, &adma_phy_addr)` (`LNX:1483`).
3. mmc_host config: `f_min = 300000` (resolved 400 kHz), `f_max = 48 MHz`, `ocr_avail = 2.7..3.3 V (all 100 mV steps from 2.7 to 3.3 V plus 1.65-1.95 V bit)` (`LNX:1533`), `caps = 4_BIT_DATA | MMC_HIGHSPEED | SD_HIGHSPEED` (`LNX:1534`), `caps2 = NO_SDIO | NO_PRESCAN_POWERUP` (non-SDIO slot), `max_blk_count 1024`, `max_blk_size 512`, `max_req_size 512 KiB`, `max_seg_size 512 KiB`, `max_segs 128` (`LNX:87-92,1548-1558`). No UHS, no CMD23, no 1.8 V signalling, no DDR.
4. `Hal_CARD_IPOnceSetting(0)` (clock source, section 2.1).
5. `_SwitchPAD()` (section 3.2).
6. `Hal_SDMMC_MIEIntCtrl(eIP, FALSE)`, `request_irq(mieIRQ, Hal_CARD_INT_MIE, IRQF_TRIGGER_NONE)`, then `Hal_SDMMC_MIEIntCtrl(eIP, TRUE)` (software flag that selects interrupt-wait instead of polling; `INT:147-155`, `LNX:1592-1602`).
7. `mmc_add_host()`, then CD IRQ arming + `request_irq(cdzIRQ)` (`LNX:1623-1648`).

### 4.2 Per-power-on init

`MMC_POWER_ON` -> CLK_EN on + soft reset (`Hal_SDMMC_Reset` = `_REG_ResetIP`), exact sequence in 8.2. After that, nothing else is written until the first command.

### 4.3 Registers written for every command (static "init" values)

(Values: `HAL:63-71`.) `V_MIE_PATH_INIT` = 0, `V_MMA_PRI_INIT` = 0x0033, `V_MIE_INT_EN_INIT` = DATA_END\|CMD_END\|SDIO_INT\|BUSY_END = 0x001B, `V_CMD_SIZE_INIT` = 5<<8, `V_SD_CTL_INIT` = 0, `V_SD_MODE_INIT` = CLK_EN, `V_SDIO_MODE_INIT` = 0x0008, `V_DDR_MODE_INIT` = 0. Written in the order in section 5.1.

### 4.4 Interrupt enables

- `MIE_INT_EN` (0x1F282004) is written at **every** command with 0x001B (`Hal_CARD_INT_SetMIEIntEn`, `INT:157-169`, called `HAL:819`); in polling mode (`MIEIntCtrl(FALSE)`) it is written 0. Bit 2 (ERR_STS) is intentionally *not* enabled (see section 10 on the SD_CTL ERR_DET_ON combination). Bit 3 (SDIO_INT) is enabled but cannot fire without SDIO mode/`SDIO_DET_ON` (not set here); a new driver can leave it out (0x0013) if it wants (unverified against hardware).
- Host IRQ: GIC level-high, hwirq as in 3.5, handler `Hal_CARD_INT_MIE` (section 7).

---------------------------------------------------------------------------------------------------

## 5. Command issue

### 5.1 Exact write order for one command (`Hal_SDMMC_SendCmdAndWaitProcess`, `HAL:797-888`)

Before the call (`ms_sdmmc_request`, `LNX:811-975`):
1. (`LNX:836`) if no card present, clear the stop-wait flag.
2. (`LNX:842`) `Hal_CARD_SetClock(currRealClk)`.
3. `Hal_SDMMC_SetCmdToken(opcode, arg)` (`HAL:666-685`, `LNX:848`): write the 5 command bytes into the CFIFO as 16-bit halfwords:
   - `CFIFO[0] (0x1F282080) = ((arg>>24)<<8) | (0x40 + opcode)`
   - `CFIFO[1] (0x1F282084) = (((arg>>8)&0xFF)<<8) | ((arg>>16)&0xFF)`
   - `CFIFO[2] (0x1F282088) = arg & 0xFF`
   i.e. bytes in order: `0x40|opcode`, arg[31:24], arg[23:16], arg[15:8], arg[7:0] (byte 0 in the low half of halfword 0). The CRC7 and end bit are generated by hardware (CMD size = 5 in CMD_RSP_SIZE[15:8]).
4. For a data command: `Hal_SDMMC_TransCmdSetting` (section 6.2).

Then inside `SendCmdAndWaitProcess` (all 16-bit writes, in this order):
1. `CMD_RSP_SIZE (0x0A) = 0x0500 | rspsize` with rspsize from the `SDMMCRspEmType` low byte: none 0x00, R1/R1b/R3/R6/R7 0x05, R2 0x10 (`hal_sdmmc_v5.h:90-98`; write `HAL:801`).
2. `MIE_FUNC_CTL (0x07) = 0x0004` (`HAL:802`).
3. `SD_MODE (0x0B) = 0x0001 | width | extra` where width = 0x0002 for 4-bit, 0 for 1-bit (`EV_BUS_4BITS = 0x02`), extra = `(transType>>8)` (0 for ADMA/DMA/none; 0x10 DEST_R2N for CIF) \| `(U8)(transType & 0x80)` (DMA_RD_CLK_STOP, only for plain `EV_DMA`; 0 for ADMA) (`HAL:803`). For ADMA, no DIS_WR_BUSY_CHK/STOP_BLK bits: the hardware's write-busy check stays enabled.
4. `SD_CTL (0x0C) = rspbits | dirbit | admabit | 0x0200 (ERR_DET_ON) | 0x0004 (CMD_EN)` where
   - `rspbits = (rspType >> 12)`: none 0; R1/R1b/R3 = 0x2 (RSP_EN); R2 = 0x3 (RSPR2_EN\|RSP_EN),
   - `dirbit = (cmdType >> 4)`: CMDRSP/CMDREAD 0, CMDWRITE (`0x101>>4 = 0x10`) = JOB_DIR,
   - `admabit = transType & 0x20` (ADMA_EN) (`HAL:804`).
5. `SDIO_MOD (0x11) = 0x0008` (`HAL:805`).
6. `BOOT_MOD (0x0E) &= ~0x0004`; `BOOT (0x37) &= ~0x0007` (`HAL:807-808`).
7. `MMA_PRI (0x02) = 0x0033` (`HAL:810`).
8. `DDR_MOD (0x0F) = 0x6400` (`HAL:811`, value from `HAL:598`; see section 9).
9. `udelay(NRC)` (2.4).
10. Clear status: `SD_STS |= 0x003F` and re-read; repeat up to 3 more times until `(SD_STS & 0x3F) == 0`. Then clear events: write `0x0037` to `MIE_EVENT` and re-read until `(MIE_EVENT & 0x37) == 0` (up to 3 retries); this also zeros the software event accumulator (`HAL:181-226,815`). Failure of either = `EV_STS_RIU_ERR` (reset IP).
11. `MIE_INT_EN (0x01) = 0x001B` (interrupt mode) (`HAL:819`).
12. Start:
    - **Command only, or write command (command phase)**: `SD_CTL |= JOB_START (0x40)` (`HAL:842`).
    - **Read command**: `SD_CTL |= DTRX_EN (0x08)`, then `SD_CTL |= DTRX_EN|JOB_START (0x48)` (`HAL:837-838`). Command and data phase are started together.
13. Wait (section 7): command-only/write: `MIE_EVENT & CMD_END`, timeout `WT_EVENT_RSP` = 10 ms (+10 ms interrupt-mode risk margin `WT_INT_RISKTIME`, `inc/hal_card_intr_v5.h:43`); read: `CMD_END|DATA_END` both, timeout 10 + 2000 ms.
14. R1b: `_REG_ClearMIEEvent()` then busy wait (5.3). R3/R4: `SD_STS = 0x0010` (CMDRSP_CERR, write-1-clear) to drop the bogus CRC error that the IP reports on responses that have no CRC (R3 = OCR, `HAL:865-866`, comment "For IP CRC bug").
15. Write command only, if `(SD_STS & 0x3F) == 0` after the command phase: data phase (6.3).
16. Return `SD_STS & 0x3F` as the error (`HAL:886`), after `_SDMMC_EndProcess` (clock gating, error handling, 8.1).

Sanity: a CMD with `SD_CTL = ... | CMD_EN | RSP_EN | ERR_DET_ON` and JOB_START is the whole command; `CHK_CMD` (b7) is **never** set by the vendor.

### 5.2 Response handling

After completion `Hal_SDMMC_GetRspToken()` (`HAL:698-723`) clears a 16-byte array then copies `rspsize` bytes (the low byte of CMD_RSP_SIZE, read back at `HAL:519`) from the CFIFO using **8-bit** accesses: byte `p` is at `0x1F282080 + 4*(p>>1) + (p&1)` (even bytes = low byte of halfword `p/2`, odd = high byte) (`HAL:358-365,713`). A 16-bit read of the halfword and a shift gives the same bytes (little-endian halfword).

Byte layout of the copied response (`LNX:921-927`):
- R1/R1b/R3/R6/R7 (size 5): `b[0]` = command-index byte (0x00|opcode for R1/R1b, 0x3F for R3 per SD spec) and is **ignored**; `b[1..4]` = the 32-bit payload, MSB first: `resp[0] = b1<<24 | b2<<16 | b3<<8 | b4`. The trailing CRC7/end byte is not delivered (5 bytes = index + 4 payload).
- R2 (size 0x10 = 16): `b[0]` header (ignored), `b[1..15]` = the 120 payload bits CID/CSD[127:8] (CRC byte dropped by the IP):
  - `resp[0] = b1<<24|b2<<16|b3<<8|b4`
  - `resp[1] = b5<<24|b6<<16|b7<<8|b8`
  - `resp[2] = b9<<24|b10<<16|b11<<8|b12`
  - `resp[3] = b13<<24|b14<<16|b15<<8|0` (low byte forced 0, matching what the Linux MMC core expects, since the CRC is not delivered).
- The stop command's response uses only `resp[0]` = b1..b4 (`LNX:962`).

Linux response type mapping (`_TransRspType`, `LNX:601-623`): `MMC_RSP_NONE` -> none; `MMC_RSP_R1` (also R5/R6/R7, they have the same flag set) -> R1; `MMC_RSP_R1B` -> R1b; `MMC_RSP_R2` -> R2; `MMC_RSP_R3` (also R4) -> R3; anything else -> R1. R1/R1b/R3 all use RSP_EN with 5 bytes; hardware does not check the index/CRC differently per type: the vendor handles R3's CRC by clearing SD_STS b4 afterwards (above). R2 uses RSPR2_EN|RSP_EN with 16 bytes. **The HW CRC check for R1 happens regardless (CMDRSP_CERR in SD_STS)**; there is no flag in the vendor code to skip it other than the post-clear for R3/R4. CHK_CMD is not used.

### 5.3 R1b busy wait (`HAL:858-864`, `_REG_WaitDat0HI` `HAL:231-262`)

After CMD_END of an R1b command:
1. Clear MIE events (write 0x0037, and zero the shadow accumulator).
2. Interrupt mode (this config): `SD_CTL |= BUSY_DET_ON (0x100)`; wait for `MIE_EVENT.BUSY_END_INT (b4)` with timeout `WT_DAT0HI_END` = 1000 ms (+10). In the ISR on BUSY_END: `SD_CTL &= ~BUSY_DET_ON` and `MIE_INT_EN &= ~0x10` (`INT:112-116`). (MIE_INT_EN is rewritten with 0x1B at the next command.)
3. Polling fallback (only when `MIEIntCtrl` is FALSE): poll `SD_STS & 0x100` (DAT0 pin high) every 1 us for up to 1000 ms (`HAL:246-261`).
4. Timeout = `EV_STS_DAT0_BUSY`, which resets the IP (8.1).
BUSY_DET_ON is never combined with `DTRX_EN`/`JOB_DIR=1` in this flow because R1b commands used here (CMD12, CMD38, CMD7 deselect etc.) have no data phase; SD_CTL is fully rewritten for the next command.

---------------------------------------------------------------------------------------------------

## 6. Data transfer

### 6.1 Mode selected

`EN_SDMMC_BRO_DMA = TRUE`, `EN_SDMMC_ADV_DMA = TRUE` (`LNX:80-81`) so `eTransType = EV_ADMA` for every data request (`LNX:821`). ADMA is selected by `SD_CTL.ADMA_EN (b5)` plus the descriptor table address in the DMA address registers. The plain DMA and the CIFD/"R2N" paths exist in the HAL but are not reachable in this build (the non-ADMA paths in `_PreDataBufferProcess` are `#if`'d out).

### 6.2 ADMA descriptors and register setup

Descriptor (16 bytes, little-endian, `AdmaDescStruct`, `inc/hal_sdmmc_v5.h:139-149`; fill `Hal_SDMMC_ADMASetting`, `HAL:939-971`):
- word0: bit0 = `End` (1 on the last descriptor), bits 2:1 = MIU select (always 0 = MIU0; the vendor never sets it, `Hal_CARD_TransMIUAddr` ignores its out-param, `PLAT:843-846`), bits 15:3 = 0, bits 31:16 = job (block) count = `sg_len / blksz`.
- word1: MIU address of the segment = `dma_address - 0x20000000`.
- word2: byte length of the segment (`sg->length`).
- word3: 0 (zeroed with `memset`).
Table has up to 128 descriptors, one per scatterlist segment (`MAX_SEG_CNT`, `LNX:89`), in a `dma_alloc_coherent` buffer.

Per data request (`LNX:429-529`, `LNX:856-911`):
1. For each sg segment: `dma_map_page(NULL, page, offset, length, dir)` (DMA_FROM_DEVICE for reads, DMA_TO_DEVICE for writes); fail on error/0 address (`LNX:457-472`).
2. Build the descriptor table in the coherent buffer (`LNX:474-484`).
3. **`Chip_Flush_MIU_Pipe()` (`L3_FLUSH_PIPE`) after building the table, for both reads and writes** (`LNX:486`, `#define L3_FLUSH_PIPE() Chip_Flush_MIU_Pipe()` `LNX:152`). See 10.1.
4. `au32Addr[0]` := `adma_phy_addr`; `u16ProcCnt = 1`, so total length/blocks = `blksz*blocks`.
5. `Hal_SDMMC_TransCmdSetting(ADMA, ...)` (`HAL:739-768`), written in this order (before the command registers of 5.1):
   - `BLK_SIZE (0x09) = blksz` (512)
   - `JOB_BLK_CNT (0x08) = 1`
   - `DMA_LEN[15:0] (0x05) = 0x0010`, `DMA_LEN[31:16] (0x06) = 0`
   - `DMA_ADDR[15:0] (0x03) = (adma_phy_addr - 0x20000000) & 0xFFFF`, `DMA_ADDR[31:16] (0x04) = (adma_phy_addr - 0x20000000) >> 16`.
   (For the unused plain-DMA path: `JOB_BLK_CNT = nblocks`, `DMA_LEN = nblocks*blksz`, `DMA_ADDR = buffer - 0x20000000`.)
6. Issue the command (5.1). MMA_PRI = 0x0033 = read and write priority + burst 8, MIU0.
7. After completion: `dma_unmap_page()` for each segment; for reads additionally `flush_dcache_page(page)` when the page is not a slab page (`LNX:548-556`). There is **no** `Chip_Flush_MIU_Pipe` after a read completes in the ADMA path.

Multi-segment ("broken DMA", `RunBrokenDmaAndWaitProcess`) is only used when `u16ProcCnt > 1`, which cannot happen in ADMA mode.

### 6.3 Read and write job sequences

- **Read** (single or multi block): one job. Registers as 5.1 steps 1-11, then `SD_CTL |= DTRX_EN`, `SD_CTL |= DTRX_EN|JOB_START`; the command and data phases run in that single job (ADMA reads data into memory as it arrives). Wait for `CMD_END` **and** `DATA_END`, timeout 10 + 2000 ms (+10 margin). Final SD_CTL (JOB_DIR=0, R1) = ERR_DET_ON\|ADMA_EN\|CMD_EN\|RSP_EN\|DTRX_EN\|JOB_START = 0x026E.
- **Write**: two jobs.
  1. Command job: `SD_CTL = JOB_DIR|ADMA_EN|ERR_DET_ON|CMD_EN|RSP_EN` (0x0236), `SD_CTL |= JOB_START` (-> 0x0276); wait `CMD_END` (10 ms).
  2. If `(SD_STS & 0x3F) == 0` (`HAL:868`): clear status and events (same retry helpers), then **overwrite** `SD_CTL = JOB_DIR|ADMA_EN` (0x0030) (no CMD_EN, no ERR_DET_ON, no RSP bits); `SD_CTL |= DTRX_EN`; `SD_CTL |= DTRX_EN|JOB_START` (final 0x0078); wait `DATA_END`, timeout 3000 ms (+10) (`HAL:868-884`). SD_MODE, MMA_PRI, DDR_MOD, BLK_SIZE, JOB_BLK_CNT, DMA_LEN/ADDR are *not* rewritten for the data job. Hardware performs the CRC status/busy wait itself (SD_MODE.DIS_WR_BUSY_CHK is 0).
  If the command phase reported an error, the data job is skipped and the error is returned.

### 6.4 Stop command

Manual CMD12 (no auto-stop; `SD_MODE.STOP_BLK` unused, no CMD23). The MMC core supplies `mrq->stop` for multi-block transfers; the vendor sends it *after* the data command, even if the data command failed (`LNX:947-968`), as a normal command: `SetCmdToken(opcode, arg)`, `SendCmdAndWaitProcess(EV_EMP, CMDRSP, R1b, TRUE)`. The clock is therefore kept running through the data command and gated after the stop command (2.3). Its response goes into `stop->resp[0]` only.

### 6.5 Limits

`max_blk_size 512`, `max_blk_count 1024` (`MAX_BRO_BLK_COUNT`), `max_req_size = 512 KiB`, `max_seg_size = 512 KiB`, `max_segs = 128`. The per-descriptor job count is 16 bits, length is 32 bits, so a segment up to 512 KiB is fine. The CIFD buffers (bank 1) are never used for data.

---------------------------------------------------------------------------------------------------

## 7. Interrupts and completion

- IRQ: `mie0_irq` (main intc hwirq 0x33, GIC level-high) -> `Hal_CARD_INT_MIE` (`INT:313-342`, `request_irq(..., IRQF_TRIGGER_NONE, "ms_sdmmc_mie")` `LNX:1595`). The same function is the IRQ handler for all events (shared IRQ per IP).
- ISR flow (`_CARD_INT_SaveMIEEvent`, `INT:97-129`):
  1. If `MIE_FUNC_CTL & EMMC_EN` return not-handled (not the case here).
  2. `u16Reg = MIE_EVENT`; OR the whole value into a software accumulator `gu16_MIEEvent_ForInt` (all event bits, including ERR_STS even though it is not enabled).
  3. `u16Reg &= MIE_INT_EN`; then `MIE_EVENT = 0` followed by `MIE_EVENT = (0x0013 & u16Reg)` (mask = DATA_END|CMD_END|BUSY_END bits); that clears (W1C) only those enabled events that fired. Events not in that mask (ERR_STS, R2N_RDY, SDIO_INT) are left set in the register until the next command's explicit clear. The leading write of 0 is a no-op for a W1C register.
  4. If the accumulator has BUSY_END: `SD_CTL &= ~BUSY_DET_ON`, `MIE_INT_EN &= ~0x10`.
  5. `wake_up(&wait_queue)`, return `IRQ_HANDLED`. (The handler claims the IRQ whenever EMMC_EN is clear, even if no enabled event was pending.)
- Waiting (`_REG_WaitEvent` / `Hal_CARD_INT_WaitMIEEvent`, `HAL:267-314`, `INT:226-253`): `wait_event_timeout(wq, (accumulator & req) == req || stop_flag, msecs_to_jiffies(ms + 10))`; success only if all requested bits are in the accumulator. The accumulator is zeroed whenever the HAL clears events (`Hal_CARD_INT_ClearMIEvent`, `INT:188-191`, called from `_REG_ClearMIEEvent` `HAL:207`).
- Events per operation:
  - command with/without response: CMD_END (b1).
  - read command with data: CMD_END (b1) + DATA_END (b0).
  - write data job: DATA_END (b0).
  - R1b busy end: BUSY_END_INT (b4).
  - ERR_STS (b2) is **never waited on and never enabled as an interrupt**; errors are read from SD_STS (b5:0) after CMD_END/DATA_END, or surface as a wait timeout.
- Polling fallback (only if `gu16_MIEINT_Mode == 0`, i.e. never in this driver): poll `(MIE_EVENT & req) == req` every 1 ms up to `ms` iterations (`HAL:285-310`); MIE_INT_EN is written 0 (`INT:166-167`). `DAT0` busy is polled at 1 us granularity.

---------------------------------------------------------------------------------------------------

## 8. Error handling and recovery

### 8.1 Error reporting (`_SDMMC_EndProcess`, `HAL:512-543`)

Codes (`inc/hal_sdmmc_v5.h:39-68`): the SD_STS bits are returned as-is: b0 RD_CERR (read CRC error), b1 WD_CERR (write CRC status error), b2 WR_TOUT, b3 NORSP (no response / cmd timeout), b4 RSP_CERR (response CRC), b5 RD_TOUT; plus software codes b6 RIU_ERR (status/event would not clear), b7 DAT0_BUSY (busy wait timeout), b8 MIE_TOUT (wait timed out), b9 SWPROC_ERR (aborted by card removal), b15 OTHER (DMA map failure).
- Always: record the error line, and read back the response size.
- If the code is nonzero and the stop-wait flag is set (card removed): code := `EV_SWPROC_ERR` and **reset the IP**.
- Else if the code has any of RIU_ERR, MIE_TOUT, DAT0_BUSY: dump registers (printk) and **reset the IP**.
- Plain SD_STS errors (b5:0 only): nothing is done; the next command clears SD_STS (step 10 of 5.1).
- If `bCloseClk` and not an SDIO device: clear `SD_MODE.CLK_EN | DMA_RD_CLK_STOP`.

### 8.2 IP soft reset (`_REG_ResetIP`, `HAL:319-353`; also used by `Hal_SDMMC_Reset` at POWER_ON)

1. `SD_CTL &= ~JOB_START`.
2. `FCIE_RST (0x1F2820FC) &= ~0x0001` (assert reset, active low).
3. Poll `FCIE_RST & 0x000E == 0x000E` (all three reset-status bits set) with `udelay(1)` per step, up to 100,000 steps (100 ms, `WT_RESET`); on timeout only a printk (`"IP Reset Switch Low Fail"`).
4. `FCIE_RST |= 0x0001` (release).
5. Poll `FCIE_RST & 0x000E == 0` with `udelay(1)` steps up to 100 ms; timeout only logs.
No register re-initialisation follows, since every command rewrites the configuration. The vendor does not retry the failed command; the error goes to the MMC core, which handles retries.

### 8.3 Mapping to Linux error codes (vendor behaviour)

- Data commands: error group TOUT {WR_TOUT, NORSP, RD_TOUT, RIU_ERR, DAT0_BUSY, MIE_TOUT} -> `-ETIMEDOUT`; COMM {RD_CERR, WD_CERR, RSP_CERR} -> `-EILSEQ`; anything else (including multi-bit combinations) keeps the raw positive code (`HAL:1072-1097`, `LNX:665-712`).
- Non-data commands: **the raw positive code is stored in `cmd->error`** (no mapping, `LNX:680`). A new driver should map NORSP/MIE_TOUT to `-ETIMEDOUT` and RSP_CERR to `-EILSEQ`.
- Software timeouts: response 10 ms, read data 2000 ms, write data 3000 ms, busy 1000 ms, reset 100 ms (+10 ms interrupt-mode margin on waits), `inc/infinity2m/hal_card_platform_config.h:48-50`, `HAL:54-56`.

### 8.4 Card removal during a request

`Hal_SDMMC_StopProcessCtrl(eIP, TRUE)` sets a flag that makes every wait return failure immediately and wakes the waiter (`HAL:1025-1036`, `INT:264-284`); the in-flight request ends with `EV_SWPROC_ERR` and a reset.

---------------------------------------------------------------------------------------------------

## 9. Bus width and timing

- Bus width: `ios->bus_width` -> `gu16_SD_MODE_DatLine` = 0x0 (1-bit) / 0x2 (4-bit) / 0x4 (8-bit) (`LNX:324-340`, `HAL:559-562`); ORed into SD_MODE (b2:b1) at each command (5.1 step 3). Applied in `set_ios` when width changed or `!initFlag` (`LNX:1036-1041`). 8-bit is not advertised.
- Bus timing: `HAL:574-621`, `LNX:344-375`, `set_ios` `LNX:1043-1049`:
  - `MMC_TIMING_LEGACY`, `UHS_SDR12`, default/`0xFF`: `EV_BUS_DEF`/`EV_BUS_LOW`.
  - `SD_HS`, `MMC_HS`, `UHS_SDR25/50/104`, `MMC_HS200`: `EV_BUS_HS`.
  - `UHS_DDR50`: does nothing in the shipped (non-bypass) build.
  - For LOW, DEF and HS the stored value is the same: `DDR_MOD = PAD_CLK_SEL|PAD_IN_SEL|FALL_LATCH = 0x6400` (b10, b13, b14) (`EN_BYPASSMODE` is FALSE). The "bypass mode" variant (`PAD_IN_BYPASS` for LOW/DEF) is compiled out.
  - So there is **no** per-speed sample-edge/phase tuning: input data is latched on the falling edge of the clock (FALL_LATCH) at all speeds. High speed differs only by the clock mux value (20 MHz for 25 MHz requests, 48 MHz for 50 MHz requests).
  - After POWER_OFF the vendor re-calls `_SetBusTiming(0xFF)` for clocks <= 400 kHz when the clock is set (`LNX:1011-1014`), which is the same 0x6400 value.
- No voltage switching; 3.3 V only (ocr mask includes 1.65-1.95 V bit but no switch is implemented).
- The `R_PAD_IN_RDY_SEL|PRE_FULL_SEL0|PRE_FULL_SEL1` variant of DDR_MOD (`gu16_DDR_MODE_REG_ForR2N`) is only used for CIF transfers and is unused.

---------------------------------------------------------------------------------------------------

## 10. Gotchas

### 10.1 `Chip_Flush_MIU_Pipe` (MIU write-pipe flush)

- Dispatch: `Chip_Flush_MIU_Pipe()` -> `chip_funcs.chip_flush_miu_pipe()` (`vendor-tky/arch/arm/mach-sstar/ms_chip.c:114-116`); for infinity2m the pointer is `mstar_chip_flush_miu_pipe` (`arch/arm/mach-sstar/infinity2m/soc.c:361`, body `:143-162`). The default `_default_flush_miu_pipe()` is empty (`ms_chip.c:238-241`).
- Implementation (`soc.c:143-162`), under `spin_lock_irqsave(&mstar_l2prefetch_lock)`:
  1. `*(u16*)0xFD204414 = 0x0010;` (physical **0x1F204414**, RIU bank 0x1022 reg index 0x05)
  2. `*(u16*)0xFD204414 = 0x0011;` (toggle bit 0 = "fire")
  3. spin until `*(u16*)0xFD204440 & BIT12` is set (physical **0x1F204440**, bank 0x1022 reg 0x10; "flush pipe finish" status). **There is no timeout.**
- What the vendor SD driver uses it for: only (a) once per data request after writing the ADMA descriptor table into coherent memory (`LNX:486`), for both read and write; (b) in the unused non-ADMA bounce-buffer paths. It is not called on completion of reads. Interpretation (not stated in the source): it makes CPU writes still sitting in the SoC's write buffers/"L3" visible to the MIU before the DMA engine fetches the descriptors. A new driver should call an equivalent after filling the descriptor table (and, to be safe, before job start for write data since `dma_map_*` only handles CPU caches). Whether writes to the data buffers also need it is not shown: the vendor relies on `dma_map_page()` for them and calls the flush once after building the table, which also orders earlier posted writes.

### 10.2 SD_CTL combinations and what the vendor does

- `ERR_DET_ON (b9)` is set in the first SD_CTL write of **every** command (`HAL:804`, `BIT09_T`), including reads where `DTRX_EN` is added afterwards (0x26E), which the wiki says gives error-interrupt storms. This is safe in the vendor flow only because `MIE_INT_EN.ERR_STS` (b2) is never enabled (`V_MIE_INT_EN_INIT`, `HAL:65`). **Do not enable the ERR_STS interrupt** while ERR_DET_ON and DTRX_EN are both set.
- For the write data job the vendor drops ERR_DET_ON (and CMD_EN, RSP bits) entirely: SD_CTL = `JOB_DIR|ADMA_EN`, then DTRX_EN, then JOB_START.
- `BUSY_DET_ON + JOB_DIR + DTRX_EN` (the stuck combination) is never produced: BUSY_DET_ON is only ORed in during the R1b busy wait of non-data commands, and SD_CTL is fully rewritten (`=`) at the next command.
- `CHK_CMD (b7)`, `SD_MODE.STOP_BLK (b9)`, `DIS_WR_BUSY_CHK (b8)`, `DATASYNC (b5)`, `DEST_R2N (b4)` are never set on this path.
- `JOB_START` is never explicitly cleared except by the full SD_CTL rewrite at the next command (or in `_REG_ResetIP`); whether hardware self-clears it is not visible in the source. The two-step start (`SETBIT DTRX_EN`, then `SETBIT DTRX_EN|JOB_START`) is two separate RMW writes; keep that order.

### 10.3 Ordering and timing items

- Everything (CFIFO command bytes, BLK_SIZE, JOB_BLK_CNT, DMA_LEN, DMA_ADDR) is programmed **before** the register block in 5.1, and `MIE_EVENT`/`SD_STS` are cleared **after** SD_CTL/SD_MODE and the NRC delay but **before** `JOB_START`.
- Clear events with a write of 0x37 (W1C) and re-read; retry up to 3 times.
- Interrupt enable (`MIE_INT_EN`) is (re)written at each command after the clears and before JOB_START.
- Wait for `CMD_END` before touching the CFIFO response; the response is read after the wait.
- R1b: clear events *after* CMD_END, then set BUSY_DET_ON and wait BUSY_END. Whether BUSY_END fires immediately if DAT0 is already high at that moment is not shown in the source.
- R3/R4: write 0x0010 to SD_STS after the wait to remove the false response-CRC error.
- Write data job needs a status/event clear between the command job and the data job (`HAL:870`).
- Pad/clock state: the pads must be in SDIO_MODE_1 (CHIPTOP[0x08] b9:8 = 01b) with pulls on (CHIPTOP[0x32] b12:8) before commands; in the powered-off state the vendor drives all SD pins low as GPIO.
- `reg_all_pad_in` (CHIPTOP idx 0x50 b15) must be 0.
- SD clock is gated after each command (2.3); the first command after a gap rewrites `SD_MODE` with CLK_EN set. Between commands there is no card clock (including right after the R1b busy of CMD12).
- Each request re-programs CLKGEN (`LNX:842`); not needed if the rate has not changed.
- `msleep`-style delays only in power sequencing; the HAL polling waits are all `udelay/mdelay` loops, no sleeping inside the HAL (the interrupt-mode waits sleep on a waitqueue).

### 10.4 Things that are present in the source but do not apply here

SDIO interrupt/`SDIO_DET_ON`/`SDIO_MOD` int modes (slot-sdio-use = 0), CIFD/R2N data path, plain DMA path, DDR/UHS, bypass mode, MIU1-3 select, pad order 1 (SDIO_MODE_2), `FORCE_SWITCH_PAD`, the `BY_REG` pad/GPIO implementations, runtime/suspend PM (which just saves/restores CLKGEN[0x45] and SC_GP_CTRL[0x25] and re-runs `_SwitchPAD`, `LNX:1863-1927`).

---------------------------------------------------------------------------------------------------

## 11. Open questions / ambiguities

1. CDZ pin direction: `MDrv_GPIO_Pad_Oen(58)` clears PM_GPIO[0x47] b0, which by the `BY_REG` branch and PADTOP convention seems to be the opposite of input. Verify on hardware (read 0x1F001F1C b2 with/without card; b0 should be 1 for input). Level mapping itself is clear: b2 low = card present.
2. Power pad: stock padmux schematic maps `SDIO0_PWR` to pad 19 (PAD_TTL0, GPIO regs at 0x1F207880, active-high), so the stock kernel drives GPIO19 even if nothing on the board uses it. Confirm against the R26 schematic whether GPIO19 is connected to anything; if not, omit power handling in the new driver (but keep the 1 ms / 30 ms delays).
3. Whether `JOB_START` (SD_CTL b6) self-clears is not shown in the vendor code.
4. R1b: behaviour of the BUSY_END event when DAT0 is already high when BUSY_DET_ON is set is not shown; the vendor relies on it firing (1000 ms timeout).
5. `Chip_Flush_MIU_Pipe` semantics are only known from its register sequence (toggle 0x1F204414 b0, wait 0x1F204440 b12). The exact name of the register and whether it covers data buffers is not stated.
6. SC_GP_CTRL[0x25] b3: the vendor comment talks about bit 7 but the code uses BIT03; we follow the code.
7. CLKGEN b1 (invert) is only inferred from the clear-all-five-bits behaviour; the clock tree DT only defines mux b4:2 and gate b0.
8. The MIE_INT_EN SDIO_INT bit (b3) is enabled by the vendor even for non-SDIO use; it is harmless as far as the source shows but could be left off.
9. The non-data command error return in the vendor glue is a positive raw code, not an errno; the mapping in 8.3 is a recommendation, not vendor behaviour.
10. The IRQ for CD is a FIQ line (main intc #23) fed from the PM sleep domain; a mainline port needs either the existing sstar intc driver or a plain GPIO interrupt on pad 58 (PM_SLEEP irq `INT_PMSLEEP_SD_CDZ`, `irqs.h:231`; `mhal_gpio.c` `_pmsleep_to_irq_table[0]`). Which one the existing mainline-port intc supports was not examined.
