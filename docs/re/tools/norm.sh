#!/bin/sh
# normalize Ghidra C: addresses, auto names, mmc_host +0x80 shift is NOT normalized (kept visible)
sed -E -e 's/_?DAT_[0-9a-f]{8}/DAT/g' -e 's/(FUN|func|LAB|PTR|s)_0?x?[0-9a-f]{8}/\1_X/g' -e 's/^(\S+ \**)[A-Za-z_][A-Za-z0-9_.]*\(/\1FN(/' -e 's/[a-z]Var[0-9]+/v/g' -e 's/[a-z]Stack_[0-9a-f]+/stk/g' "$1"
