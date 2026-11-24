// SPDX-License-Identifier: GPL-2.0
/*
 * r26kexec: start a new kernel from the running stock Gustard R26 kernel
 * (4.9.84, no kexec, no sysrq) through /dev/mem.
 *
 * The stock reboot path ends in machine_restart(): smp_send_stop(), then
 * arm_pm_restart(reboot_mode, cmd). We point arm_pm_restart at the stock
 * kernel's own _soft_restart() and reboot_mode at a trampoline page, so
 * _soft_restart(tramp_phys, false) turns the MMU off and jumps there. No
 * new code ever runs under the stock MMU.
 *
 * Safety: before patching anything the hardware watchdog is armed with a
 * hard deadline and nothing in the new kernel feeds it. Every failure and
 * every finished session ends in a watchdog reset into the untouched
 * stock boot from the SD card.
 *
 * usage: r26kexec [--dry-run] <tramp.bin> <zImage> <dtb> <wdt-seconds>
 * All SoC/kernel addresses are compiled in below for the shipped
 * GustardCore 4.9.84 #30 image; the tool refuses to run if the patched
 * words don't hold the expected stock values.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define PAGE		4096u

/* Shipped GustardCore 4.9.84 #30 (see re/FINDINGS.md) */
#ifndef ARM_PM_RESTART_PHYS
#define ARM_PM_RESTART_PHYS	0x203b5114u	/* VA 0xc03b5114 */
#endif
#ifndef ARM_PM_RESTART_STOCK
#define ARM_PM_RESTART_STOCK	0xc0018f09u	/* global_reset | Thumb */
#endif
#ifndef REBOOT_MODE_PHYS
#define REBOOT_MODE_PHYS	0x203956b4u	/* VA 0xc03956b4 */
#endif
#ifndef SOFT_RESTART_THUMB
#define SOFT_RESTART_THUMB	0xc000ea45u	/* _soft_restart | Thumb */
#endif

/* RAM and where things go */
#ifndef RAM_BASE
#define RAM_BASE	0x20000000u
#endif
#ifndef RAM_END
#define RAM_END		0x28000000u
#endif
#ifndef DTB_DEST
#define DTB_DEST	0x21f00000u	/* below the zImage, above the kernel */
#endif
#ifndef ZIMAGE_DEST
#define ZIMAGE_DEST	0x22000000u
#endif
#ifndef WINDOW_END
#define WINDOW_END	0x23000000u	/* [DTB_DEST, WINDOW_END) is copy target */
#endif
#ifndef KERNEL_END
#define KERNEL_END	0x20400000u	/* stock kernel image, keep out */
#endif
#ifndef CMA_BASE
#define CMA_BASE	0x27e00000u	/* stock CMA: live DMA, keep out */
#endif

/* Watchdog, 12 MHz (vendor U-Boot WDT_CLK) */
#define WDT_PHYS	0x1f006000u
#define WDT_CLK_HZ	12000000u
#define WDT_CLR		0x00
#define WDT_MAX_PRD_L	0x10
#define WDT_MAX_PRD_H	0x14
#define WDT_UNBIND	"/sys/bus/platform/drivers/infinity-wdt/unbind"
#define WDT_DEVNAME	"1f006000.watchdog"

/* trampoline.S: params are the last 16 bytes of the flat binary */
#ifndef CRUMB_PHYS
#define CRUMB_PHYS	(WDT_PHYS + 0x04)	/* WDT_DUMMY_REG_1 */
#endif
#define LIST_ENTRIES	((PAGE - 8) / 8)

struct page { uint8_t *va; uint32_t pa; };

static int dry_run;

static void die(const char *what)
{
	fprintf(stderr, "r26kexec: %s: %s\n", what, strerror(errno));
	exit(1);
}

static uint8_t *read_file(const char *path, size_t *len)
{
	int fd = open(path, O_RDONLY);
	struct stat st;
	uint8_t *buf;
	size_t off = 0;

	if (fd < 0 || fstat(fd, &st))
		die(path);
	buf = malloc(st.st_size);
	while (off < (size_t)st.st_size) {
		ssize_t r = read(fd, buf + off, st.st_size - off);
		if (r <= 0)
			die(path);
		off += r;
	}
	close(fd);
	*len = st.st_size;
	return buf;
}

static int pa_ok(uint32_t pa)
{
	if (pa < KERNEL_END || pa >= CMA_BASE)
		return 0;
	if (pa >= DTB_DEST && pa < WINDOW_END)
		return 0;
	return 1;
}

/* Allocate n locked pages whose physical address is safe to read during the copy. */
static struct page *alloc_pages(unsigned int n, int pagemap)
{
	struct page *pg = calloc(n, sizeof(*pg));
	unsigned int got = 0;

	while (got < n) {
		unsigned int batch = (n - got) + 64;
		uint8_t *va = mmap(NULL, batch * PAGE, PROT_READ | PROT_WRITE,
				   MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE | MAP_LOCKED,
				   -1, 0);
		if (va == MAP_FAILED)
			die("mmap");
		for (unsigned int i = 0; i < batch && got < n; i++) {
			uint64_t ent;
			uint8_t *p = va + (size_t)i * PAGE;

			p[0] = 0;	/* make sure it's present */
			if (pread(pagemap, &ent, 8, ((uintptr_t)p / PAGE) * 8) != 8)
				die("pagemap");
			if (!(ent & (1ull << 63)))
				continue;
			uint64_t pfn = ent & ((1ull << 55) - 1);
			uint32_t pa = (uint32_t)(pfn * PAGE);
			if (!pfn || !pa_ok(pa))
				continue;	/* stays mapped+locked, just unused */
			pg[got].va = p;
			pg[got].pa = pa;
			got++;
		}
	}
	return pg;
}

static void clean_dcache(struct page *pg, unsigned int n)
{
	/* ARM private cacheflush: clean+invalidate by VA (broadcast) */
	for (unsigned int i = 0; i < n; i++)
		if (syscall(0xf0002, pg[i].va, pg[i].va + PAGE, 0))
			die("cacheflush");
}

static uint32_t mem_read32(int mem, uint32_t pa)
{
	uint32_t v;

	if (pread(mem, &v, 4, pa) != 4)
		die("read /dev/mem");
	return v;
}

static void mem_write32(int mem, uint32_t pa, uint32_t v)
{
	if (pwrite(mem, &v, 4, pa) != 4)
		die("write /dev/mem");
}

static void wdt_arm(int mem, unsigned int secs)
{
	volatile uint8_t *w = mmap(NULL, PAGE, PROT_READ | PROT_WRITE,
				   MAP_SHARED, mem, WDT_PHYS);
	uint32_t t = secs * WDT_CLK_HZ;

	if (w == MAP_FAILED)
		die("mmap wdt");
	*(volatile uint16_t *)(w + WDT_CLR) = 1;
	*(volatile uint16_t *)(w + WDT_MAX_PRD_H) = t >> 16;
	*(volatile uint16_t *)(w + WDT_MAX_PRD_L) = t & 0xffff;
	*(volatile uint16_t *)(w + WDT_CLR) = 1;
	fprintf(stderr, "r26kexec: watchdog armed, %u s (prd %04x%04x)\n", secs,
		*(volatile uint16_t *)(w + WDT_MAX_PRD_H),
		*(volatile uint16_t *)(w + WDT_MAX_PRD_L));
}

static int wdt_disarm(int mem)
{
	volatile uint8_t *w = mmap(NULL, PAGE, PROT_READ | PROT_WRITE,
				   MAP_SHARED, mem, WDT_PHYS);
	uint16_t h, l;

	if (w == MAP_FAILED)
		die("mmap wdt");
	*(volatile uint16_t *)(w + WDT_CLR) = 1;
	*(volatile uint16_t *)(w + WDT_MAX_PRD_H) = 0;
	*(volatile uint16_t *)(w + WDT_MAX_PRD_L) = 0;
	*(volatile uint16_t *)(w + WDT_CLR) = 0;
	h = *(volatile uint16_t *)(w + WDT_MAX_PRD_H);
	l = *(volatile uint16_t *)(w + WDT_MAX_PRD_L);
	fprintf(stderr, "r26kexec: watchdog disarmed (prd %04x%04x)\n", h, l);
	return (h || l) ? 1 : 0;
}

int main(int argc, char **argv)
{
	size_t tlen, zlen, dlen;
	uint8_t *tramp, *zimg, *dtb;
	unsigned int zpages, dpages, entries, lpages, secs;
	struct page *data, *list, *tp;
	int pagemap, mem;
	cpu_set_t cpu0;

	if (argc == 2 && !strcmp(argv[1], "--disarm-wdt")) {
		mem = open("/dev/mem", O_RDWR | O_SYNC);
		if (mem < 0)
			die("/dev/mem");
		return wdt_disarm(mem);
	}
	if (argc == 3 && !strcmp(argv[1], "--arm-wdt-only")) {
		/* T1: exercise the exact unbind+arm path, then let the reset happen */
		secs = strtoul(argv[2], NULL, 0);
		if (secs < 30 || secs > 300)
			return fprintf(stderr, "r26kexec: wdt seconds must be 30..300\n"), 2;
		mem = open("/dev/mem", O_RDWR | O_SYNC);
		if (mem < 0)
			die("/dev/mem");
		int u = open(WDT_UNBIND, O_WRONLY);
		if (u >= 0) {
			if (write(u, WDT_DEVNAME, strlen(WDT_DEVNAME)) < 0 && errno != ENODEV)
				die("unbind wdt");
			close(u);
		}
#ifndef NO_WDT
		wdt_arm(mem, secs);
#endif
		return 0;
	}
	if (argc > 1 && !strcmp(argv[1], "--dry-run")) {
		dry_run = 1;
		argv++;
		argc--;
	}
	if (argc != 5) {
		fprintf(stderr, "usage: r26kexec [--dry-run] <tramp.bin> <zImage> <dtb> <wdt-seconds>\n");
		return 2;
	}
	secs = strtoul(argv[4], NULL, 0);
	if (secs < 30 || secs > 300) {
		fprintf(stderr, "r26kexec: wdt seconds must be 30..300\n");
		return 2;
	}

	/* Run on CPU0: the reboot path migrates there, and our dirty lines too */
	CPU_ZERO(&cpu0);
	CPU_SET(0, &cpu0);
	if (sched_setaffinity(0, sizeof(cpu0), &cpu0))
		die("sched_setaffinity");

	tramp = read_file(argv[1], &tlen);
	zimg = read_file(argv[2], &zlen);
	dtb = read_file(argv[3], &dlen);
	if (tlen < 32 || tlen > PAGE || tlen % 4)
		return fprintf(stderr, "r26kexec: unexpected trampoline size %zu\n", tlen), 1;
	const size_t PARAMS_OFF = tlen - 16;
	if (DTB_DEST + dlen > ZIMAGE_DEST || ZIMAGE_DEST + zlen > WINDOW_END)
		return fprintf(stderr, "r26kexec: images don't fit the copy window\n"), 1;

	zpages = (zlen + PAGE - 1) / PAGE;
	dpages = (dlen + PAGE - 1) / PAGE;
	entries = zpages + dpages;
	lpages = (entries + LIST_ENTRIES - 1) / LIST_ENTRIES;

	/* Locked pages may still be migrated by compaction; forbid it so PFNs stay put */
	char old_cua = '1';
	int cua = open("/proc/sys/vm/compact_unevictable_allowed", O_RDWR);
	if (cua >= 0) {
		if (read(cua, &old_cua, 1) != 1 || pwrite(cua, "0", 1, 0) != 1)
			die("compact_unevictable_allowed");
	}

	pagemap = open("/proc/self/pagemap", O_RDONLY);
	if (pagemap < 0)
		die("pagemap");
	data = alloc_pages(entries, pagemap);
	list = alloc_pages(lpages, pagemap);
	tp = alloc_pages(1, pagemap);

	/* data pages: zImage, then DTB */
	for (unsigned int i = 0; i < entries; i++) {
		const uint8_t *src = i < zpages ? zimg + (size_t)i * PAGE : dtb + (size_t)(i - zpages) * PAGE;
		size_t left = i < zpages ? zlen - (size_t)i * PAGE : dlen - (size_t)(i - zpages) * PAGE;

		memset(data[i].va, 0, PAGE);
		memcpy(data[i].va, src, left < PAGE ? left : PAGE);
	}

	/* list pages */
	for (unsigned int l = 0, e = 0; l < lpages; l++) {
		uint32_t *w = (uint32_t *)list[l].va;
		unsigned int cnt = 0;

		memset(w, 0, PAGE);
		while (cnt < LIST_ENTRIES && e < entries) {
			uint32_t dst = e < zpages ? ZIMAGE_DEST + e * PAGE : DTB_DEST + (e - zpages) * PAGE;

			w[2 + cnt * 2] = dst;
			w[3 + cnt * 2] = data[e].pa;
			cnt++;
			e++;
		}
		w[0] = l + 1 < lpages ? list[l + 1].pa : 0;
		w[1] = cnt;
	}

	/* trampoline */
	memset(tp->va, 0, PAGE);
	memcpy(tp->va, tramp, tlen);
	((uint32_t *)(tp->va + PARAMS_OFF))[0] = ZIMAGE_DEST;
	((uint32_t *)(tp->va + PARAMS_OFF))[1] = DTB_DEST;
	((uint32_t *)(tp->va + PARAMS_OFF))[2] = list[0].pa;
	((uint32_t *)(tp->va + PARAMS_OFF))[3] = CRUMB_PHYS;

	clean_dcache(data, entries);
	clean_dcache(list, lpages);
	clean_dcache(tp, 1);

	fprintf(stderr, "r26kexec: zImage %zu B (%u pages) -> %#x, dtb %zu B -> %#x\n",
		zlen, zpages, ZIMAGE_DEST, dlen, DTB_DEST);
	fprintf(stderr, "r26kexec: %u list pages, first %#x; trampoline at %#x\n",
		lpages, list[0].pa, tp->pa);

	mem = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem < 0)
		die("/dev/mem");
	uint32_t apr = mem_read32(mem, ARM_PM_RESTART_PHYS);
	uint32_t rbm = mem_read32(mem, REBOOT_MODE_PHYS);
	fprintf(stderr, "r26kexec: arm_pm_restart=%#x reboot_mode=%#x\n", apr, rbm);
	if (apr != ARM_PM_RESTART_STOCK || rbm != 0) {
		fprintf(stderr, "r26kexec: kernel words don't match the stock image, refusing\n");
		return 1;
	}
	if (dry_run) {
		/* prove /dev/mem writes work: write the current values back to themselves */
		mem_write32(mem, ARM_PM_RESTART_PHYS, apr);
		mem_write32(mem, REBOOT_MODE_PHYS, rbm);
		if (mem_read32(mem, ARM_PM_RESTART_PHYS) != apr ||
		    mem_read32(mem, REBOOT_MODE_PHYS) != rbm)
			return fprintf(stderr, "r26kexec: write-back readback mismatch\n"), 1;
		fprintf(stderr, "r26kexec: /dev/mem write-back ok\n");
		if (cua >= 0 && pwrite(cua, &old_cua, 1, 0) != 1)
			die("restore compact_unevictable_allowed");
		fprintf(stderr, "r26kexec: dry run, nothing changed\n");
		return 0;
	}

	/* 1. watchdog: unbind the vendor driver (its .shutdown stops the timer), then arm */
	int u = open(WDT_UNBIND, O_WRONLY);
	if (u >= 0) {
		if (write(u, WDT_DEVNAME, strlen(WDT_DEVNAME)) < 0 && errno != ENODEV)
			die("unbind wdt");
		close(u);
	}
#ifndef NO_WDT
	wdt_arm(mem, secs);
#else
	fprintf(stderr, "r26kexec: built without watchdog (simulation)\n");
#endif

	/* 2. patch: reboot_mode first, then the function pointer */
	mem_write32(mem, REBOOT_MODE_PHYS, tp->pa);
	mem_write32(mem, ARM_PM_RESTART_PHYS, SOFT_RESTART_THUMB);
	if (mem_read32(mem, REBOOT_MODE_PHYS) != tp->pa ||
	    mem_read32(mem, ARM_PM_RESTART_PHYS) != SOFT_RESTART_THUMB) {
		fprintf(stderr, "r26kexec: patch readback mismatch\n");
		/* the watchdog is armed; it resets into stock */
		return 1;
	}

	/* breadcrumb in WDT_DUMMY_REG_1, read back after the watchdog reset */
	if (CRUMB_PHYS) {
		volatile uint8_t *w = mmap(NULL, PAGE, PROT_READ | PROT_WRITE,
					   MAP_SHARED, mem, WDT_PHYS);
		if (w != MAP_FAILED)
			*(volatile uint16_t *)(w + (CRUMB_PHYS - WDT_PHYS)) = 0x5201;
	}

	/* 3. go: plain reboot(2) runs device_shutdown(), then machine_restart() */
	fprintf(stderr, "r26kexec: rebooting into the trampoline\n");
	sync();
	reboot(RB_AUTOBOOT);
	die("reboot");
}
