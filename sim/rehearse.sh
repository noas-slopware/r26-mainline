#!/bin/bash
# Rebuild the 4.9 simulation kernel, derive restart-path addresses, build the
# simulation loader against them, and run the rehearsal in QEMU vexpress-a15 -smp 2.
set -e
R=${R:?set R to the workspace holding sim/, loader/, build/ (see sim/README)}
S=$R/sim
TC=$R/toolchains/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf/bin
B=$S/build-4.9
export PATH=$TC:$PATH

make -C $S/linux-4.9 -s -j20 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- HOSTCFLAGS=-fcommon O=$B zImage

sym() { awk -v s="$1" '$3 == s { print "0x" $1 }' $B/System.map; }
APR=$(sym arm_pm_restart)
RBM=$(sym reboot_mode)
SR=$(printf '0x%x' $(( $(sym _soft_restart) | 1 )))
KEND=$(printf '0x%x' $(( ($(sym _end) + 0xfffff) & ~0xfffff )))
echo "sim: arm_pm_restart=$APR reboot_mode=$RBM _soft_restart|1=$SR kernel_end=$KEND"

arm-linux-gnueabihf-gcc -O2 -static -DNO_WDT -DCRUMB_PHYS=0u \
	-DARM_PM_RESTART_PHYS=${APR}u -DARM_PM_RESTART_STOCK=${STOCK_APR:-0}u \
	-DREBOOT_MODE_PHYS=${RBM}u -DSOFT_RESTART_THUMB=${SR}u \
	-DRAM_BASE=0x80000000u -DRAM_END=0x88000000u \
	-DDTB_DEST=0x81f00000u -DZIMAGE_DEST=0x82000000u -DWINDOW_END=0x83000000u \
	-DKERNEL_END=${KEND}u -DCMA_BASE=0x88000000u \
	-o $S/rootfs-src/r26kexec-sim $R/loader/r26kexec.c 2>/dev/null

[ -n "$KEEP_PAYLOAD" ] || cp $B/arch/arm/boot/zImage $S/rootfs-src/payload.zImage
cp $R/loader/trampoline.bin $S/rootfs-src/
$R/build/r26/usr/gen_init_cpio $S/stage1.list > $S/stage1.cpio

timeout ${QEMU_TIMEOUT:-90} qemu-system-arm -M vexpress-a15 -smp 2 -m 128M -nographic -no-reboot \
	-kernel $B/arch/arm/boot/zImage -dtb $B/arch/arm/boot/dts/vexpress-v2p-ca15-tc1.dtb \
	-initrd $S/stage1.cpio -append "console=ttyAMA0 rdinit=/init" > $S/qemu.log 2>&1 || true
grep -E 'SIM:|r26kexec|Booting Linux|Kernel command line|CPU1: stopping|Unable to handle|Kernel panic|Internal error|Brought up|Uncompressing' $S/qemu.log
