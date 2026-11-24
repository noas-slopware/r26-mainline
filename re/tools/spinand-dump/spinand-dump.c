// SPDX-License-Identifier: GPL-2.0
/*
 * spinand-dump: read-only dump of the SSD202D boot SPI NAND from the running
 * stock kernel, through the FSP command engine over /dev/mem
 * (recipe: re/spinand-read.md).
 *
 *   spinand-dump info                 ID, feature registers, CIS + PNI pages
 *   spinand-dump read <blk> <n> <op>  blocks blk..blk+n-1, main+spare of
 *                                     every page to stdout; op = 03 or 0b
 *
 * Only these flash commands can ever be sent: 9F (read ID), 0F A0/B0/C0
 * (get feature), 13 (page read to cache), 03/0B (read from cache). Any other
 * opcode aborts before it reaches the bus: no write enable, no set feature,
 * no program, no erase, no reset.
 *
 * The hardware watchdog is armed for the duration (30 s, re-armed after every
 * page) so a bus stall ends in a reset into the untouched stock system, and
 * disarmed on exit, including SIGHUP/SIGINT/SIGTERM/SIGPIPE.
 */
#define _FILE_OFFSET_BITS 64
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define FSP_PAGE	0x1f002000u	/* FSP at +0xc00, QSPI at +0xe00 */
#define PM_PAGE		0x1f001000u	/* PM sleep at +0xc00 */
#define CHIP_PAGE	0x1f203000u	/* chiptop at +0xc00 */
#define WDT_PAGE	0x1f006000u

#define FSP(r)		(*(volatile uint16_t *)(fsp + 0xc00 + (r) * 4))
#define QSPI(r)		(*(volatile uint16_t *)(fsp + 0xe00 + (r) * 4))
#define PMSLP(r)	(*(volatile uint16_t *)(pm + 0xc00 + (r) * 4))
#define CHIP(r)		(*(volatile uint16_t *)(chip + 0xc00 + (r) * 4))
#define WDT(off)	(*(volatile uint16_t *)(wdt + (off)))

static volatile uint8_t *fsp, *pm, *chip, *wdt;

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void wdt_arm(unsigned int secs)
{
	uint32_t t = secs * 12000000u;

	WDT(0x00) = 1;
	WDT(0x14) = t >> 16;
	WDT(0x10) = t & 0xffff;
	WDT(0x00) = 1;
}

static void wdt_disarm(void)
{
	if (!wdt)
		return;
	WDT(0x00) = 1;
	WDT(0x14) = 0;
	WDT(0x10) = 0;
	WDT(0x00) = 0;
}

static void on_signal(int sig)
{
	(void)sig;
	wdt_disarm();
	_exit(3);
}

static void die(const char *msg)
{
	wdt_disarm();
	fprintf(stderr, "spinand-dump: %s\n", msg);
	exit(1);
}

/* one FSP transaction: CS low, wn bytes out, rn bytes in, CS high */
static void fsp_xfer(const uint8_t *tx, int wn, uint8_t *rx, int rn)
{
	uint8_t op = tx[0];
	int i;

	if (!((op == 0x9f && wn == 2) ||
	      (op == 0x0f && wn == 2 && (tx[1] == 0xa0 || tx[1] == 0xb0 || tx[1] == 0xc0)) ||
	      (op == 0x13 && wn == 4 && rn == 0) ||
	      ((op == 0x03 || op == 0x0b) && wn == 4)))
		die("refusing a non-read flash command");
	if (wn > 10 || rn > 10)
		die("transfer too long");

	if (FSP(0x6e) & 1)
		FSP(0x6f) = 1;
	FSP(0x6c) = 0x0007;
	FSP(0x75) = 0;
	FSP(0x76) = 0;
	for (i = 0; i < (wn + 1) / 2; i++)
		FSP(0x60 + i) = tx[2 * i] | (2 * i + 1 < wn ? tx[2 * i + 1] << 8 : 0);
	FSP(0x6a) = wn;
	FSP(0x6b) = rn;
	FSP(0x6d) = 1;
	double t0 = now();
	while (!(FSP(0x6e) & 1))
		if (now() - t0 > 0.002)
			die("FSP done timeout");
	for (i = 0; i < rn; i++)
		rx[i] = (FSP(0x65 + i / 2) >> (8 * (i & 1))) & 0xff;
	FSP(0x6f) = 1;
}

static uint8_t get_feature(uint8_t addr)
{
	uint8_t tx[2] = { 0x0f, addr }, rx[1];

	fsp_xfer(tx, 2, rx, 1);
	return rx[0];
}

/* page read to cache, wait for OIP clear; returns the status byte */
static uint8_t page_to_cache(uint32_t row)
{
	uint8_t tx[4] = { 0x13, row >> 16, row >> 8, row };
	uint8_t st;

	fsp_xfer(tx, 4, NULL, 0);
	double t0 = now();
	while ((st = get_feature(0xc0)) & 1)
		if (now() - t0 > 0.020)
			die("page read (OIP) timeout");
	return st;
}

static void read_cache(uint8_t op, uint16_t col, uint8_t *buf, int len)
{
	while (len > 0) {
		int n = len > 10 ? 10 : len;
		uint8_t tx[4] = { op, col >> 8, col & 0xff, 0 };

		fsp_xfer(tx, 4, buf, n);
		buf += n;
		col += n;
		len -= n;
	}
}

static volatile uint8_t *map(int fd, uint32_t pa, int prot)
{
	void *p = mmap(NULL, 4096, prot, MAP_SHARED, fd, pa);

	if (p == MAP_FAILED)
		die("mmap");
	return p;
}

static void checks(void)
{
	uint16_t pads = CHIP(0x50), cs = QSPI(0x7a), pmspi = PMSLP(0x35);
	uint16_t burst = QSPI(0x0a), clk = PMSLP(0x20);

	fprintf(stderr, "chiptop[50]=%04x qspi[7a]=%04x pm[35]=%04x qspi[0a]=%04x pm[20]=%04x\n",
		pads, cs, pmspi, burst, clk);
	if (pads & 0x8000)
		die("all_pad_in is set");
	if (cs)
		die("QSPI CS select is not SPI#1");
	if (pmspi & 0x0005)
		die("PM SPI pads are not in SPI mode");
	if (burst & 1)
		die("QSPI burst write left enabled");
}

static void hex(const char *tag, const uint8_t *b, int n)
{
	printf("%s", tag);
	for (int i = 0; i < n; i++)
		printf("%s%02x", i % 32 ? "" : "\n  ", b[i]);
	printf("\n");
}

static int info(void)
{
	uint8_t tx[2] = { 0x9f, 0 }, id[3];
	static uint8_t p0[2112], p1[2112];
	uint8_t a[16], b[10], c[10];
	uint8_t op;

	fsp_xfer(tx, 2, id, 3);
	printf("id %02x %02x %02x\n", id[0], id[1], id[2]);
	if (id[0] == 0x00 || id[0] == 0xff)
		die("no flash answering");
	uint8_t fa0 = get_feature(0xa0), fb0 = get_feature(0xb0), fc0 = get_feature(0xc0);
	printf("feature a0=%02x b0=%02x c0=%02x\n", fa0, fb0, fc0);
	if (fb0 & 0x40)
		die("OTP mode is on");

	/* go/no-go: chunk boundaries and dummy count, 03 first, then 0b */
	printf("page0 status %02x\n", page_to_cache(0));
	for (op = 0x03;; op = 0x0b) {
		read_cache(op, 0, a, 16);
		read_cache(op, 8, b, 10);
		read_cache(op, 5, c, 10);
		int ok = !memcmp(a + 8, b, 8) && !memcmp(a + 5, c, 10);
		printf("op %02x first16 %.16s consistent %d\n", op, (const char *)a, ok);
		if (ok && !memcmp(a, "MSTARSEMIUSFDCIS", 16))
			break;
		if (op == 0x0b)
			die("neither 03 nor 0b reads a CIS tag at block 0");
	}
	read_cache(op, 0, p0, sizeof(p0));
	printf("p1 status %02x\n", page_to_cache(1));
	read_cache(op, 0, p1, sizeof(p1));
	printf("op %02x\n", op);
	hex("cis", p0, 512);
	hex("pni", p1, 512);
	hex("cis-spare", p0 + 2048, 64);
	return 0;
}

static int dump(uint32_t blk, uint32_t n, uint8_t op)
{
	static uint8_t buf[4096 + 256];
	uint8_t tx[2] = { 0x9f, 0 }, id[3];

	if (op != 0x03 && op != 0x0b)
		die("op must be 03 or 0b");
	fsp_xfer(tx, 2, id, 3);
	fprintf(stderr, "id %02x %02x %02x\n", id[0], id[1], id[2]);
	if (id[0] == 0x00 || id[0] == 0xff)
		die("no flash answering");

	/* geometry from the CIS in block 0 */
	page_to_cache(0);
	read_cache(op, 0, buf, 16 + 41);
	if (memcmp(buf, "MSTARSEMIUSFDCIS", 16))
		die("no CIS tag in block 0");
	const uint8_t *sni = buf + 16;
	uint16_t spare = sni[16] | sni[17] << 8, psz = sni[18] | sni[19] << 8;
	uint16_t ppb = sni[20] | sni[21] << 8, nblk = sni[22] | sni[23] << 8;
	uint8_t planes = sni[26];
	fprintf(stderr, "geometry: page %u + %u, %u pages/block, %u blocks, planes %u\n",
		psz, spare, ppb, nblk, planes);
	if (psz + spare > (int)sizeof(buf) || !ppb || blk + n > nblk)
		die("bad geometry or range");

	unsigned long ecc_bad = 0, ecc_fixed = 0;
	for (uint32_t b = blk; b < blk + n; b++) {
		for (uint32_t p = 0; p < ppb; p++) {
			uint8_t st = page_to_cache(b * ppb + p);
			uint16_t col0 = (planes && (b & 1)) ? 0x1000 : 0;

			read_cache(op, col0, buf, psz + spare);
			if ((st & 0x70) == 0x20)
				ecc_bad++, fprintf(stderr, "uncorrectable: block %u page %u status %02x\n", b, p, st);
			else if (st & 0x70)
				ecc_fixed++;
			if (fwrite(buf, 1, psz + spare, stdout) != (size_t)(psz + spare))
				die("write");
			wdt_arm(30);
		}
	}
	fflush(stdout);
	fprintf(stderr, "done: blocks %u..%u, %lu pages corrected, %lu uncorrectable\n",
		blk, blk + n - 1, ecc_fixed, ecc_bad);
	return 0;
}

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);

	if (fd < 0)
		die("open /dev/mem");
	fsp = map(fd, FSP_PAGE, PROT_READ | PROT_WRITE);
	pm = map(fd, PM_PAGE, PROT_READ);
	chip = map(fd, CHIP_PAGE, PROT_READ);
	checks();

	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGPIPE, &sa, NULL);
	wdt = map(fd, WDT_PAGE, PROT_READ | PROT_WRITE);
	wdt_arm(30);

	int rc;
	if (argc == 2 && !strcmp(argv[1], "info"))
		rc = info();
	else if (argc == 5 && !strcmp(argv[1], "read"))
		rc = dump(strtoul(argv[2], NULL, 0), strtoul(argv[3], NULL, 0),
			  strtoul(argv[4], NULL, 16));
	else {
		wdt_disarm();
		fprintf(stderr, "usage: spinand-dump info | read <block> <count> <03|0b>\n");
		return 2;
	}
	wdt_disarm();
	return rc;
}
