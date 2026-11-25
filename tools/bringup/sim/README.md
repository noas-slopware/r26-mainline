# Loader rehearsal (QEMU)

`rehearse.sh` runs the `r26kexec` loader end to end under `qemu-system-arm -M vexpress-a15 -smp 2`:
a stock-like 4.9.84 Thumb-2 SMP kernel (linux-chenxing-vendor-slop `v4.9.84-vanilla` plus the vendor's
`__ret_fast_syscall` fix, Arm GNU 8.2, no DEBUG_RODATA) boots a stage-1 initramfs that runs the loader,
which must land in a payload kernel (`R26KEXEC_PAYLOAD_OK` on its command line).

It expects a workspace `R` with `sim/linux-4.9`, `sim/build-4.9`, `sim/rootfs-src`, `sim/stage1.list`,
`loader/` and a built `usr/gen_init_cpio`. The loader is built with `-DNO_WDT -DCRUMB_PHYS=0u` and the
vexpress addresses taken from the 4.9 `System.map`.
