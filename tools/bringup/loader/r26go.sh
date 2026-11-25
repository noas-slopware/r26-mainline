#!/bin/sh
# Run on the stock R26, detached: setsid sh /tmp/r26go.sh <wdt-seconds> &
# Order: sanity dry run -> arm watchdog (hard deadline) -> quiesce -> patch + reboot(2).
# Any failure after arming ends in the watchdog reset into stock.
S=${1:-180}
cd /tmp || exit 1
exec > /tmp/r26go.log 2>&1
echo "go: $(date) wdt=$S"
# Never jump out of a stock system that is still booting or shutting down.
st=$(systemctl is-system-running 2>/dev/null)
up=$(cut -d. -f1 /proc/uptime)
case "$st" in running|degraded) ;; *) echo "go: stock not settled ($st), refusing"; exit 1;; esac
[ "$up" -ge 60 ] || { echo "go: stock uptime ${up}s < 60, refusing"; exit 1; }
./r26kexec --dry-run trampoline.bin r26-test.zImage r26-test.dtb "$S" || { echo "go: dry run failed"; exit 1; }
./r26kexec --arm-wdt-only "$S" || exit 1
# Stop the vendor EMAC's DMA (its driver has no .shutdown); this ends the SSH session.
ip link set eth0 down
sync
# Re-arms (fresh deadline), patches arm_pm_restart/reboot_mode, reboot(2).
./r26kexec trampoline.bin r26-test.zImage r26-test.dtb "$S"
echo "go: r26kexec returned $? (should not happen); watchdog will reset"
