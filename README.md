# docs

Docs for [r26-mainline](https://github.com/noas-slopware/r26-mainline), covering the install guide
plus the reverse-engineering notes and tools behind the port.

| path | what |
|---|---|
| `docs/install.md` | installing the Alpine image on the R26, updates, recovery, going back |
| `docs/re/FINDINGS.md` | the port's lab log, oldest first (vendor kernel, boot chain, and every test run on the box) |
| `docs/re/sdmmc-hw.md` | the SD host as the shipped kernel drives it, register by register (the spec `sstar-sdio` was written from) |
| `docs/re/spinand-read.md` | reading the on-board SPI NAND from the stock kernel, read-only |
| `docs/re/usb-start-ehc-i2m.txt` | the vendor's USB host bring-up order |
| `docs/re/tools/` | `fnmatch.py` (function matching against a rebuilt vendor kernel), `initcall-at.py`, the Ghidra scripts, and on-device tools: `spinand-dump` (read-only SPI NAND dumper), `riuread`, `riuw1c`, `r26peek` (read-only register peek) |

The on-device tools are static armhf binaries. `docs/re/tools/build.sh` builds them using the Arm GNU
8.2 toolchain that `tools/bringup/initramfs/build.sh` on the `senpai` branch fetches. They need a
kernel with `/dev/mem` (the stock one has it, while the mainline production config doesn't).
