#!/bin/bash
# Derive a loader test DTB from the production DTB:
#  - /memory starts at 0x20400000, so the stock kernel image (where CPU1 stays
#    parked by r26kexec) is never touched
#  - the stock kernel's CMA area (live EHCI/EMAC DMA at handover) is reserved
#  - test bootargs (no SMP: CPU1 belongs to the parked stock kernel)
# usage: mktestdtb.sh <prod.dtb> <out.dtb> [extra bootargs]
set -e
in=$1 out=$2 extra=$3
cp "$in" "$out"
fdtput -t x "$out" /memory reg 20400000 07a00000
fdtput -c "$out" /reserved-memory/stock-cma@27e00000
fdtput -t x "$out" /reserved-memory/stock-cma@27e00000 reg 27e00000 200000
fdtput -t s "$out" /reserved-memory/stock-cma@27e00000 no-map ""
fdtput -t s "$out" /chosen bootargs "nosmp ip=192.0.2.46::192.0.2.1:255.255.255.0:r26test:eth0:off carrier_timeout=10 netconsole=6665@192.0.2.46/eth0,6666@192.0.2.54/ clk_ignore_unused loglevel=8${extra:+ $extra}"
